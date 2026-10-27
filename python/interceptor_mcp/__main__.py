"""`python3 -m interceptor_mcp [--no-warm]` — serve MCP over stdio."""

import sys

from . import adapter, server

if __name__ == "__main__":
    if "--no-warm" not in sys.argv[1:]:
        sys.stderr.write("interceptor mcp: warming daemon…\n")
        adapter.warm_daemon()
    sys.stderr.write("interceptor mcp: serving over stdio\n")
    server.serve()
