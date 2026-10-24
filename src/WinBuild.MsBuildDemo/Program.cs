using System;
using System.Reflection;

namespace WinBuild.MsBuildDemo
{
    /// <summary>
    /// Prints what it was built with, so the build log proves which toolchain produced it.
    /// </summary>
    internal static class Program
    {
        private static int Main(string[] args)
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version;
            Console.WriteLine("WinBuild.MsBuildDemo");
            Console.WriteLine("  built with : .NET Framework " + Environment.Version);
            Console.WriteLine("  assembly   : " + version);
            Console.WriteLine("  machine    : " + Environment.MachineName);
            Console.WriteLine("  reason     : proving an MSBuild (not dotnet) build in the pipeline image");
            return 0;
        }
    }
}
