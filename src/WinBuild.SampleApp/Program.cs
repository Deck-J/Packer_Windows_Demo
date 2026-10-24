using System.Reflection;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// The pipeline's proof depends on these three endpoints agreeing with each other:
//   /healthz    the load balancer's health check
//   /version    what the NODE is actually running (must equal the published package version)
//   X-Served-By which node answered (two distinct values prove traffic is distributed)
var instanceName = Environment.GetEnvironmentVariable("COMPUTERNAME")
                   ?? Environment.GetEnvironmentVariable("HOSTNAME")
                   ?? "unknown-instance";

var version = Assembly.GetExecutingAssembly()
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
    ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString()
    ?? "unknown";

app.Use(async (context, next) =>
{
    context.Response.Headers["X-Served-By"] = instanceName;
    await next();
});

app.MapGet("/healthz", () => Results.Text("ok", "text/plain"));
app.MapGet("/version", () => Results.Text(version, "text/plain"));
app.MapGet("/", () => Results.Text($"WinBuild sample app {version} on {instanceName}", "text/plain"));

app.Logger.LogInformation("starting {App} version {Version} as {Instance}", "WinBuild.SampleApp", version, instanceName);
app.Run();

// Required so the test project can reference the entry point.
public partial class Program { }
