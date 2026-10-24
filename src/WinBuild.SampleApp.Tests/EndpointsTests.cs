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
    public async Task Every_response_identifies_the_instance()
    {
        var response = await _client.GetAsync("/healthz");
        Assert.True(response.Headers.Contains("X-Served-By"));
        Assert.False(string.IsNullOrWhiteSpace(response.Headers.GetValues("X-Served-By").First()));
    }
}
