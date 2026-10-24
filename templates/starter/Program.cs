using System.Reflection;

// The three things the framework's validation suite expects of any application.
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var instance = Environment.GetEnvironmentVariable("COMPUTERNAME") ?? Environment.GetEnvironmentVariable("HOSTNAME") ?? "unknown";
var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown";

app.Use(async (context, next) =>
{
    context.Response.Headers["X-Served-By"] = instance;
    await next();
});

app.MapGet("/healthz", () => Results.Text("ok", "text/plain"));
app.MapGet("/version", () => Results.Text(version, "text/plain"));
app.MapGet("/", () => Results.Text($"hello from {instance} running {version}", "text/plain"));

app.Run();

public partial class Program { }
