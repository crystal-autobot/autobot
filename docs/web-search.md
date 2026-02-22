# Web Search & Fetch

Autobot includes two built-in web tools that give the LLM access to the internet: `web_search` for querying search engines and `web_fetch` for retrieving page content.

## How It Works

```
User message -> Agent loop -> LLM requests web_search/web_fetch -> Tool executes -> Results fed back to LLM
```

1. The LLM decides it needs external information and calls `web_search` or `web_fetch`
2. The tool executes the request (search query or URL fetch)
3. Results are returned to the LLM as tool output
4. The LLM incorporates the information into its response

Both tools are registered automatically in the agent's tool registry at startup.

## Tools

### web_search

Searches the web using the [Brave Search API](https://brave.com/search/api/).

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | Search query |
| `count` | integer | no | Number of results (1-10, default: 5) |

**Returns:** Numbered list of results with title, URL, and description snippet.

### web_fetch

Fetches a URL and extracts readable text content. Supports HTML (with tag stripping), JSON (pretty-printed), and raw text.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `url` | string | yes | URL to fetch (http/https only) |
| `maxChars` | integer | no | Max content chars to return (default: 20,000) |

**Returns:** Plain text with URL header and extracted content. Includes truncation notice when content exceeds `maxChars`.

**Features:**

- Follows redirects (max 5 hops)
- HTML tag stripping with entity decoding
- JSON pretty-printing
- 10-second read/connect timeout

## Configuration

```yaml
tools:
  web:
    search:
      api_key: "${BRAVE_API_KEY}"
      max_results: 5
```

The Brave API key can also be set via the `BRAVE_API_KEY` environment variable. If no key is configured, `web_search` returns an error message — `web_fetch` works without any API key.

## Security

### SSRF Protection

`web_fetch` includes defense against Server-Side Request Forgery (SSRF) attacks. Before connecting to any URL, the tool:

1. **Validates the scheme** — only `http` and `https` are allowed
2. **Resolves DNS** and validates **all** returned IPs (not just the first)
3. **Blocks private ranges** — RFC 1918 (`10.x`, `172.16-31.x`, `192.168.x`), IPv6 ULA (`fc00::/7`)
4. **Blocks loopback** — `127.x`, `::1`, `0.0.0.0`
5. **Blocks cloud metadata** — `169.254.169.254` (AWS/GCP/Azure metadata endpoint)
6. **Blocks link-local** — `169.254.x`, `fe80:`
7. **Blocks alternate IP notation** — octal (`0177.0.0.1`), hex (`0x7f000001`), integer notation
8. **Validates redirect targets** — each redirect hop is re-validated against all SSRF checks
9. **Connects to validated IP** — prevents DNS rebinding by connecting to the resolved IP directly

### Rate Limiting

Both tools are subject to the global tool rate limiter, preventing excessive API calls within a session.
