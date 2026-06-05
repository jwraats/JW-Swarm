using System.Windows.Forms;
using JwSwarmNode.Core.Config;
using JwSwarmNode.Core.Enroll;

namespace JwSwarmNode.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // CLI enrollment mode: JwSwarmNode.exe enroll --base-url ... --node-id ... --token ...
        if (args.Length > 0 && string.Equals(args[0], "enroll", StringComparison.OrdinalIgnoreCase))
        {
            return RunEnroll(args.Skip(1).ToArray());
        }

        ApplicationConfiguration.Initialize();
        var config = NodeConfig.Load();
        using var context = new TrayApplicationContext(config);
        System.Windows.Forms.Application.Run(context);
        return 0;
    }

    private static int RunEnroll(string[] args)
    {
        string? baseUrl = null, nodeId = null, token = null, outDir = null;
        var writeConfig = true;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--base-url": baseUrl = Next(args, ref i); break;
                case "--node-id": nodeId = Next(args, ref i); break;
                case "--token": token = Next(args, ref i); break;
                case "--out-dir": outDir = Next(args, ref i); break;
                case "--no-write-config": writeConfig = false; break;
                case "-h":
                case "--help":
                    PrintEnrollHelp();
                    return 0;
            }
        }

        if (baseUrl is null || nodeId is null || token is null)
        {
            Console.Error.WriteLine("error: --base-url, --node-id and --token are required");
            PrintEnrollHelp();
            return 2;
        }

        try
        {
            Enrollment.RunAsync(new EnrollArgs
            {
                BaseUrl = baseUrl,
                NodeId = nodeId,
                Token = token,
                OutDir = outDir,
                WriteConfig = writeConfig,
            }).GetAwaiter().GetResult();
            Console.WriteLine("Enrollment complete.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"enrollment failed: {ex.Message}");
            return 1;
        }
    }

    private static string? Next(string[] args, ref int i)
        => (i + 1 < args.Length) ? args[++i] : null;

    private static void PrintEnrollHelp()
    {
        Console.WriteLine(
            "Usage: JwSwarmNode.exe enroll --base-url <https://host> --node-id <id> --token <token> [--out-dir <dir>] [--no-write-config]");
    }
}
