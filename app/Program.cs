var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => Results.Json(new
{
    application = "Windows Worker Demo",
    status = "healthy",
    machine = Environment.MachineName,
    timestampUtc = DateTimeOffset.UtcNow
}));

app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.Run();
