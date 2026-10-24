using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Reflection;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// The pipeline's proof depends on these endpoints agreeing with each other:
//   /healthz    the load balancer's health check
//   /version    what the NODE is actually running (must equal the published package version)
//   /telemetry  whether this instance is exporting, and where to  (so a misconfiguration is visible)
//   X-Served-By which node answered (two distinct values prove traffic is distributed)

const string ServiceName = "WinBuild.SampleApp";

var builder = WebApplication.CreateBuilder(args);

var instanceName = Environment.GetEnvironmentVariable("COMPUTERNAME")
                   ?? Environment.GetEnvironmentVariable("HOSTNAME")
                   ?? "unknown-instance";

var version = Assembly.GetExecutingAssembly()
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
    ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString()
    ?? "unknown";

var environment = Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") ?? "Production";
var otlpEndpoint = Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT") ?? string.Empty;
var serviceName = Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME") ?? ServiceName;

// Telemetry is on when an endpoint is configured, unless explicitly forced either way. A demo app that
// silently exports to nowhere is worse than one that says it is not exporting.
var telemetryEnabled = bool.TryParse(Environment.GetEnvironmentVariable("OTEL_ENABLED"), out var forced)
    ? forced
    : !string.IsNullOrWhiteSpace(otlpEndpoint);

var telemetryEndpoint = string.IsNullOrWhiteSpace(otlpEndpoint) ? "none" : otlpEndpoint;

if (telemetryEnabled && telemetryEndpoint == "none")
{
    builder.Logging.AddConsole();
    Console.WriteLine("OTEL_ENABLED=true but OTEL_EXPORTER_OTLP_ENDPOINT is empty: refusing to start exporters.");
    telemetryEnabled = false;
}

if (telemetryEnabled)
{
    builder.Services.AddOpenTelemetry()
        .ConfigureResource(resource => resource
            .AddService(serviceName, serviceVersion: version)
            .AddAttributes(new Dictionary<string, object>
            {
                ["deployment.environment"] = environment,
                ["host.name"] = instanceName,
                ["service.instance.id"] = instanceName,
            }))
        .WithTracing(tracing => tracing
            .AddSource(ServiceName)
            .AddAspNetCoreInstrumentation(options =>
            {
                // Health checks fire every 10 seconds from the load balancer; tracing them buries the
                // signal. Everything else is traced.
                options.Filter = context => !context.Request.Path.StartsWithSegments("/healthz");
            })
            .AddHttpClientInstrumentation()
            .AddOtlpExporter(options => options.Endpoint = new Uri(otlpEndpoint)))
        .WithMetrics(metrics => metrics
            .AddMeter(ServiceName)
            .AddAspNetCoreInstrumentation()
            .AddRuntimeInstrumentation()
            .AddOtlpExporter(options => options.Endpoint = new Uri(otlpEndpoint)));
}

var app = builder.Build();

// Demo instrumentation: one counter, one histogram, one activity source. This is what "instrumented"
// looks like when it is not just the framework's automatic spans.
var checkoutCounter = app.Services.GetService<MeterProvider>() is null
    ? null
    : new Meter(ServiceName).CreateCounter<long>("checkout.requests", "1", "Demo checkout requests");
var checkoutDuration = checkoutCounter is null
    ? null
    : new Meter(ServiceName).CreateHistogram<double>("checkout.duration", "ms", "Demo checkout duration");
var checkoutSource = new ActivitySource(ServiceName);

app.Use(async (context, next) =>
{
    context.Response.Headers["X-Served-By"] = instanceName;
    await next();
});

app.MapGet("/healthz", () => Results.Text("ok", "text/plain"));
app.MapGet("/version", () => Results.Text(version, "text/plain"));

app.MapGet("/telemetry", () => Results.Json(new
{
    enabled = telemetryEnabled,
    service = serviceName,
    endpoint = telemetryEndpoint,
    environment,
    instance = instanceName,
    version,
    protocol = telemetryEnabled ? "otlp" : "none",
}));

// A deliberately instrumented endpoint: a parent span, a child span, an attribute, a counter and a
// histogram. Call it after deployment and the trace should appear in whatever backend OTLP points at.
app.MapGet("/demo/checkout", async (int items = 3) =>
{
    using var activity = checkoutSource.StartActivity("checkout", ActivityKind.Internal);
    activity?.SetTag("checkout.items", items);
    activity?.SetTag("checkout.currency", "USD");

    var started = Stopwatch.StartNew();
    using (var pricing = checkoutSource.StartActivity("pricing", ActivityKind.Internal))
    {
        pricing?.SetTag("pricing.items", items);
        await Task.Delay(15 * Math.Max(1, items));
        pricing?.SetTag("pricing.total", items * 9.99);
    }

    using (var persist = checkoutSource.StartActivity("persist-order", ActivityKind.Client))
    {
        persist?.SetTag("db.system", "demo");
        await Task.Delay(25);
    }

    started.Stop();
    checkoutCounter?.Add(1);
    checkoutDuration?.Record(started.Elapsed.TotalMilliseconds);

    return Results.Json(new
    {
        order = Guid.NewGuid().ToString("n")[..8],
        items,
        total = Math.Round(items * 9.99, 2),
        durationMs = Math.Round(started.Elapsed.TotalMilliseconds, 1),
        traceId = activity?.TraceId.ToString() ?? "no-trace",
        instance = instanceName,
    });
});

app.MapGet("/", () => Results.Text($"WinBuild sample app {version} on {instanceName}", "text/plain"));

app.Logger.LogInformation(
    "starting {App} version {Version} as {Instance} (telemetry: {Telemetry} -> {Endpoint})",
    ServiceName, version, instanceName, telemetryEnabled, telemetryEndpoint);

app.Run();

// Required so the test project can reference the entry point.
public partial class Program { }
