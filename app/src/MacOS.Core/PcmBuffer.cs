using System.Buffers.Binary;
namespace MacOS.Core;
// Stereo float32 frames stay aligned across arbitrary SSH read boundaries.
// Drop complete oldest frames on overflow so latency cannot grow unbounded.
public sealed class PcmBuffer(int capacityFrames = 2400)
{
    public const int FrameBytes = 8;
    readonly byte[] ring = new byte[checked(capacityFrames > 0 ? capacityFrames * FrameBytes : throw new ArgumentOutOfRangeException(nameof(capacityFrames)))];
    readonly byte[] partial = new byte[FrameBytes];
    readonly object gate = new();
    int read, count, partialCount;
    public long DroppedFrames { get; private set; }
    public long ReceivedBytes { get; private set; }
    public int BufferedBytes { get { lock(gate) return count; } }
    public static void ValidateHeader(ReadOnlySpan<byte> header)
    {
        if(header.Length!=24 || !header[..8].SequenceEqual("MACAUDIO"u8) ||
            BinaryPrimitives.ReadUInt32LittleEndian(header[8..])!=1 ||
            BinaryPrimitives.ReadUInt32LittleEndian(header[12..])!=48000 ||
            BinaryPrimitives.ReadUInt32LittleEndian(header[16..])!=2 ||
            BinaryPrimitives.ReadUInt32LittleEndian(header[20..])!=32)
            throw new InvalidDataException("Unsupported macOS audio stream.");
    }
    public void Write(ReadOnlySpan<byte> input)
    {
        lock(gate) {
            ReceivedBytes+=input.Length;
            foreach(byte value in input) {
                partial[partialCount++]=value;
                if(partialCount!=FrameBytes)continue;
                if(count==ring.Length){read=(read+FrameBytes)%ring.Length;count-=FrameBytes;DroppedFrames++;}
                int at=(read+count)%ring.Length;
                partial.CopyTo(ring,at);count+=FrameBytes;partialCount=0;
            }
        }
    }
    public int Read(Span<byte> output)
    {
        if(output.Length%FrameBytes!=0)throw new ArgumentException("Audio reads must contain whole frames.");
        lock(gate) {
            int take=Math.Min(count,output.Length),first=Math.Min(take,ring.Length-read);
            ring.AsSpan(read,first).CopyTo(output);
            ring.AsSpan(0,take-first).CopyTo(output[first..]);
            read=(read+take)%ring.Length;count-=take;
            output[take..].Clear();return output.Length;
        }
    }
}
