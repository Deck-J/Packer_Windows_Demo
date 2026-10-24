using System.Net;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace WinBuild.SampleApp.Tests;

public class EndpointsTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public EndpointsTests(WebApplicationFactory<Program> factory) => _client = factory.CreateClient();

    [Fact]
    public async Task Healthz_returns_ok()
    {
        var response = await _client.GetAsync("/healthz");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("ok", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Version_is_not_empty()
    {
        var body = await _client.GetStringAsync("/version");
        Assert.False(string.IsNullOrWhiteSpace(body));
        Assert.NotEqual("unknown", body);
    }

    [Fact]
    public async Task Telemetry_reports_the_service_and_its_export_state()
    {
        var body = await _client.GetStringAsync("/telemetry");
        Assert.Contains("WinBuild.SampleApp", body);
        Assert.Contains("\"enabled\":", body);
    }

    [Fact]
    public async Task Demo_checkout_produces_an_order()
    {
        var response = await _client.GetAsync("/demo/checkout?items=2");
        response.EnsureSuccessStatusCode();
        var body = await response.Content.ReadAsStringAsync();
        Assert.Contains("19.98", body);   // 2 x 9.99, the documented demo price
    }

    [Fact]
    public async Task Every_response_identifies_the_instance()
    {
        var response = await _client.GetAsync("/healthz");
        Assert.True(response.Headers.Contains("X-Served-By"));
        Assert.False(string.IsNullOrWhiteSpace(response.Headers.GetValues("X-Served-By").First()));
    }
}
