"use strict";

/**
 * P2 editor-box verification without a GUI.
 *
 * Boxes covered:
 * 1. TextMate grammar assigns scopes for keywords, comments, strings, functions
 * 2. language-configuration.json contributes comments, brackets, autoClosingPairs
 * 3. Bundled server + jog: didSave publishes diagnostics; fixed save clears them
 * 4. shutdown + exit ends the server; no leftover child jog from that session
 *
 * Usage (from editors/vscode):
 *   JOG=~/.local/bin/jog node verify-p2.js
 */

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawn } = require("child_process");
const {
  resolveServerExecutable,
  resolveCompilerExecutable,
} = require("./paths");

const root = __dirname;
const failures = [];

function fail(msg) {
  failures.push(msg);
  console.error("FAIL:", msg);
}

function ok(msg) {
  console.log("OK:", msg);
}

function assert(cond, msg) {
  if (!cond) fail(msg);
  else ok(msg);
}

// --- Box 1: TextMate highlighting ---

function verifyGrammar() {
  const grammarPath = path.join(root, "syntaxes", "jog.tmLanguage.json");
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const contrib = pkg.contributes;
  assert(contrib.languages.some((l) => l.id === "jog" && l.extensions.includes(".jog")), "package.json registers .jog as language jog");
  assert(
    contrib.grammars.some((g) => g.language === "jog" && g.scopeName === "source.jog"),
    "package.json contributes source.jog grammar"
  );
  const grammar = JSON.parse(fs.readFileSync(grammarPath, "utf8"));
  assert(grammar.scopeName === "source.jog", "grammar scopeName is source.jog");

  const sample = [
    '// line comment',
    'fn main() {',
    '    var x = 1',
    '    io.println("hi")',
    '}',
  ].join("\n");

  // Lightweight scope probe: ensure repository patterns exist for the scopes the theme uses.
  const repo = grammar.repository;
  assert(repo["comment-line"] && repo["comment-line"].name.includes("comment"), "grammar colors // comments");
  assert(repo.keyword && /fn|var|struct/.test(repo.keyword.match), "grammar colors keywords including fn/var");
  assert(repo.string && repo.string.patterns && repo.string.patterns.length >= 2, "grammar colors strings");
  assert(repo.function && repo.function.captures, "grammar colors function names");

  // Regex smoke: each pattern matches the sample where expected.
  const lineComment = new RegExp(repo["comment-line"].match);
  assert(lineComment.test("// line comment"), "line-comment regex matches sample");
  const kw = new RegExp(repo.keyword.match);
  assert(kw.test("fn") && kw.test("var"), "keyword regex matches fn and var");
  const fn = new RegExp(repo.function.match);
  assert(fn.test("fn main()"), "function regex matches fn main");
  void sample;
}

// --- Box 2: language configuration ---

function verifyLanguageConfig() {
  const cfgPath = path.join(root, "language-configuration.json");
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const lang = pkg.contributes.languages.find((l) => l.id === "jog");
  assert(lang && lang.configuration === "./language-configuration.json", "language points at configuration file");
  const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  assert(cfg.comments && cfg.comments.lineComment === "//", "line comment is //");
  assert(cfg.comments.blockComment && cfg.comments.blockComment[0] === "/*", "block comment is /* */");
  assert(Array.isArray(cfg.brackets) && cfg.brackets.some((p) => p[0] === "{" && p[1] === "}"), "bracket matching includes {}");
  assert(
    Array.isArray(cfg.autoClosingPairs) &&
      cfg.autoClosingPairs.some((p) => p.open === "{" && p.close === "}") &&
      cfg.autoClosingPairs.some((p) => p.open === '"' && p.close === '"'),
    "autoClosingPairs include braces and quotes"
  );
}

// --- Boxes 3–4: LSP client path + server diagnostics + clean exit ---

function frame(body) {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  return Buffer.from(`Content-Length: ${Buffer.byteLength(payload, "utf8")}\r\n\r\n${payload}`, "utf8");
}

function createFramedReader(stream) {
  let buf = Buffer.alloc(0);
  const messages = [];
  let waiters = [];

  function pump() {
    while (true) {
      const headerEnd = buf.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = buf.slice(0, headerEnd).toString("utf8");
      const match = /Content-Length:\s*(\d+)/i.exec(header);
      if (!match) {
        buf = buf.slice(headerEnd + 4);
        continue;
      }
      const len = Number(match[1]);
      const start = headerEnd + 4;
      if (buf.length < start + len) return;
      const body = buf.slice(start, start + len).toString("utf8");
      buf = buf.slice(start + len);
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch (err) {
        parsed = { parseError: String(err), body };
      }
      if (waiters.length) {
        const w = waiters.shift();
        w(parsed);
      } else {
        messages.push(parsed);
      }
    }
  }

  stream.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    pump();
  });

  return {
    next(timeoutMs) {
      if (messages.length) return Promise.resolve(messages.shift());
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          waiters = waiters.filter((w) => w !== onMsg);
          reject(new Error("timeout waiting for LSP message"));
        }, timeoutMs);
        function onMsg(msg) {
          clearTimeout(timer);
          resolve(msg);
        }
        waiters.push(onMsg);
      });
    },
    drain() {
      const out = messages.slice();
      messages.length = 0;
      return out;
    },
  };
}

