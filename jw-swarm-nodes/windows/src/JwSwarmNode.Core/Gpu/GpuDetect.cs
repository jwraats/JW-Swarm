using System.Diagnostics;
using JwSwarmNode.Core.Proto;

namespace JwSwarmNode.Core.Gpu;

/// <summary>Detects the local GPU vendor and name, mirroring the Linux node.</summary>
public static class GpuDetect
{
    public static string Vendor()
    {
        if (TryRun("nvidia-smi", "-L", out _)) return GpuVendor.Nvidia;
        if (TryRun("rocminfo", "", out _)) return GpuVendor.Amd;
        // Default to NVIDIA, matching the other nodes' optimistic default.
        return GpuVendor.Nvidia;
    }

    public static string Name(string vendor)
    {
        if (vendor == GpuVendor.Nvidia &&
            TryRun("nvidia-smi", "--query-gpu=name --format=csv,noheader,nounits", out var outp))
        {
            var first = outp.Split('\n').FirstOrDefault()?.Trim();
            if (!string.IsNullOrWhiteSpace(first)) return first;
        }
        return vendor == GpuVendor.Nvidia ? "NVIDIA GPU" : "GPU";
    }

    internal static bool TryRun(string file, string args, out string output)
    {
        output = "";
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = file,
                Arguments = args,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var proc = Process.Start(psi);
            if (proc is null) return false;
            output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(5000);
            return proc.HasExited && proc.ExitCode == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
