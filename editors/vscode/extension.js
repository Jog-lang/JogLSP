"use strict";

const fs = require("fs");
const path = require("path");
const vscode = require("vscode");

let client = null;

function firstExisting(candidates) {
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return "";
}

function serverExecutable(context) {
  const configured = vscode.workspace.getConfiguration("jog").get("serverPath");
  return firstExisting([
    configured,
    path.join(context.extensionPath, "bin", "server.exe"),
    path.resolve(context.extensionPath, "..", "..", "server", "out", "server.exe"),
    "D:\\Projects\\Jog\\JogLSP\\server\\out\\server.exe",
  ]);
}

function compilerExecutable() {
  const configured = vscode.workspace.getConfiguration("jog").get("compilerPath");
  return firstExisting([
    configured,
    process.env.JOG,
    "D:\\Projects\\CTools\\build\\jog.exe",
  ]);
}

function activate(context) {
  let LanguageClient;
  try {
    LanguageClient = require("vscode-languageclient/node").LanguageClient;
  } catch (err) {
    vscode.window.showErrorMessage("Jog: the language client is missing. Run npm install in editors/vscode and reinstall the extension.");
    return;
  }

  const server = serverExecutable(context);
  const jog = compilerExecutable();
  const output = vscode.window.createOutputChannel("Jog");
  context.subscriptions.push(output);

  if (!server) {
    vscode.window.showErrorMessage("Jog: language server not found. Build server/out/server.exe or set jog.serverPath.");
    return;
  }
  if (!jog) {
    vscode.window.showErrorMessage("Jog: jog.exe not found. Set jog.compilerPath or the JOG environment variable.");
    return;
  }

  output.appendLine("server: " + server);
  output.appendLine("compiler: " + jog);

  const serverOptions = {
    command: server,
    args: [jog],
    options: { env: Object.assign({}, process.env, { JOG: jog }) },
  };
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "jog" }],
    outputChannel: output,
  };
  client = new LanguageClient("jog", "Jog", serverOptions, clientOptions);
  client.start().catch(function (err) {
    output.appendLine(String(err));
    vscode.window.showErrorMessage("Jog: the language server failed to start. See the Jog output channel.");
  });
  context.subscriptions.push({
    dispose: function () {
      if (client) {
        return client.stop();
      }
      return undefined;
    },
  });
}

function deactivate() {
  if (!client) {
    return undefined;
  }
  return client.stop();
}

module.exports = { activate, deactivate };
