#!/usr/bin/env python3
"""Smoke-test JogLSP against JogCompiler v2 (hello + coro examples)."""
from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "server" / "zig-out" / "bin" / "server"
COMPILER_ROOT = ROOT.parent / "JogCompiler-v2"
def _default_jog() -> str:
    # Prefer the sibling JogCompiler-v2 tip for smoke; JOG in cloud shells may be a backup.
    if os.environ.get("JOG_LSP_SMOKE"):
        return os.environ["JOG_LSP_SMOKE"]
    preferred = [
        COMPILER_ROOT / "zig-out" / "bin" / "jog",
        Path.home() / ".local/bin/jog-v2",
    ]
    for p in preferred:
        if p.exists():
            return str(p)
    env = os.environ.get("JOG")
    if env and Path(env).exists():
        return env
    return str(preferred[0])


JOG = _default_jog()
EXAMPLES = COMPILER_ROOT / "examples"


class Lsp:
    def __init__(self, jog: str) -> None:
        self.proc = subprocess.Popen(
            [str(SERVER), jog],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self._id = 0
        self.pending: list[dict] = []
        self._buf = b""

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def send(self, method: str, params=None, *, as_request: bool = True):
        msg: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        req_id = None
        if as_request:
            self._id += 1
            req_id = self._id
            msg["id"] = req_id
        raw = json.dumps(msg).encode()
        header = f"Content-Length: {len(raw)}\r\n\r\n".encode()
        assert self.proc.stdin is not None
        self.proc.stdin.write(header + raw)
        self.proc.stdin.flush()
        return req_id

    def _read_some(self, n: int = 4096) -> bytes:
        assert self.proc.stdout is not None
        return os.read(self.proc.stdout.fileno(), n)

    def read_msg(self, timeout: float = 5.0) -> dict:
        assert self.proc.stdout is not None
        while b"\r\n\r\n" not in self._buf:
            r, _, _ = select.select([self.proc.stdout], [], [], timeout)
            if not r:
                err = b""
                if self.proc.stderr is not None:
                    try:
                        err = os.read(self.proc.stderr.fileno(), 4096)
                    except Exception:
                        pass
                raise TimeoutError(f"header timeout; stderr={err!r}")
            chunk = self._read_some()
            if not chunk:
                raise EOFError("server closed")
            self._buf += chunk
        header, rest = self._buf.split(b"\r\n\r\n", 1)
        length = None
        for line in header.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        assert length is not None
        body = rest
        while len(body) < length:
            r, _, _ = select.select([self.proc.stdout], [], [], 5.0)
            if not r:
                raise TimeoutError("body timeout")
            chunk = self._read_some(length - len(body))
            if not chunk:
                raise EOFError("server closed mid-body")
            body += chunk
        self._buf = body[length:]
        return json.loads(body[:length])

    def wait_response(self, req_id: int, timeout: float = 8.0) -> dict:
        while True:
            msg = self.read_msg(timeout=timeout)
            if "id" in msg and msg["id"] == req_id:
                return msg
            self.pending.append(msg)

    def wait_notification(self, method: str, timeout: float = 8.0) -> dict:
        for i, msg in enumerate(self.pending):
            if msg.get("method") == method:
                return self.pending.pop(i)
        while True:
            msg = self.read_msg(timeout=timeout)
            if msg.get("method") == method:
                return msg
            if "id" in msg:
                self.pending.append(msg)


def uri_for(path: Path) -> str:
    return "file://" + str(path.resolve())


def line_col_of(text: str, needle: str) -> tuple[int, int]:
    idx = text.index(needle)
    line = text.count("\n", 0, idx)
    col = idx - (text.rfind("\n", 0, idx) + 1)
    # character inside the identifier
    return line, col + len(needle) // 2


def check_file(lsp: Lsp, path: Path, *, expect_clean: bool, hover_at: str | None = None, complete_prefix: str | None = None) -> None:
    text = path.read_text()
    # Work in a temp copy under /tmp so LSP temp files are writable
    with tempfile.NamedTemporaryFile("w", suffix=".jog", delete=False) as f:
        f.write(text)
        tmp = Path(f.name)
    uri = uri_for(tmp)
    lsp.send("textDocument/didOpen", {
        "textDocument": {"uri": uri, "languageId": "jog", "version": 1, "text": text},
    }, as_request=False)
    diags = lsp.wait_notification("textDocument/publishDiagnostics")
    dlist = diags["params"]["diagnostics"]
    if expect_clean and dlist:
        raise AssertionError(f"{path.name}: unexpected diags: {dlist}")
    if not expect_clean and not dlist:
        raise AssertionError(f"{path.name}: expected diagnostics")
    print(f"  diags {path.name}: {len(dlist)} ok")

    if hover_at:
        line, col = line_col_of(text, hover_at)
        hid = lsp.send("textDocument/hover", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": col},
        })
        hover = lsp.wait_response(hid)
        val = (hover.get("result") or {}).get("contents", {}).get("value", "")
        if hover_at not in val and "Dispatcher" not in val and "fn " not in val:
            raise AssertionError(f"hover for {hover_at!r} weak: {val!r}")
        print(f"  hover {hover_at}: ok ({val.splitlines()[0] if val else ''})")

    if complete_prefix is not None:
        # place cursor after prefix at end of a synthetic line — use first occurrence end
        if complete_prefix:
            line, col = line_col_of(text, complete_prefix)
            col = text.splitlines()[line].index(complete_prefix) + len(complete_prefix)
        else:
            line, col = 0, 0
        cid = lsp.send("textDocument/completion", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": col},
        })
        comp = lsp.wait_response(cid)
        labels = [it["label"] for it in (comp.get("result") or [])]
        for need in ("go", "yield", "dispatcher_io", "Dispatcher"):
            if need not in labels and (not complete_prefix or need.startswith(complete_prefix)):
                # when prefix filters, only require matching ones
                if complete_prefix and not need.startswith(complete_prefix):
                    continue
                if not complete_prefix or need.startswith(complete_prefix):
                    if need not in labels:
                        raise AssertionError(f"completion missing {need}: {labels[:20]}")
        print(f"  completion prefix={complete_prefix!r}: {len(labels)} items ok")

    tmp.unlink(missing_ok=True)


