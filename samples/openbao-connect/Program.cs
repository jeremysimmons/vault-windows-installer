using System.Text.Json;

var address = (Environment.GetEnvironmentVariable("BAO_ADDR")
    ?? Environment.GetEnvironmentVariable("VAULT_ADDR")
    ?? "http://127.0.0.1:8200").TrimEnd('/');

var token = Environment.GetEnvironmentVariable("BAO_TOKEN")
    ?? Environment.GetEnvironmentVariable("VAULT_TOKEN");

using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

Console.WriteLine($"OpenBao address: {address}");

var health = await GetJsonAsync(http, $"{address}/v1/sys/health");
Console.WriteLine($"Health: initialized={health.GetProperty("initialized")} sealed={health.GetProperty("sealed")} standby={health.GetProperty("standby")}");

var seal = await GetJsonAsync(http, $"{address}/v1/sys/seal-status");
Console.WriteLine($"Seal: storage={seal.GetProperty("storage_type")} type={seal.GetProperty("type")} version={seal.GetProperty("version")}");

if (string.IsNullOrWhiteSpace(token))
{
    Console.Error.WriteLine("Set BAO_TOKEN or VAULT_TOKEN (root_token from C:\\OpenBao\\init\\bao-init.json) to verify authenticated access.");
    Environment.Exit(1);
}

using var authRequest = new HttpRequestMessage(HttpMethod.Get, $"{address}/v1/auth/token/lookup-self");
authRequest.Headers.Add("X-Vault-Token", token);
using var authResponse = await http.SendAsync(authRequest);
authResponse.EnsureSuccessStatusCode();
var authBody = await authResponse.Content.ReadAsStringAsync();
using var authDoc = JsonDocument.Parse(authBody);
var accessor = authDoc.RootElement.GetProperty("data").GetProperty("accessor").GetString();
Console.WriteLine($"Token lookup-self OK (accessor {accessor}).");

Console.WriteLine("Connection OK.");
return;

static async Task<JsonElement> GetJsonAsync(HttpClient http, string url)
{
    using var response = await http.GetAsync(url);
    response.EnsureSuccessStatusCode();
    await using var stream = await response.Content.ReadAsStreamAsync();
    using var doc = await JsonDocument.ParseAsync(stream);
    return doc.RootElement.Clone();
}
