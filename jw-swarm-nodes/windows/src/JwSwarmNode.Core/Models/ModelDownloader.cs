using System.Security.Cryptography;
using JwSwarmNode.Core.Proto;

namespace JwSwarmNode.Core.Models;

public sealed class DownloadException : Exception
{
    public DownloadException(string message) : base(message) { }
}

/// <summary>
/// Downloads and SHA256-verifies model artifacts. Mirrors the Linux/macOS
/// downloaders: disk-space preflight, streaming to a <c>.partial</c> file,
/// cleanup on failure, and atomic rename on success.
/// </summary>
public sealed class ModelDownloader
{
    private const long DiskHeadroomBytes = 64L * 1024 * 1024;
    private const int BufferSize = 1 << 20; // 1 MiB

    private readonly HttpClient _http;

    public ModelDownloader(HttpClient? http = null)
    {
        _http = http ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>Progress callback: (bytesDownloaded, totalBytes or 0 if unknown).</summary>
    public Action<long, long>? Progress { get; set; }

    /// <summary>
    /// Ensures the model identified by <paramref name="model"/> is present and
    /// verified under <paramref name="modelRoot"/>/&lt;id&gt;/weights.bin.
    /// Returns the directory holding the verified artifact.
    /// </summary>
    public async Task<string> DownloadModelAsync(
        CatalogModel model, string modelRoot, CancellationToken ct = default)
    {
        var dir = Path.Combine(modelRoot, model.Id);
        Directory.CreateDirectory(dir);

        var finalPath = Path.Combine(dir, "weights.bin");
        if (File.Exists(finalPath) && await VerifyAsync(finalPath, model.Sha256, ct))
        {
            return dir;
        }

        EnsureDiskSpace(dir, (long)model.SizeBytes);

        var partial = Path.Combine(dir, "weights.bin.partial");
        if (File.Exists(partial)) File.Delete(partial);

        try
        {
            await StreamToFileAsync(model.DownloadUrl, partial, (long)model.SizeBytes, ct);

            if (!await VerifyAsync(partial, model.Sha256, ct))
            {
                File.Delete(partial);
                throw new DownloadException(
                    $"sha256 mismatch for {model.Id} (expected {model.Sha256})");
            }

            if (File.Exists(finalPath)) File.Delete(finalPath);
            File.Move(partial, finalPath);
            return dir;
        }
        catch
        {
            if (File.Exists(partial)) File.Delete(partial);
            throw;
        }
    }

    private async Task StreamToFileAsync(
        string url, string destPath, long expectedBytes, CancellationToken ct)
    {
        using var resp = await _http.GetAsync(
            url, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!resp.IsSuccessStatusCode)
        {
            throw new DownloadException($"download failed: HTTP {(int)resp.StatusCode} for {url}");
        }

        var total = resp.Content.Headers.ContentLength ?? expectedBytes;
        await using var src = await resp.Content.ReadAsStreamAsync(ct);
        await using var dst = new FileStream(
            destPath, FileMode.Create, FileAccess.Write, FileShare.None,
            BufferSize, useAsync: true);

        var buffer = new byte[BufferSize];
        long written = 0;
        int read;
        while ((read = await src.ReadAsync(buffer.AsMemory(0, BufferSize), ct)) > 0)
        {
            await dst.WriteAsync(buffer.AsMemory(0, read), ct);
            written += read;
            Progress?.Invoke(written, total);
        }
    }

    private static async Task<bool> VerifyAsync(string path, string expectedSha256, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(expectedSha256)) return false;
        await using var fs = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize, useAsync: true);
        using var sha = SHA256.Create();
        var hash = await sha.ComputeHashAsync(fs, ct);
        var hex = Convert.ToHexString(hash).ToLowerInvariant();
        return string.Equals(hex, expectedSha256.Trim().ToLowerInvariant(), StringComparison.Ordinal);
    }

    /// <summary>Throws if the target volume lacks room for the artifact plus headroom.</summary>
    internal static void EnsureDiskSpace(string dir, long requiredBytes)
    {
        if (requiredBytes <= 0) return;
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(dir));
            if (string.IsNullOrEmpty(root)) return;
            var drive = new DriveInfo(root);
            var available = drive.AvailableFreeSpace;
            var needed = requiredBytes + DiskHeadroomBytes;
            if (available < needed)
            {
                throw new DownloadException(
                    $"insufficient disk space: need {needed} bytes, {available} available at {root}");
            }
        }
        catch (DownloadException)
        {
            throw;
        }
        catch (Exception)
        {
            // If the volume can't be inspected, proceed and let the write surface errors.
        }
    }
}
