"""The subprocess seam (port of cli/mcp/adapter.ts).

Every tool call shells out to the `interceptor` CLI. The binary is taken from
INTERCEPTOR_BIN (default: `interceptor` on PATH). Never raises.
"""

from __future__ import annotations

import os
import subprocess
from typing import NamedTuple, Optional


class RunResult(NamedTuple):
    stdout: str
    stderr: str
    code: int


def _dec(b: Optional[bytes]) -> str:
    return (b or b"").decode("utf-8", "replace")


def run_interceptor(args: list[str], timeout_ms: Optional[int] = None) -> RunResult:
    cmd = [os.environ.get("INTERCEPTOR_BIN") or "interceptor", *args]
    timeout = timeout_ms / 1000 if timeout_ms and timeout_ms > 0 else None
    try:
        p = subprocess.run(cmd, capture_output=True, stdin=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return RunResult(_dec(e.stdout), _dec(e.stderr) + f"\n[interceptor-mcp] killed after {timeout_ms}ms", 124)
    except OSError as e:
        return RunResult("", f"failed to spawn interceptor: {e}", 127)
    return RunResult(_dec(p.stdout), _dec(p.stderr), p.returncode)


def warm_daemon() -> None:
    """Best-effort: `interceptor contexts` makes the CLI auto-spawn the daemon."""
    try:
        run_interceptor(["contexts"], 20_000)
    except Exception:
        pass


def with_global_flags(
    args: list[str],
    group: Optional[str] = None,
    context: Optional[str] = None,
    tab: Optional[float] = None,
    device: Optional[str] = None,
    session: Optional[str] = None,
) -> list[str]:
    out = list(args)
    if group and "--group" not in out:
        out += ["--group", group]
    if context and "--context" not in out:
        out += ["--context", context]
    if tab is not None and "--tab" not in out:
        out += ["--tab", str(int(tab)) if float(tab).is_integer() else str(tab)]
    if device and "--on" not in out and "--context" not in out:
        out += ["--on", device]
    if session and "--session" not in out:
        out += ["--session", session]
    return out
