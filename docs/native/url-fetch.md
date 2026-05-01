# url_fetch — Native networking with sidecar promotion

`interceptor macos url get/post <url>` runs over `URLSession` with shared cookies, ETag, redirect handling, and content-type passthrough. Large responses (>64 KB by default) are spilled to a sidecar file so the next agent turn does not get the full payload back inline.

## Quick examples

```bash
interceptor macos url get https://example.com
interceptor macos url get https://api.example.com/data \
  --header "Authorization: Bearer XYZ" \
  --header "X-Custom: foo"
interceptor macos url post https://api.example.com/x \
  --body '{"a":1}' --content-type application/json
```

## Body shape (small payload, ≤64 KB)

```json
{
  "status": 200,
  "headers": {...},
  "contentType": "text/html; charset=utf-8",
  "url": "https://example.com",
  "body": { "kind": "text", "text": "<full body>", "bytes": 12345 }
}
```

For binary content types (no `text/`, `json`, `xml`, `html`, `javascript` in Content-Type), the `kind` is `"bytes"` and `body.base64` holds the bytes.

## Body shape (large payload, >64 KB) — bodyRef

```json
{
  "status": 200,
  "headers": {...},
  "contentType": "application/json",
  "url": "https://api.example.com/data",
  "body": {
    "kind": "bodyRef",
    "bytes": 524288,
    "preview": "{\"items\":[{\"id\":1,…",
    "sidecarPath": "/Users/you/.local/share/interceptor/url_fetch_cache/url_fetch-a1b2c3d4.json",
    "artifactRef": {
      "kind": "artifact",
      "artifactId": "a1b2c3d4",
      "preview": "{\"items\":[{\"id\":1,…",
      "bytes": 524288,
      "contentType": "application/json",
      "url": "https://api.example.com/data"
    }
  }
}
```

The bridge writes the full bytes to the sidecar at `sidecarPath` (mode 0700) and returns a 4 KB preview so the model has enough head-of-content to decide whether to consume the full artifact via a follow-up read.

## Tuning

| Env var | Default | Effect |
|---|---|---|
| `INTERCEPTOR_URL_FETCH_INLINE_THRESHOLD` | `65536` | Bytes above this go to sidecar. Set to `0` to force every response to sidecar. |
| `INTERCEPTOR_URL_FETCH_CACHE_DIR` | `~/.local/share/interceptor/url_fetch_cache/` | Where sidecars land. |

Reads are re-evaluated per request, so operators can `export INTERCEPTOR_URL_FETCH_INLINE_THRESHOLD=0` and rerun without restarting the bridge.

## Cleanup

The cache dir is bounded by disk, not by retention. Operators can run periodic cleanup:

```bash
find ~/.local/share/interceptor/url_fetch_cache -type f -mtime +7 -delete
```
