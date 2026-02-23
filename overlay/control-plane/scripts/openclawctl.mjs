#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const stateDir = process.env.CONTROL_PLANE_STATE_DIR || path.resolve("control-plane/state");
const runtimeDir = process.env.OPENCLAW_RUNTIME_DIR || path.resolve("control-plane/state/runtime");
const encPath = path.join(stateDir, "secrets.enc");
const runtimeEnvPath = path.join(stateDir, ".env.runtime");
const runtimeAuthPath = path.join(runtimeDir, "auth-profiles.json");

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function enforcePrivate(pathname) {
  if (process.platform === "win32") {
    return;
  }
  fs.chmodSync(pathname, 0o600);
}

function getArg(flag) {
  const i = process.argv.indexOf(flag);
  if (i === -1 || i + 1 >= process.argv.length) return undefined;
  return process.argv[i + 1];
}

function requirePassphrase() {
  const passphrase = getArg("--passphrase") || process.env.OPENCLAW_PASSPHRASE;
  if (!passphrase) {
    throw new Error("Missing passphrase. Use --passphrase or OPENCLAW_PASSPHRASE.");
  }
  return passphrase;
}

function sealPayload(payload, passphrase) {
  const salt = crypto.randomBytes(16);
  const iv = crypto.randomBytes(12);
  const key = crypto.scryptSync(passphrase, salt, 32);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const plaintext = Buffer.from(JSON.stringify(payload), "utf8");
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    version: 1,
    kdf: "scrypt",
    cipher: "aes-256-gcm",
    salt: salt.toString("base64"),
    iv: iv.toString("base64"),
    tag: tag.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
  };
}

function unsealPayload(blob, passphrase) {
  const salt = Buffer.from(blob.salt, "base64");
  const iv = Buffer.from(blob.iv, "base64");
  const tag = Buffer.from(blob.tag, "base64");
  const ciphertext = Buffer.from(blob.ciphertext, "base64");
  const key = crypto.scryptSync(passphrase, salt, 32);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
  return JSON.parse(plaintext);
}

function writeSecrets(blob) {
  ensureDir(stateDir);
  fs.writeFileSync(encPath, `${JSON.stringify(blob, null, 2)}\n`, { encoding: "utf8" });
  enforcePrivate(encPath);
}

function readSecrets() {
  if (!fs.existsSync(encPath)) {
    throw new Error(`Missing ${encPath}`);
  }
  return JSON.parse(fs.readFileSync(encPath, "utf8"));
}

function lockRuntime() {
  if (fs.existsSync(runtimeEnvPath)) fs.rmSync(runtimeEnvPath, { force: true });
  if (fs.existsSync(runtimeAuthPath)) fs.rmSync(runtimeAuthPath, { force: true });
}

function writeRuntime(payload) {
  ensureDir(stateDir);
  ensureDir(runtimeDir);

  const envLines = [
    payload.gatewayToken ? `OPENCLAW_GATEWAY_TOKEN=${payload.gatewayToken}` : "",
    payload.gatewayPassword ? `OPENCLAW_GATEWAY_PASSWORD=${payload.gatewayPassword}` : "",
  ].filter(Boolean);
  fs.writeFileSync(runtimeEnvPath, `${envLines.join("\n")}\n`, { encoding: "utf8" });
  enforcePrivate(runtimeEnvPath);

  const auth = payload.openaiCodexAuthProfiles || "{}";
  fs.writeFileSync(runtimeAuthPath, auth.endsWith("\n") ? auth : `${auth}\n`, { encoding: "utf8" });
  enforcePrivate(runtimeAuthPath);
}

function cmdInit() {
  const passphrase = requirePassphrase();
  const gatewayToken = getArg("--gateway-token") || "";
  const gatewayPassword = getArg("--gateway-password") || "";
  const authProfilesFile = getArg("--auth-profiles-file");
  const openaiCodexAuthProfiles = authProfilesFile && fs.existsSync(authProfilesFile)
    ? fs.readFileSync(authProfilesFile, "utf8")
    : "{}\n";
  const blob = sealPayload({ gatewayToken, gatewayPassword, openaiCodexAuthProfiles }, passphrase);
  writeSecrets(blob);
  console.log(`initialized ${encPath}`);
}

function cmdSeal() {
  const passphrase = requirePassphrase();
  const blob = readSecrets();
  let payload = unsealPayload(blob, passphrase);
  const gatewayToken = getArg("--gateway-token");
  const gatewayPassword = getArg("--gateway-password");
  const authProfilesFile = getArg("--auth-profiles-file");

  if (gatewayToken !== undefined) payload.gatewayToken = gatewayToken;
  if (gatewayPassword !== undefined) payload.gatewayPassword = gatewayPassword;
  if (authProfilesFile && fs.existsSync(authProfilesFile)) {
    payload.openaiCodexAuthProfiles = fs.readFileSync(authProfilesFile, "utf8");
  }

  writeSecrets(sealPayload(payload, passphrase));
  console.log(`sealed ${encPath}`);
}

function cmdUnseal() {
  const passphrase = requirePassphrase();
  const payload = unsealPayload(readSecrets(), passphrase);
  writeRuntime(payload);
  console.log("runtime unlocked");
}

function cmdLock() {
  lockRuntime();
  console.log("runtime locked");
}

function cmdStatus() {
  const out = {
    secretsEnc: fs.existsSync(encPath),
    runtimeEnv: fs.existsSync(runtimeEnvPath),
    runtimeAuthProfiles: fs.existsSync(runtimeAuthPath),
  };
  console.log(JSON.stringify(out, null, 2));
}

function main() {
  const command = process.argv[2];
  try {
    if (command === "init") return cmdInit();
    if (command === "seal") return cmdSeal();
    if (command === "unseal") return cmdUnseal();
    if (command === "lock") return cmdLock();
    if (command === "status") return cmdStatus();

    console.error("Usage: openclawctl <init|seal|unseal|lock|status> [--passphrase ...]");
    process.exit(1);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}

main();