def main() -> int:
    if not SERVER.exists():
        print("missing server binary", SERVER, file=sys.stderr)
        return 1
    print("jog:", JOG)
    lsp = Lsp(JOG)
    try:
        iid = lsp.send("initialize", {
            "processId": None,
            "capabilities": {},
            "rootUri": None,
        })
        init = lsp.wait_response(iid)
        caps = init["result"]["capabilities"]
        assert caps.get("hoverProvider") is True
        assert caps.get("definitionProvider") is True
        assert "completionProvider" in caps
        ver = init["result"]["serverInfo"]["version"]
        print("initialize ok", ver, "caps completion+hover+definition")
        lsp.send("initialized", {}, as_request=False)

        check_file(lsp, EXAMPLES / "hello.jog", expect_clean=True)
        check_file(
            lsp,
            EXAMPLES / "coro_yield.jog",
            expect_clean=True,
            hover_at="yield",
            complete_prefix="dispatcher",
        )
        check_file(
            lsp,
            EXAMPLES / "coro_with_dispatcher.jog",
            expect_clean=True,
            hover_at="with",
        )
        check_file(
            lsp,
            EXAMPLES / "coro_io_dispatcher.jog",
            expect_clean=True,
            hover_at="dispatcher_io",
            complete_prefix="",
        )

        # intentional type error → JSON diag contract
        bad = "fn main() {\n  val x: i32 = \"hi\"\n}\n"
        with tempfile.NamedTemporaryFile("w", suffix=".jog", delete=False) as f:
            f.write(bad)
            bad_path = Path(f.name)
        uri = uri_for(bad_path)
        lsp.send("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "jog", "version": 1, "text": bad},
        }, as_request=False)
        diags = lsp.wait_notification("textDocument/publishDiagnostics")
        msgs = [d["message"] for d in diags["params"]["diagnostics"]]
        if not any("cannot assign" in m for m in msgs):
            raise AssertionError(f"expected type diag, got {msgs}")
        print("  diag json contract: ok", msgs)
        bad_path.unlink(missing_ok=True)

        sid = lsp.send("shutdown")
        lsp.wait_response(sid)
        lsp.send("exit", as_request=False)
        lsp.proc.wait(timeout=3)
        print("SMOKE OK")
        return 0
    finally:
        lsp.close()


if __name__ == "__main__":
    sys.exit(main())
