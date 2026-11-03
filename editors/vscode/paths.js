"use strict";

const fs = require("fs");
const path = require("path");

function firstExisting(candidates) {
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return "";
}

function withExeSuffix(basePath) {
  // Windows packages historically used server.exe; Linux/macOS use server.
  return [basePath, basePath + ".exe"];
}

function resolveServerExecutable(extensionPath, configured) {
  const bundled = path.join(extensionPath, "bin", "server");
  const checkout = path.resolve(extensionPath, "..", "..", "server", "out", "server");
  return firstExisting([
    configured,
    ...withExeSuffix(bundled),
    ...withExeSuffix(checkout),
  ]);
}

function resolveCompilerExecutable(explicit, envJog, home) {
  const homeDir = home || process.env.HOME || process.env.USERPROFILE || "";
  return firstExisting([
    explicit,
    envJog,
    path.join(homeDir, ".local", "bin", "jog"),
    "D:\\Projects\\Jog\\JogCompiler\\build\\jog.exe",
  ]);
}

module.exports = {
  firstExisting,
  withExeSuffix,
  resolveServerExecutable,
  resolveCompilerExecutable,
};