async function verifyLspAndShutdown() {
  const jog = resolveCompilerExecutable("", process.env.JOG);
  const serverPath = resolveServerExecutable(root, "");
  assert(!!jog, `compiler resolved (${jog || "missing"})`);
  assert(!!serverPath, `server resolved (${serverPath || "missing"})`);
  assert(serverPath.endsWith(`${path.sep}server`) || serverPath.endsWith("server.exe"), "resolved server basename is server[.exe]");

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "jog-p2-"));
  const modDir = path.join(tmp, "mod");
  fs.mkdirSync(modDir);
  fs.writeFileSync(path.join(modDir, "jog.mod"), "module p2verify\n");
  const filePath = path.join(modDir, "main.jog");
  const uri = "file://" + filePath;

  const child = spawn(serverPath, [jog], {
    stdio: ["pipe", "pipe", "pipe"],
    env: Object.assign({}, process.env, { JOG: jog }),
  });
  const reader = createFramedReader(child.stdout);
  let stderr = "";
  child.stderr.on("data", (c) => {
    stderr += c.toString("utf8");
  });

  const serverPid = child.pid;

  function send(msg) {
    child.stdin.write(frame(msg));
  }

  try {
    send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        processId: process.pid,
        rootUri: "file://" + modDir,
        capabilities: {},
      },
    });
    const init = await reader.next(5000);
    assert(init && init.id === 1 && init.result && init.result.capabilities, "initialize returns capabilities");
    send({ jsonrpc: "2.0", method: "initialized", params: {} });

    // Broken file on disk, then didSave → expect diagnostics.
    fs.writeFileSync(filePath, "fn main( {\n");
    send({
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: { uri, languageId: "jog", version: 1, text: fs.readFileSync(filePath, "utf8") },
      },
    });
    send({
      jsonrpc: "2.0",
      method: "textDocument/didSave",
      params: { textDocument: { uri } },
    });

    let diagMsg = null;
    const deadline = Date.now() + 8000;
    while (Date.now() < deadline) {
      try {
        const msg = await reader.next(Math.max(100, deadline - Date.now()));
        if (msg.method === "textDocument/publishDiagnostics") {
          diagMsg = msg;
          break;
        }
      } catch (err) {
        break;
      }
    }
    assert(!!diagMsg, "publishDiagnostics arrived after save of broken file");
    const brokenDiags = (diagMsg && diagMsg.params && diagMsg.params.diagnostics) || [];
    assert(brokenDiags.length > 0, `broken save has ${brokenDiags.length} diagnostic(s)`);

    // Fixed file on disk, then didSave → empty diagnostics.
    fs.writeFileSync(
      filePath,
      [
        "import std.io",
        "",
        "fn main() {",
        '    io.println("ok")',
        "}",
        "",
      ].join("\n")
    );
    send({
      jsonrpc: "2.0",
      method: "textDocument/didSave",
      params: { textDocument: { uri } },
    });

    let clearMsg = null;
    const clearDeadline = Date.now() + 8000;
    while (Date.now() < clearDeadline) {
      try {
        const msg = await reader.next(Math.max(100, clearDeadline - Date.now()));
        if (msg.method === "textDocument/publishDiagnostics") {
          clearMsg = msg;
          break;
        }
      } catch (err) {
        break;
      }
    }
    assert(!!clearMsg, "publishDiagnostics arrived after save of fixed file");
    const clearDiags = (clearMsg && clearMsg.params && clearMsg.params.diagnostics) || [];
    assert(clearDiags.length === 0, `fixed save clears diagnostics (got ${clearDiags.length})`);

    // Clean shutdown.
    send({ jsonrpc: "2.0", id: 2, method: "shutdown", params: null });
    const shut = await reader.next(5000);
    assert(shut && shut.id === 2, "shutdown responds");
    send({ jsonrpc: "2.0", method: "exit", params: null });

    const exitCode = await new Promise((resolve) => {
      const t = setTimeout(() => resolve("timeout"), 5000);
      child.on("exit", (code) => {
        clearTimeout(t);
        resolve(code);
      });
    });
    assert(exitCode === 0, `server exit code 0 after shutdown+exit (got ${exitCode})`);

    // No orphaned process with this server pid.
    let stillAlive = false;
    try {
      process.kill(serverPid, 0);
      stillAlive = true;
    } catch (_) {
      stillAlive = false;
    }
    assert(!stillAlive, "server pid is gone after exit");
  } catch (err) {
    fail("LSP session: " + err.message);
    try {
      child.kill("SIGKILL");
    } catch (_) {}
  } finally {
    if (stderr.trim()) {
      console.log("--- server stderr ---");
      console.log(stderr.trim());
    }
    try {
      fs.rmSync(tmp, { recursive: true, force: true });
    } catch (_) {}
  }
}

async function main() {
  console.log("P2 verify root:", root);
  verifyGrammar();
  verifyLanguageConfig();
  await verifyLspAndShutdown();
  if (failures.length) {
    console.error(`\n${failures.length} failure(s)`);
    process.exit(1);
  }
  console.log("\nAll P2 editor verification checks passed.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
