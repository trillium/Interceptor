# fs — Native filesystem

`interceptor macos fs {read, write, search}` exposes Foundation `FileManager` + `UTType` reads/writes plus Spotlight (`NSMetadataQuery`) search. Native, structured — no shelling out to `cat` / `bash`.

## fs_read

```bash
interceptor macos fs read /path/to/file
interceptor macos fs read /path/to/file --byte-range 0,4096
interceptor macos fs read /path/to/file --encoding base64    # for binary
```

Returns: `{ path, content, encoding, size, modified, contentType }` where `contentType` is the UTType identifier (e.g. `public.plain-text`, `public.png`).

## fs_write

```bash
interceptor macos fs write /tmp/notes.txt --content "hello world"
interceptor macos fs write /tmp/blob.bin --base64 "aGVsbG8="
interceptor macos fs write /tmp/log.txt --content "next line\n" --append
```

**Hard-coded denylist** (cannot be disabled):

- `/etc/**`
- `/usr/**`
- `/System/**`
- `/private/var/**`

Writes to these paths return `fs_write: refused (denylist)` regardless of permission rules.

## fs_search (Spotlight)

```bash
interceptor macos fs search "kMDItemDisplayName == 'budget*'"
interceptor macos fs search "Bun" --scope ~/Documents --limit 25
```

Uses `NSMetadataQuery` against the Spotlight index. The `query` argument is either a Spotlight predicate or a free-text term. Results: `{ path, displayName, contentType, size, modified, score }`.

Falls back to a breadth-first enumerator if Spotlight is disabled or the scope is unindexed.
