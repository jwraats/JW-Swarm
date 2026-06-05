using System.Globalization;
using JwSwarmNode.Core.Gpu;
using JwSwarmNode.Core.Proto;

namespace JwSwarmNode.Core.Metrics;

/// <summary>
/// Collects GPU metrics via <c>nvidia-smi</c> where available, falling back to
/// zeroed metrics. Mirrors the Linux node's <c>metrics.rs</c>.
/// </summary>
public static class MetricsCollector
{
    public static Proto.Metrics Collect()
    {
        if (GpuDetect.TryRun(
                "nvidia-smi",
                "--query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits",
                out var output))
        {
            var line = output.Split('\n').FirstOrDefault();
            if (!string.IsNullOrWhiteSpace(line))
            {
                var parts = line.Split(',');
                if (parts.Length >= 3
                    && ulong.TryParse(parts[0].Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out var used)
                    && ulong.TryParse(parts[1].Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out var total)
                    && double.TryParse(parts[2].Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out var util))
                {
                    return new Proto.Metrics
                    {
                        VramUsedMb = used,
                        VramTotalMb = total,
                        GpuUtilPct = util,
                        Tps = 0,
                        LatencyMs = 0,
                        InFlight = 0,
                    };
                }
            }
        }
        return Zero();
    }

    public static Proto.Metrics Zero() => new();
}
