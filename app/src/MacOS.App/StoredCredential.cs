using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;

namespace MacOS.App;
static class StoredCredential
{
    public static string Read()
    {
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacOS");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "guest-credential.clixml");
        if (!File.Exists(path) || new FileInfo(path).Length > 65536) throw new IOException("The saved macOS sign-in credential is unavailable.");
        var document = XDocument.Load(path);
        var encrypted = document.Descendants().Single(e => e.Name.LocalName == "SS" && (string?)e.Attribute("N") == "Password").Value;
        var bytes = ProtectedData.Unprotect(Convert.FromHexString(encrypted), null, DataProtectionScope.CurrentUser);
        try { return Encoding.Unicode.GetString(bytes); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
}
