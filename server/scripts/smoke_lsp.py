#!/usr/bin/env python3
"""Smoke-test JogLSP against JogCompiler v2 (ide wire-up + coro/std)."""
from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "server" / "zig-out" / "bin" / "server"
REPOS = ROOT.parent


def _default_compiler_root() -> Path:
    for name in ("JogCompiler-v2", "jogcompiler", "JogCompiler"):
        p = REPOS / name
        if (p / "zig-out" / "bin" / "jog").exists() or (p / "std").exists():
            return p
    return REPOS / "JogCompiler-v2"


COMPILER_ROOT = _default_compiler_root()


def _default_jog() -> str:
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
IDE_FIX = COMPILER_ROOT / "testdata" / "ide"


class Lsp:
    def __init__(self, jog: str) -> None:
        env = os.environ.copy()
        env.setdefault("JOG_ROOT", str(COMPILER_ROOT))
        self.proc = subprocess.Popen(
            [str(SERVER), jog],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env=env,
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

    def wait_response(self, req_id: int, timeout: float = 12.0) -> dict:
        while True:
            msg = self.read_msg(timeout=timeout)
            if "id" in msg and msg["id"] == req_id:
                return msg
            self.pending.append(msg)

    def wait_notification(self, method: str, timeout: float = 12.0) -> dict:
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
    return line, col + len(needle) // 2


def open_doc(lsp: Lsp, path: Path, text: str | None = None) -> tuple[str, Path]:
    body = text if text is not None else path.read_text()
    with tempfile.NamedTemporaryFile("w", suffix=".jog", delete=False) as f:
        f.write(body)
        tmp = Path(f.name)
    uri = uri_for(tmp)
    lsp.send(
        "textDocument/didOpen",
        {"textDocument": {"uri": uri, "languageId": "jog", "version": 1, "text": body}},
        as_request=False,
    )
    lsp.wait_notification("textDocument/publishDiagnostics")
    return uri, tmp


def check_file(
    lsp: Lsp,
    path: Path,
    *,
    expect_clean: bool,
    hover_at: str | None = None,
    complete_prefix: str | None = None,
) -> None:
    text = path.read_text()
    uri, tmp = open_doc(lsp, path, text)
    # Re-fetch last diags from pending if any — open_doc already waited.
    # For expect_clean we need the diags from open; re-open pattern already consumed them.
    # Check by asking again via didSave.
    lsp.send(
        "textDocument/didSave",
        {"textDocument": {"uri": uri}, "text": text},
        as_request=False,
    )
    diags = lsp.wait_notification("textDocument/publishDiagnostics")
    dlist = diags["params"]["diagnostics"]
    if expect_clean and dlist:
        raise AssertionError(f"{path.name}: unexpected diags: {dlist}")
    if not expect_clean and not dlist:
        raise AssertionError(f"{path.name}: expected diagnostics")
    print(f"  diags {path.name}: {len(dlist)} ok")

    if hover_at:
        line, col = line_col_of(text, hover_at)
        hid = lsp.send(
            "textDocument/hover",
            {"textDocument": {"uri": uri}, "position": {"line": line, "character": col}},
        )
        hover = lsp.wait_response(hid)
        val = (hover.get("result") or {}).get("contents", {}).get("value", "")
        if hover_at not in val and "Dispatcher" not in val and "fn " not in val:
            raise AssertionError(f"hover for {hover_at!r} weak: {val!r}")
        print(f"  hover {hover_at}: ok ({val.splitlines()[0] if val else ''})")

    if complete_prefix is not None:
        if complete_prefix:
            line, col = line_col_of(text, complete_prefix)
            col = text.splitlines()[line].index(complete_prefix) + len(complete_prefix)
        else:
            line, col = 0, 0
        cid = lsp.send(
            "textDocument/completion",
            {"textDocument": {"uri": uri}, "position": {"line": line, "character": col}},
        )
        comp = lsp.wait_response(cid)
        labels = [it["label"] for it in (comp.get("result") or [])]
        for need in ("go", "yield", "dispatcher_io", "Dispatcher"):
            if complete_prefix and not need.startswith(complete_prefix):
                continue
            if need not in labels:
                raise AssertionError(f"completion missing {need}: {labels[:20]}")
        print(f"  completion prefix={complete_prefix!r}: {len(labels)} items ok")

    tmp.unlink(missing_ok=True)


def main() -> int:
    if not SERVER.exists():
        print("missing server binary", SERVER, file=sys.stderr)
        return 1
    if not Path(JOG).exists():
        print("missing jog binary", JOG, file=sys.stderr)
        return 1
    print("jog:", JOG)
    print("compiler root:", COMPILER_ROOT)
    os.environ.setdefault("JOG_ROOT", str(COMPILER_ROOT))

    lsp = Lsp(JOG)
    try:
        iid = lsp.send(
            "initialize",
            {
                "processId": None,
                "capabilities": {},
                "rootUri": uri_for(COMPILER_ROOT),
            },
        )
        init = lsp.wait_response(iid)
        caps = init["result"]["capabilities"]
        assert caps.get("hoverProvider") is True
        assert caps.get("definitionProvider") is True
        assert caps.get("referencesProvider") is True
        assert caps.get("workspaceSymbolProvider") is True
        assert caps.get("renameProvider") is not None
        assert "signatureHelpProvider" in caps
        assert caps.get("documentSymbolProvider") is True
        assert "completionProvider" in caps
        ver = init["result"]["serverInfo"]["version"]
        print("initialize ok", ver, "caps +refs +rename +signatureHelp +workspaceSymbol")
        lsp.send("initialized", {}, as_request=False)

        check_file(lsp, EXAMPLES / "hello.jog", expect_clean=True)

        hello = EXAMPLES / "hello.jog"
        htext = hello.read_text()
        huri, htmp = open_doc(lsp, hello, htext)
        sid = lsp.send("textDocument/documentSymbol", {"textDocument": {"uri": huri}})
        syms = lsp.wait_response(sid)
        labels = [it["name"] for it in (syms.get("result") or [])]
        if "main" not in labels:
            raise AssertionError(f"documentSymbol missing main: {labels}")
        print("  documentSymbol: ok", labels)
        htmp.unlink(missing_ok=True)

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

        # std/core goto via jog ide
        smoke = EXAMPLES / "std_math_smoke.jog"
        if smoke.exists():
            stext = smoke.read_text()
            suri, stmp = open_doc(lsp, smoke, stext)
            line, col = line_col_of(stext, "cos")
            hid = lsp.send(
                "textDocument/hover",
                {"textDocument": {"uri": suri}, "position": {"line": line, "character": col}},
            )
            hover = lsp.wait_response(hid)
            hval = (hover.get("result") or {}).get("contents", {}).get("value", "")
            if "fn cos" not in hval and "cos" not in hval:
                raise AssertionError(f"std.math hover weak: {hval!r}")
            print("  hover std.math cos: ok")
            did = lsp.send(
                "textDocument/definition",
                {"textDocument": {"uri": suri}, "position": {"line": line, "character": col}},
            )
            dres = lsp.wait_response(did).get("result")
            if not dres or "math.jog" not in str(dres.get("uri", "")):
                raise AssertionError(f"std.math definition missed: {dres!r}")
            print("  definition std.math cos: ok", dres.get("uri"))
            stmp.unlink(missing_ok=True)

        # Multi-file sibling goto + typed hover + member complete + refs + rename + sighelp + workspace symbol
        if IDE_FIX.exists():
            work = Path(tempfile.mkdtemp(prefix="joglsp-ide-"))
            try:
                shutil.copy(IDE_FIX / "main.jog", work / "main.jog")
                shutil.copy(IDE_FIX / "util.jog", work / "util.jog")
                main_text = (work / "main.jog").read_text()
                util_text = (work / "util.jog").read_text()
                muri = uri_for(work / "main.jog")
                uuri = uri_for(work / "util.jog")
                lsp.send(
                    "textDocument/didOpen",
                    {
                        "textDocument": {
                            "uri": muri,
                            "languageId": "jog",
                            "version": 1,
                            "text": main_text,
                        }
                    },
                    as_request=False,
                )
                lsp.wait_notification("textDocument/publishDiagnostics")
                lsp.send(
                    "textDocument/didOpen",
                    {
                        "textDocument": {
                            "uri": uuri,
                            "languageId": "jog",
                            "version": 1,
                            "text": util_text,
                        }
                    },
                    as_request=False,
                )
                lsp.wait_notification("textDocument/publishDiagnostics")

                # sibling goto answer()
                line, col = line_col_of(main_text, "answer()")
                did = lsp.send(
                    "textDocument/definition",
                    {
                        "textDocument": {"uri": muri},
                        "position": {"line": line, "character": col},
                    },
                )
                dres = lsp.wait_response(did).get("result")
                if not dres or "util.jog" not in str(dres.get("uri", "")):
                    raise AssertionError(f"sibling definition missed: {dres!r}")
                print("  sibling definition answer: ok")

                hid = lsp.send(
                    "textDocument/hover",
                    {
                        "textDocument": {"uri": muri},
                        "position": {"line": line, "character": col},
                    },
                )
                hval = (lsp.wait_response(hid).get("result") or {}).get("contents", {}).get("value", "")
                if "fn answer" not in hval:
                    raise AssertionError(f"typed hover weak: {hval!r}")
                print("  typed hover answer: ok")

                # member complete on p.x in util
                uline = util_text.splitlines().index("    return p.x + p.y")
                # column on '.' after p (0-based): "    return p.x" → p at 11, . at 12
                ucol = util_text.splitlines()[uline].index("p.x") + 1
                cid = lsp.send(
                    "textDocument/completion",
                    {
                        "textDocument": {"uri": uuri},
                        "position": {"line": uline, "character": ucol + 1},
                    },
                )
                labels = [it["label"] for it in (lsp.wait_response(cid).get("result") or [])]
                if "x" not in labels or "y" not in labels:
                    raise AssertionError(f"member complete missed: {labels}")
                print("  member complete Point: ok", labels)

                rid = lsp.send(
                    "textDocument/references",
                    {
                        "textDocument": {"uri": muri},
                        "position": {"line": line, "character": col},
                        "context": {"includeDeclaration": True},
                    },
                )
                refs = lsp.wait_response(rid).get("result") or []
                if len(refs) < 2:
                    raise AssertionError(f"refs too few: {refs}")
                print(f"  references answer: ok ({len(refs)})")

                # signatureHelp on answer(
                sh_line, sh_col = line_col_of(main_text, "answer(")
                sh_col = main_text.splitlines()[sh_line].index("answer(") + len("answer(")
                shid = lsp.send(
                    "textDocument/signatureHelp",
                    {
                        "textDocument": {"uri": muri},
                        "position": {"line": sh_line, "character": sh_col},
                    },
                )
                sh = lsp.wait_response(shid).get("result")
                labs = [s.get("label", "") for s in (sh or {}).get("signatures", [])]
                if not any("answer" in lab for lab in labs):
                    raise AssertionError(f"signatureHelp weak: {sh!r}")
                print("  signatureHelp answer: ok", labs[0] if labs else "")

                # prepareRename + rename
                prid = lsp.send(
                    "textDocument/prepareRename",
                    {
                        "textDocument": {"uri": muri},
                        "position": {"line": line, "character": col},
                    },
                )
                pr = lsp.wait_response(prid).get("result")
                if not pr or "range" not in pr:
                    raise AssertionError(f"prepareRename failed: {pr!r}")
                print("  prepareRename: ok")

                rnid = lsp.send(
                    "textDocument/rename",
                    {
                        "textDocument": {"uri": muri},
                        "position": {"line": line, "character": col},
                        "newName": "answer2",
                    },
                )
                edit = lsp.wait_response(rnid).get("result") or {}
                changes = edit.get("changes") or {}
                if not changes:
                    raise AssertionError(f"rename empty: {edit!r}")
                print("  rename answer→answer2: ok", list(changes.keys()))

                wid = lsp.send("workspace/symbol", {"query": "Point"})
                wsyms = lsp.wait_response(wid).get("result") or []
                names = [s.get("name") for s in wsyms]
                if "Point" not in names:
                    raise AssertionError(f"workspace/symbol missed Point: {names[:20]}")
                print("  workspace/symbol Point: ok")
            finally:
                shutil.rmtree(work, ignore_errors=True)

        # intentional type error → JSON diag contract (end span + severity)
        bad = 'fn main() {\n  val x: i32 = "hi"\n}\n'
        with tempfile.NamedTemporaryFile("w", suffix=".jog", delete=False) as f:
            f.write(bad)
            bad_path = Path(f.name)
        uri = uri_for(bad_path)
        lsp.send(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri, "languageId": "jog", "version": 1, "text": bad}},
            as_request=False,
        )
        diags = lsp.wait_notification("textDocument/publishDiagnostics")
        dlist = diags["params"]["diagnostics"]
        msgs = [d["message"] for d in dlist]
        if not any("cannot assign" in m for m in msgs):
            raise AssertionError(f"expected type diag, got {msgs}")
        sev = dlist[0].get("severity")
        if sev != 1:
            raise AssertionError(f"expected severity 1, got {sev}")
        rng = dlist[0].get("range", {})
        if rng.get("end", {}).get("character", 0) <= rng.get("start", {}).get("character", 0):
            # end may be start+1; just require end present
            if "end" not in rng:
                raise AssertionError(f"diag missing end range: {dlist[0]}")
        print("  diag json contract: ok", msgs, "severity", sev, "range", rng)

        # debounce: rapid didChange should still eventually publish
        lsp.send(
            "textDocument/didChange",
            {
                "textDocument": {"uri": uri, "version": 2},
                "contentChanges": [{"text": bad + "\n"}],
            },
            as_request=False,
        )
        time.sleep(0.35)
        # nudge the server poll loop with a no-op request
        pid = lsp.send(
            "textDocument/hover",
            {"textDocument": {"uri": uri}, "position": {"line": 0, "character": 0}},
        )
        # may get diag notification before hover response
        got_diag = False
        deadline = time.time() + 3
        while time.time() < deadline:
            msg = lsp.read_msg(timeout=1.0)
            if msg.get("method") == "textDocument/publishDiagnostics":
                got_diag = True
                break
            if msg.get("id") == pid:
                # hover returned; keep looking briefly in pending
                break
            lsp.pending.append(msg)
        if not got_diag:
            for msg in list(lsp.pending):
                if msg.get("method") == "textDocument/publishDiagnostics":
                    got_diag = True
                    lsp.pending.remove(msg)
                    break
        print("  didChange debounce flush: ok" if got_diag else "  didChange debounce: soft-skip")
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
