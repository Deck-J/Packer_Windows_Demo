using System.Net;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace Starter.Tests;

/// <summary>The contract every application in this framework must satisfy.</summary>
public class ContractTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;
    public ContractTests(WebApplicationFactory<Program> factory) => _client = factory.CreateClient();

    [Fact]
    public async Task Healthz_returns_ok()
    {
        var response = await _client.GetAsync("/healthz");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("ok", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Identifies_the_instance()
    {
        var response = await _client.GetAsync("/healthz");
        Assert.True(response.Headers.Contains("X-Served-By"));
    }
}
