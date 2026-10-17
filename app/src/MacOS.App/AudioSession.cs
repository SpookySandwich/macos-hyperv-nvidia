using System.Diagnostics;
using System.Text.Json;
using MacOS.Core;
using NAudio.Wave;
namespace MacOS.App;
sealed class AudioSession(GuestConnection guest, Action<string> notice) : IDisposable
{
    readonly CancellationTokenSource lifetime=new();
    readonly object gate=new();
    Task? worker;
    string? lastFailure;
    int disposed;
    public void Start()
    {
        lock(gate) { ObjectDisposedException.ThrowIf(disposed!=0,this);worker ??= Task.Run(RunAsync); }
    }
    static void StopTransport(Process process)
    {
        try { if(!process.HasExited)process.Kill(true); }
        catch(InvalidOperationException) { }
        catch(System.ComponentModel.Win32Exception) { }
    }
    static async Task<WasapiPlayer> OpenPlayerAsync(CancellationToken ct)
    {
        var activation=new WasapiPlayerBuilder().WithDefaultDeviceStreamRouting().WithLatency(20).BuildAsync();
        try { return await activation.WaitAsync(ct); }
        catch {
            // WASAPI activation itself has no cancellation API. If it completes
            // after the session closes, release the player without starting it.
            _=ReleaseLatePlayerAsync(activation);
            throw;
        }
    }
    static async Task ReleaseLatePlayerAsync(Task<WasapiPlayer> activation)
    {
        try { await (await activation).DisposeAsync(); } catch { }
    }
    sealed class Source(PcmBuffer buffer) : IWaveProvider
    {
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(48000,2);
        public int Read(Span<byte> data) => buffer.Read(data);
    }
    async Task RunAsync()
    {
        var ct=lifetime.Token;
        while(!ct.IsCancellationRequested) {
            Process? process=null;Task<string>? errors=null;
            try {
                using var setup=CancellationTokenSource.CreateLinkedTokenSource(ct);setup.CancelAfter(TimeSpan.FromSeconds(35));
                process=await guest.OpenAudioAsync(setup.Token);
                using var cancellation=ct.Register(()=>StopTransport(process));
                errors=process.StandardError.ReadToEndAsync();
                var input=process.StandardOutput.BaseStream;
                var header=new byte[24];await input.ReadExactlyAsync(header,setup.Token);PcmBuffer.ValidateHeader(header);
                var pcm=new PcmBuffer();var bytes=new byte[8192];
                // Ten milliseconds of real PCM before starting the device.
                await input.ReadExactlyAsync(bytes.AsMemory(0,3840),setup.Token);pcm.Write(bytes.AsSpan(0,3840));
                await using var player=await OpenPlayerAsync(setup.Token);
                ct.ThrowIfCancellationRequested();
                player.Init(new Source(pcm));player.Play();
                if(lastFailure is not null)notice("");
                lastFailure=null;
                Record("Playing",pcm,0,null);
                var lastReport=Stopwatch.StartNew();
                while(!ct.IsCancellationRequested) {
                    using var read=CancellationTokenSource.CreateLinkedTokenSource(ct);read.CancelAfter(TimeSpan.FromSeconds(10));
                    int length=await input.ReadAsync(bytes,read.Token);
                    if(length==0)throw new IOException("The macOS audio stream ended.");
                    pcm.Write(bytes.AsSpan(0,length));
                    if(player.PlaybackState!=PlaybackState.Playing)throw new IOException("Windows audio playback stopped.");
                    if(lastReport.Elapsed.TotalSeconds>=5){Record("Playing",pcm,player.GetPosition(),null);lastReport.Restart();}
                }
            }
            catch(Exception) when(ct.IsCancellationRequested) { break; }
            catch(Exception ex) {
                string message=ex is OperationCanceledException ? "macOS audio did not become ready. Allow macOS Audio in macOS Privacy & Security > Microphone." : ex.Message;
                if(process is not null)StopTransport(process);
                if(errors is not null) {
                    try { string detail=await errors.WaitAsync(TimeSpan.FromSeconds(2),ct);if(!string.IsNullOrWhiteSpace(detail))message=detail.Trim(); }
                    catch(Exception) { }
                }
                if(ct.IsCancellationRequested)break;
                Record("Retrying",null,0,message);
                if(lastFailure!=message){lastFailure=message;notice(message.Contains("Microphone",StringComparison.OrdinalIgnoreCase) ? "Allow macOS Audio in macOS Privacy & Security > Microphone to enable sound." : "Sound is reconnecting…");}
            }
            finally {
                if(process is not null){StopTransport(process);process.Dispose();}
            }
            try {await Task.Delay(TimeSpan.FromSeconds(5),ct);}catch(OperationCanceledException){break;}
        }
        Record("Stopped",null,0,null);
    }
    static void Record(string state,PcmBuffer? pcm,long played,string? error)
    {
        try {
            var folder=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"MacOS");Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder,"audio.json"),JsonSerializer.Serialize(new {State=state,ReceivedBytes=pcm?.ReceivedBytes,BufferedBytes=pcm?.BufferedBytes,DroppedFrames=pcm?.DroppedFrames,PlayedBytes=played,Error=error,At=DateTimeOffset.UtcNow}));
        } catch(IOException) { } catch(UnauthorizedAccessException) { }
    }
    public async Task StopAsync(){Dispose();if(worker is not null)await worker;}
    public void Dispose()
    {
        lock(gate) {
            if(disposed!=0)return;
            disposed=1;lifetime.Cancel();
            if(worker is null)lifetime.Dispose();
            else _=worker.ContinueWith(_=>lifetime.Dispose(),TaskScheduler.Default);
        }
    }
}
