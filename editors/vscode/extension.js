"use strict";

const path = require("path");
const vscode = require("vscode");
const {
  resolveServerExecutable,
  resolveCompilerExecutable,
} = require("./paths");

let client = null;

function serverExecutable(context) {
  const configured = vscode.workspace.getConfiguration("jog").get("serverPath");
  return resolveServerExecutable(context.extensionPath, configured);
}

function compilerExecutable() {
  const inspected = vscode.workspace.getConfiguration("jog").inspect("compilerPath");
  const explicit = inspected
    ? (inspected.workspaceFolderValue || inspected.workspaceValue || inspected.globalValue || "")
    : "";
  return resolveCompilerExecutable(explicit, process.env.JOG);
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
    vscode.window.showErrorMessage("Jog: language server not found. Build server/out/server (or server.exe) or set jog.serverPath.");
    return;
  }
  if (!jog) {
    vscode.window.showErrorMessage("Jog: jog not found. Set jog.compilerPath or the JOG environment variable.");
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
