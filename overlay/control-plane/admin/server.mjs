import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import crypto from "node:crypto";

const stateDir =
  process.env.CONTROL_PLANE_STATE_DIR ||
  (fs.existsSync("/state") ? "/state" : path.resolve("control-plane/state"));
const runtimeDir =
  process.env.OPENCLAW_RUNTIME_DIR ||
  (fs.existsSync("/runtime") ? "/runtime" : path.resolve("control-plane/state/runtime"));
const openclawHome =
  process.env.OPENCLAW_HOME_DIR ||
  (fs.existsSync("/openclaw-home") ? "/openclaw-home" : path.resolve("control-plane/state/openclaw-home"));
const gatewayLog =
  process.env.OPENCLAW_GATEWAY_LOG ||
  (fs.existsSync("/logs/openclaw-gateway.log")
    ? "/logs/openclaw-gateway.log"
    : path.resolve("control-plane/state/openclaw-gateway.log"));
const openclawctl = process.env.OPENCLAWCTL_PATH ||
  (fs.existsSync("/scripts/openclawctl.mjs")
    ? "/scripts/openclawctl.mjs"
    : path.resolve("control-plane/scripts/openclawctl.mjs"));
const projectRoot = process.env.OPENCLAW_PROJECT_ROOT || process.cwd();
const skillsStatePath = path.join(stateDir, "skills-state.json");
const runtimeEnvPath = path.join(stateDir, ".env.runtime");
const backupStatusPath = path.join(stateDir, "backup-status.json");
const defaultSkillsRoot = fs.existsSync(path.join(projectRoot, "skills"))
  ? path.join(projectRoot, "skills")
  : path.join(openclawHome, "skills");
const skillsRoots = (process.env.OPENCLAW_SKILLS_ROOTS || defaultSkillsRoot)
  .split(path.delimiter)
  .filter(Boolean);
const adminPasswordHashKey = "OPENCLAW_ADMIN_PASSWORD_HASH";
const adminPasswordSaltKey = "OPENCLAW_ADMIN_PASSWORD_SALT";
const adminSessionTtlMs = 1000 * 60 * 60 * 24 * 7;
const adminSessionCookie = "openclaw_admin_session";
const adminSessions = new Map();
const forceSecureAdminCookie = process.env.OPENCLAW_ADMIN_COOKIE_SECURE === "1";
const loginWindowMs = 1000 * 60 * 15;
const loginMaxAttempts = 10;
const loginBlockMs = 1000 * 60 * 15;
const loginAttempts = new Map();

const riskyPatterns = [
  { id: "curl-pipe-bash", re: /curl\s+[^\n|]+\|\s*(bash|sh)/i },
  { id: "sudo", re: /\bsudo\b/i },
  { id: "external-download", re: /(wget|Invoke-WebRequest|iwr|curl)\s+https?:\/\//i },
  { id: "credential-scrape", re: /(\.aws\/credentials|id_rsa|ssh-key|token\s*=|password\s*=)/i },
];

function shell(command, args, extraEnv = {}, cwd = projectRoot) {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      cwd,
      env: {
        ...process.env,
        CONTROL_PLANE_STATE_DIR: stateDir,
        OPENCLAW_RUNTIME_DIR: runtimeDir,
        ...extraEnv,
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (buf) => {
      stdout += String(buf);
    });
    child.stderr.on("data", (buf) => {
      stderr += String(buf);
    });
    child.on("error", (error) => {
      stderr += `${error.message}\n`;
      resolve({ code: 1, stdout, stderr });
    });
    child.on("close", (code) => {
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });
}

async function runCtl(args, passphrase) {
  const env = passphrase ? { OPENCLAW_PASSPHRASE: passphrase } : {};
  return shell("node", [openclawctl, ...args], env);
}

function toolResponse(toolName, out) {
  if (out.code === 0) return { status: 200, body: out };
  if (/ENOENT/i.test(out.stderr)) {
    return {
      status: 501,
      body: {
        ...out,
        error: `${toolName} is not available in this container`,
      },
    };
  }
  return { status: 500, body: out };
}

function json(res, status, data) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(`${JSON.stringify(data)}\n`);
}

function ensureRuntimeEnvFile() {
  fs.mkdirSync(path.dirname(runtimeEnvPath), { recursive: true });
  if (!fs.existsSync(runtimeEnvPath)) {
    fs.writeFileSync(runtimeEnvPath, "", "utf8");
  }
}

function readRuntimeEnv() {
  ensureRuntimeEnvFile();
  const content = fs.readFileSync(runtimeEnvPath, "utf8");
  const map = new Map();
  for (const line of content.split(/\r?\n/)) {
    if (!line || line.trim().startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx <= 0) continue;
    map.set(line.slice(0, idx), line.slice(idx + 1));
  }
  return map;
}

function writeRuntimeEnv(nextMap) {
  ensureRuntimeEnvFile();
  const lines = [];
  for (const [k, v] of nextMap.entries()) {
    lines.push(`${k}=${v}`);
  }
  fs.writeFileSync(runtimeEnvPath, `${lines.join("\n")}\n`, "utf8");
}

function normalizeLineEndings(input) {
  return String(input || "").replace(/\r/g, "");
}

function hashPassword(password, salt) {
  return crypto.scryptSync(password, salt, 64).toString("hex");
}

function hasAdminPasswordConfigured() {
  const envMap = readRuntimeEnv();
  const hash = normalizeLineEndings(envMap.get(adminPasswordHashKey) || "");
  const salt = normalizeLineEndings(envMap.get(adminPasswordSaltKey) || "");
  return Boolean(hash && salt);
}

function setAdminPassword(password) {
  const normalized = normalizeLineEndings(password);
  if (!normalized) return false;
  const envMap = readRuntimeEnv();
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = hashPassword(normalized, salt);
  envMap.set(adminPasswordSaltKey, salt);
  envMap.set(adminPasswordHashKey, hash);
  writeRuntimeEnv(envMap);
  return true;
}

function verifyAdminPassword(password) {
  const envMap = readRuntimeEnv();
  const hash = normalizeLineEndings(envMap.get(adminPasswordHashKey) || "");
  const salt = normalizeLineEndings(envMap.get(adminPasswordSaltKey) || "");
  if (!hash || !salt) return false;
  const candidate = hashPassword(normalizeLineEndings(password), salt);
  const a = Buffer.from(hash, "hex");
  const b = Buffer.from(candidate, "hex");
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function parseCookies(req) {
  const raw = req.headers.cookie || "";
  const out = new Map();
  for (const pair of raw.split(";")) {
    const part = pair.trim();
    if (!part) continue;
    const idx = part.indexOf("=");
    if (idx <= 0) continue;
    out.set(part.slice(0, idx), decodeURIComponent(part.slice(idx + 1)));
  }
  return out;
}

function getClientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.trim()) {
    const first = forwarded.split(",")[0]?.trim();
    if (first) return first;
  }
  if (Array.isArray(forwarded) && forwarded.length > 0) {
    const first = forwarded[0]?.split(",")[0]?.trim();
    if (first) return first;
  }
  return req.socket?.remoteAddress || "unknown";
}

function getForwardedProto(req) {
  const proto = req.headers["x-forwarded-proto"];
  if (typeof proto === "string") return proto.split(",")[0]?.trim().toLowerCase() || "";
  if (Array.isArray(proto) && proto.length > 0) {
    return String(proto[0] || "").split(",")[0]?.trim().toLowerCase() || "";
  }
  return "";
}

function shouldUseSecureCookie(req) {
  if (forceSecureAdminCookie) return true;
  return getForwardedProto(req) === "https";
}

function getLoginAttemptState(ip) {
  const now = Date.now();
  const current = loginAttempts.get(ip);
  if (!current) {
    const next = { count: 0, firstAt: now, blockedUntil: 0 };
    loginAttempts.set(ip, next);
    return next;
  }
  if (current.firstAt + loginWindowMs < now) {
    current.count = 0;
    current.firstAt = now;
    current.blockedUntil = 0;
  }
  return current;
}

function registerFailedLogin(ip) {
  const now = Date.now();
  const state = getLoginAttemptState(ip);
  state.count += 1;
  if (state.count >= loginMaxAttempts) {
    state.blockedUntil = now + loginBlockMs;
  }
}

function clearLoginAttempts(ip) {
  loginAttempts.delete(ip);
}

function getRemainingBlockMs(ip) {
  const state = getLoginAttemptState(ip);
  const now = Date.now();
  if (state.blockedUntil > now) return state.blockedUntil - now;
  return 0;
}

function createAdminSession() {
  const token = crypto.randomBytes(32).toString("hex");
  adminSessions.set(token, Date.now());
  return token;
}

function isAdminSessionValid(token) {
  if (!token) return false;
  const createdAt = adminSessions.get(token);
  if (!createdAt) return false;
  if (Date.now() - createdAt > adminSessionTtlMs) {
    adminSessions.delete(token);
    return false;
  }
  return true;
}

function setAdminSessionCookie(req, res, token) {
  const secureFlag = shouldUseSecureCookie(req) ? "; Secure" : "";
  res.setHeader(
    "Set-Cookie",
    `${adminSessionCookie}=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Strict${secureFlag}; Max-Age=${Math.floor(adminSessionTtlMs / 1000)}`,
  );
}

function clearAdminSessionCookie(req, res) {
  const secureFlag = shouldUseSecureCookie(req) ? "; Secure" : "";
  res.setHeader("Set-Cookie", `${adminSessionCookie}=; Path=/; HttpOnly; SameSite=Strict${secureFlag}; Max-Age=0`);
}

function isAuthExemptPath(pathname) {
  if (pathname === "/login") return true;
  if (pathname === "/api/auth/status") return true;
  if (pathname === "/api/auth/login") return true;
  if (pathname === "/api/auth/bootstrap") return true;
  return false;
}

function isLikelyLocalRequest(req) {
  const forwarded = getClientIp(req).toLowerCase();
  const remote = String(req.socket?.remoteAddress || "").toLowerCase();
  return (
    forwarded === "127.0.0.1" ||
    forwarded === "::1" ||
    forwarded === "localhost" ||
    remote === "127.0.0.1" ||
    remote === "::1" ||
    remote === "localhost"
  );
}

function resolveConfigSecret(value, envMap) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  const match = /^\$\{([A-Z0-9_]+)\}$/.exec(trimmed);
  if (!match) return trimmed;
  const key = match[1];
  return normalizeLineEndings(envMap.get(key) || "");
}

function readBackupStatus() {
  if (!fs.existsSync(backupStatusPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(backupStatusPath, "utf8"));
  } catch {
    return null;
  }
}

function text(res, status, data) {
  res.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" });
  res.end(data);
}

function notFound(res) {
  text(res, 404, "Not found\n");
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += String(chunk);
      if (body.length > 1024 * 1024) reject(new Error("body too large"));
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function loadSkillsState() {
  if (!fs.existsSync(skillsStatePath)) {
    return { items: {} };
  }
  try {
    return JSON.parse(fs.readFileSync(skillsStatePath, "utf8"));
  } catch {
    return { items: {} };
  }
}

function saveSkillsState(state) {
  fs.mkdirSync(path.dirname(skillsStatePath), { recursive: true });
  fs.writeFileSync(skillsStatePath, `${JSON.stringify(state, null, 2)}\n`, "utf8");
}

function listSkillDirs() {
  const found = [];
  for (const root of skillsRoots) {
    if (!fs.existsSync(root)) continue;
    const entries = fs.readdirSync(root, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const dir = path.join(root, entry.name);
      const skillFile = path.join(dir, "SKILL.md");
      if (fs.existsSync(skillFile)) found.push({ name: entry.name, root, dir, skillFile });
    }
  }
  return found;
}

function listFilesRecursively(dir, out = []) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      listFilesRecursively(p, out);
    } else if (entry.isFile()) {
      out.push(p);
    }
  }
  return out;
}

function scanRisk(skillDir) {
  const files = listFilesRecursively(skillDir).filter((f) => /\.(md|txt|json|ya?ml|sh|ps1|ts|js|mjs|cjs)$/i.test(f));
  const findings = [];
  for (const file of files) {
    const content = fs.readFileSync(file, "utf8");
    for (const pattern of riskyPatterns) {
      if (pattern.re.test(content)) {
        findings.push({ pattern: pattern.id, file: path.relative(skillDir, file) });
      }
    }
  }
  return findings;
}

function getSkillsView() {
  const state = loadSkillsState();
  const dirs = listSkillDirs();
  const items = dirs.map((skill) => {
    const managed = state.items[skill.name] || {
      status: "quarantine",
      updatedAt: new Date().toISOString(),
    };
    const findings = scanRisk(skill.dir);
    return {
      name: skill.name,
      path: skill.dir,
      root: skill.root,
      status: managed.status,
      updatedAt: managed.updatedAt,
      riskyFindings: findings,
    };
  });

  // Auto-register newly discovered skills as quarantine.
  let changed = false;
  for (const item of items) {
    if (!state.items[item.name]) {
      state.items[item.name] = { status: "quarantine", updatedAt: new Date().toISOString() };
      changed = true;
    }
  }
  if (changed) saveSkillsState(state);

  return items;
}

function updateSkillStatus(name, status) {
  const state = loadSkillsState();
  state.items[name] = { status, updatedAt: new Date().toISOString() };
  saveSkillsState(state);
  return state.items[name];
}

async function probeGateway() {
  const out = await shell("node", ["-e", "fetch('http://openclaw-gateway:18789/').then(r=>console.log(r.status)).catch(()=>process.exit(1))"]);
  return out.code === 0;
}

function renderPage(title, body) {
  return `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${title}</title>
<style>
:root { color-scheme: light; }
body { margin: 0; font-family: "Segoe UI", Tahoma, sans-serif; background: #f5f6fa; color: #1d1f24; }
header { background: #0e2238; color: #fff; padding: 14px 18px; }
main { max-width: 1080px; margin: 20px auto; padding: 0 16px; }
nav { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 18px; }
nav a { background: #fff; border: 1px solid #d8deea; border-radius: 8px; color: #0e2238; padding: 8px 12px; text-decoration: none; }
section { background: #fff; border: 1px solid #d8deea; border-radius: 10px; padding: 16px; margin-bottom: 12px; }
button { background: #0e2238; color: #fff; border: none; border-radius: 8px; padding: 8px 12px; cursor: pointer; }
input, textarea { width: 100%; box-sizing: border-box; border: 1px solid #c4ccdb; border-radius: 8px; padding: 8px; }
pre { background: #f0f3f8; border-radius: 8px; padding: 10px; overflow-x: auto; }
.small { font-size: 12px; color: #61697a; }
</style>
</head>
<body>
<header><strong>OpenClaw Control Plane</strong> (Phase A+)</header>
<main>
<nav>
<a href="/">상태</a>
<a href="/setup">빠른설정</a>
<a href="/unlock">잠금해제</a>
<a href="/secrets">보안저장소</a>
<a href="/config">고급설정</a>
<a href="/skills">스킬</a>
<a href="/security">보안점검</a>
<a href="/logs">로그</a>
<a href="/auth/codex">Codex 인증</a>
<a href="/openclaw/">OpenClaw UI</a>
</nav>
${body}
</main>
</body>
</html>`;
}

function html(res, page) {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(page);
}

function configPath() {
  return path.join(openclawHome, "openclaw.json");
}

function pageStatus() {
  return renderPage(
    "Status",
    `<section><h2>Status</h2><button onclick="refresh()">refresh</button><pre id="out">loading...</pre></section>
<script>
async function refresh() {
  const r = await fetch('/api/status');
  const j = await r.json();
  document.getElementById('out').textContent = JSON.stringify(j, null, 2);
}
refresh();
</script>`,
  );
}

function pageSetup() {
  return renderPage(
    "Setup",
    `<section><h2>초보자 빠른 설정 (원클릭)</h2>
<p class="small">Telegram 연결 + 암호화 백업을 한 번에 설정합니다. 저장 후 반드시 상태 점검을 실행하세요.</p>
<details open>
  <summary><strong>초보자 필수 안내</strong></summary>
  <ol>
    <li>Telegram Bot Token은 BotFather에서 발급합니다.</li>
    <li>Chat/User ID는 숫자여야 합니다. 잘못 입력하면 메시지가 오지 않습니다.</li>
    <li>백업 암호는 복구에 필수입니다. 분실하면 복구할 수 없습니다.</li>
    <li>설정 저장 후 "현재 상태 점검"에서 4개 항목을 확인하세요: setup/gateway/telegram/backup</li>
  </ol>
</details>
<label for="tgToken">Telegram Bot Token</label>
<input id="tgToken" placeholder="예: 123456:ABC..." autocomplete="off" />
<label for="tgChatId" style="margin-top:8px;display:block;">Telegram Chat/User ID</label>
<input id="tgChatId" placeholder="예: 123456789" autocomplete="off" />
<label for="backupPass" style="margin-top:8px;display:block;">백업 암호 (복구 시 필수, 디스크 미저장)</label>
<input id="backupPass" type="password" placeholder="실행 시 직접 입력(디스크 저장 안 함)" autocomplete="new-password" />
<label for="backupInterval" style="margin-top:8px;display:block;">백업 주기 (초)</label>
<input id="backupInterval" type="number" min="60" value="3600" />
<label for="adminPassword" style="margin-top:8px;display:block;">관리자 페이지 비밀번호 (2845 잠금)</label>
<input id="adminPassword" type="password" placeholder="최초 설정 후 2845 접속 시 항상 필요" autocomplete="new-password" />
<div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap;">
  <button onclick="applySetup()">설정 저장/적용</button>
  <button onclick="probeSetup()">현재 상태 점검</button>
</div>
<pre id="out">준비됨</pre>
</section>
<section>
<h3>복구 안내 (중요)</h3>
<p class="small">복구는 최신 백업부터 순차 시도합니다. 복구 시 현재 상태가 교체될 수 있습니다.</p>
<pre>restore-openclaw-soul.bat</pre>
</section>
<script>
function humanizeProbe(data) {
  const checks = data?.checks || {};
  const lines = [];
  lines.push('=== 점검 결과 ===');
  lines.push('setup 감지: ' + (checks.setupDetected ? 'OK' : '미설정'));
  lines.push('영혼백업 감지: ' + (checks.soulBackupDetected ? 'OK' : '없음'));
  if (checks.latestSoulBackup) lines.push('최근 백업: ' + checks.latestSoulBackup);
  lines.push('gateway 연결: ' + (checks.gatewayReachable ? 'OK' : '실패'));
  lines.push('backup 암호 설정: ' + (checks.backupPassphraseConfigured ? 'OK' : '누락'));
  lines.push('backup 상태: ' + (checks.backupStatus?.ok ? '정상' : '실패/미실행'));
  if (checks.telegramProbe?.ok) {
    lines.push('telegram 검증: OK');
  } else {
    lines.push('telegram 검증: 실패');
    if (checks.telegramProbe?.hint) lines.push('조치: ' + checks.telegramProbe.hint);
    else if (checks.telegramProbe?.error) lines.push('오류: ' + checks.telegramProbe.error);
  }
  lines.push('');
  lines.push('원본 JSON:');
  lines.push(JSON.stringify(data, null, 2));
  return lines.join('\\n');
}
async function applySetup() {
  if (!confirm('설정을 저장하고 적용할까요?\\n(잘못된 토큰/ID면 연결이 실패할 수 있습니다.)')) return;
  const body = {
    telegramBotToken: document.getElementById('tgToken').value.trim(),
    telegramChatId: document.getElementById('tgChatId').value.trim(),
    backupPassphrase: document.getElementById('backupPass').value,
    backupIntervalSec: Number(document.getElementById('backupInterval').value || '3600'),
    adminPassword: document.getElementById('adminPassword').value
  };
  const r = await fetch('/api/setup/basic', {
    method: 'POST',
    headers: {'content-type':'application/json'},
    body: JSON.stringify(body)
  });
  document.getElementById('out').textContent = await r.text();
  alert('설정 저장 완료.\\n이제 [현재 상태 점검]으로 연결 상태를 확인하세요.');
}
async function probeSetup() {
  const r = await fetch('/api/setup/probe');
  const j = await r.json();
  document.getElementById('out').textContent = humanizeProbe(j);
}
</script>`,
  );
}

function pageLogin(passwordConfigured) {
  const modeLabel = passwordConfigured ? "로그인" : "초기 비밀번호 설정";
  const buttonLabel = passwordConfigured ? "로그인" : "비밀번호 설정";
  return renderPage(
    "Login",
    `<section><h2>관리자 인증</h2>
<p class="small">보안을 위해 관리자 페이지(포트 2845)는 비밀번호 인증 후에만 접근할 수 있습니다.</p>
<label for="pw">${modeLabel} 비밀번호</label>
<input id="pw" type="password" autocomplete="current-password" />
<div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap;">
  <button onclick="login()">${buttonLabel}</button>
</div>
<pre id="out">대기 중</pre>
</section>
<script>
async function login() {
  const password = document.getElementById('pw').value;
  const status = await fetch('/api/auth/status').then(r => r.json());
  const endpoint = status?.passwordConfigured ? '/api/auth/login' : '/api/auth/bootstrap';
  const r = await fetch(endpoint, {
    method: 'POST',
    headers: {'content-type':'application/json'},
    body: JSON.stringify({password})
  });
  const t = await r.text();
  document.getElementById('out').textContent = t;
  if (r.ok) window.location.href = '/';
}
</script>`,
  );
}

function pageUnlock() {
  return renderPage(
    "Unlock",
    `<section><h2>Unlock</h2>
<p>Passphrase is used only for local unseal.</p>
<input id="passphrase" type="password" placeholder="passphrase" />
<div style="margin-top:10px;display:flex;gap:8px;">
  <button onclick="unlock()">unlock</button>
  <button onclick="lock()">lock</button>
</div>
<pre id="out"></pre>
</section>
<script>
async function unlock() {
  const passphrase = document.getElementById('passphrase').value;
  const r = await fetch('/api/unlock', {method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify({passphrase})});
  document.getElementById('out').textContent = await r.text();
}
async function lock() {
  const r = await fetch('/api/lock', {method:'POST'});
  document.getElementById('out').textContent = await r.text();
}
</script>`,
  );
}

function pageSecrets() {
  return renderPage(
    "Secrets",
    `<section><h2>Secrets</h2>
<p class="small">secrets.enc path: ${path.join(stateDir, "secrets.enc")}</p>
<p class="small">Use CLI helper inside admin container:</p>
<pre>node /scripts/openclawctl.mjs init --passphrase "..." --gateway-token "..."
node /scripts/openclawctl.mjs seal --passphrase "..." --auth-profiles-file /runtime/auth-profiles.json</pre>
</section>`,
  );
}

function pageConfig() {
  return renderPage(
    "Config",
    `<section><h2>Config</h2>
<p class="small">Edits ${configPath()}.</p>
<textarea id="cfg" rows="18"></textarea>
<div style="margin-top:10px;"><button onclick="save()">save</button></div>
<pre id="out"></pre>
</section>
<script>
async function load() {
  const r = await fetch('/api/config');
  const txt = await r.text();
  document.getElementById('cfg').value = txt;
}
async function save() {
  const body = document.getElementById('cfg').value;
  const r = await fetch('/api/config', {method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify({body})});
  document.getElementById('out').textContent = await r.text();
}
load();
</script>`,
  );
}

function pageSkills() {
  return renderPage(
    "Skills",
    `<section><h2>Skills</h2>
<button onclick="load()">refresh</button>
<pre id="out">loading...</pre>
</section>
<script>
async function setStatus(name, status) {
  const r = await fetch('/api/skills/status', {method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify({name, status})});
  console.log(await r.text());
  await load();
}
async function load() {
  const r = await fetch('/api/skills');
  const j = await r.json();
  document.getElementById('out').textContent = JSON.stringify(j, null, 2);
}
load();
</script>`,
  );
}

function pageSecurity() {
  return renderPage(
    "Security",
    `<section><h2>Security</h2>
<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
<label><input type="checkbox" id="deep" /> deep</label>
<label><input type="checkbox" id="fix" /> fix</label>
<button onclick="runAudit()">openclaw audit</button>
<button onclick="runDeps()">deps audit</button>
<button onclick="runImage()">image scan</button>
</div>
<pre id="out"></pre>
</section>
<script>
async function runAudit() {
  const deep = document.getElementById('deep').checked ? '1' : '0';
  const fix = document.getElementById('fix').checked ? '1' : '0';
  const r = await fetch('/api/security/audit?deep=' + deep + '&fix=' + fix);
  document.getElementById('out').textContent = await r.text();
}
async function runDeps() {
  const r = await fetch('/api/security/deps-audit');
  document.getElementById('out').textContent = await r.text();
}
async function runImage() {
  const r = await fetch('/api/security/image-scan');
  document.getElementById('out').textContent = await r.text();
}
</script>`,
  );
}

function pageLogs() {
  return renderPage(
    "Logs",
    `<section><h2>Gateway Logs</h2><button onclick="load()">refresh</button><pre id="out">loading...</pre></section>
<script>
async function load() {
  const r = await fetch('/api/logs');
  document.getElementById('out').textContent = await r.text();
}
load();
</script>`,
  );
}

function pageAuthCodex() {
  return renderPage(
    "Auth Codex",
    `<section><h2>Codex OAuth</h2>
<pre>openclaw models auth login --provider openai-codex</pre>
<p>Headless/Docker note: if callback capture fails, copy full redirected URL and paste into wizard.</p>
<p class="small">After login, reseal auth profiles:</p>
<pre>node /scripts/openclawctl.mjs seal --passphrase "..." --auth-profiles-file /runtime/auth-profiles.json</pre>
</section>`,
  );
}

async function handleApi(req, res, url) {
  if (req.method === "GET" && url.pathname === "/api/status") {
    const ctl = await runCtl(["status"]);
    const gatewayReachable = await probeGateway();
    const skills = getSkillsView();
    const riskyCount = skills.reduce((sum, item) => sum + item.riskyFindings.length, 0);
    let parsedStatus = null;
    try {
      parsedStatus = ctl.stdout ? JSON.parse(ctl.stdout) : null;
    } catch {
      parsedStatus = null;
    }
    return json(res, 200, {
      controlPlaneStateDir: stateDir,
      runtimeDir,
      openclawHome,
      gatewayReachable,
      backupStatus: readBackupStatus(),
      skills: {
        total: skills.length,
        riskyFindings: riskyCount,
      },
      status: parsedStatus,
      stderr: ctl.stderr,
    });
  }

  if (req.method === "POST" && url.pathname === "/api/unlock") {
    const raw = await readBody(req);
    const body = raw ? JSON.parse(raw) : {};
    if (!body.passphrase) return json(res, 400, { error: "missing passphrase" });
    const out = await runCtl(["unseal"], body.passphrase);
    return json(res, out.code === 0 ? 200 : 500, out);
  }

  if (req.method === "POST" && url.pathname === "/api/lock") {
    const out = await runCtl(["lock"]);
    return json(res, out.code === 0 ? 200 : 500, out);
  }

  if (req.method === "GET" && url.pathname === "/api/config") {
    const file = configPath();
    const body = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "{}\n";
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    return res.end(body);
  }

  if (req.method === "POST" && url.pathname === "/api/config") {
    const raw = await readBody(req);
    const body = raw ? JSON.parse(raw) : {};
    const file = configPath();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, typeof body.body === "string" ? body.body : "{}\n", "utf8");
    return json(res, 200, { ok: true, file });
  }

  if (req.method === "GET" && url.pathname === "/api/logs") {
    const lines = Number(url.searchParams.get("lines") || "200");
    if (!fs.existsSync(gatewayLog)) {
      return text(res, 200, "gateway log file not found\n");
    }
    const content = fs.readFileSync(gatewayLog, "utf8").split("\n");
    return text(res, 200, `${content.slice(-Math.max(1, Math.min(lines, 1000))).join("\n")}\n`);
  }

  if (req.method === "POST" && url.pathname === "/api/setup/basic") {
    const raw = await readBody(req);
    const body = raw ? JSON.parse(raw) : {};
    const telegramBotToken = String(body.telegramBotToken || "").trim();
    const telegramChatId = String(body.telegramChatId || "").trim();
    const backupPassphrase = String(body.backupPassphrase || "");
    const backupIntervalSec = Number(body.backupIntervalSec || 3600);
    const adminPassword = String(body.adminPassword || "");
    if (!telegramBotToken || !telegramChatId || !backupPassphrase) {
      return json(res, 400, { error: "telegramBotToken, telegramChatId, backupPassphrase are required" });
    }
    if (!hasAdminPasswordConfigured() && !adminPassword) {
      return json(res, 400, { error: "adminPassword is required for first setup" });
    }
    if (!Number.isFinite(backupIntervalSec) || backupIntervalSec < 60) {
      return json(res, 400, { error: "backupIntervalSec must be >= 60" });
    }

    const envMap = readRuntimeEnv();
    envMap.delete("OPENCLAW_BACKUP_PASSPHRASE");
    envMap.set("OPENCLAW_TELEGRAM_BOT_TOKEN", telegramBotToken);
    envMap.set("OPENCLAW_BACKUP_INTERVAL_SEC", String(Math.floor(backupIntervalSec)));
    writeRuntimeEnv(envMap);
    if (adminPassword) setAdminPassword(adminPassword);

    let cfg = {};
    const cfgFile = configPath();
    if (fs.existsSync(cfgFile)) {
      try {
        cfg = JSON.parse(fs.readFileSync(cfgFile, "utf8"));
      } catch {
        cfg = {};
      }
    }
    if (!cfg.channels) cfg.channels = {};
    cfg.channels.telegram = {
      ...(cfg.channels.telegram || {}),
      enabled: true,
      botToken: "${OPENCLAW_TELEGRAM_BOT_TOKEN}",
      dmPolicy: "allowlist",
      allowFrom: [telegramChatId],
      groupPolicy: "disabled",
    };
    fs.mkdirSync(path.dirname(cfgFile), { recursive: true });
    fs.writeFileSync(cfgFile, `${JSON.stringify(cfg, null, 2)}\n`, "utf8");

    const workspaceDir = path.join(openclawHome, "workspace");
    fs.mkdirSync(workspaceDir, { recursive: true });
    fs.writeFileSync(
      path.join(workspaceDir, "SOUL.md"),
      [
        "너의 이름은 크로(Cro)다.",
        "항상 친절하고 명확한 한국어로 답한다.",
        "모호하면 짧은 확인 질문 1개를 먼저 한다.",
        "실행 가능한 단계로 정리해 안내한다.",
      ].join("\n") + "\n",
      "utf8",
    );

    const pluginEnable = await shell("openclaw", ["plugins", "enable", "telegram"]);

    return json(res, 200, {
      ok: true,
      runtimeEnvPath,
      configPath: configPath(),
      pluginEnable: {
        code: pluginEnable.code,
        stdout: pluginEnable.stdout.trim(),
        stderr: pluginEnable.stderr.trim(),
      },
      restartRequired: true,
      restartHint:
        "Run start-openclaw-control-plane.bat --skip-auth (or recreate gateway/cli/backup services) to apply settings.",
    });
  }

  if (req.method === "GET" && url.pathname === "/api/setup/probe") {
    const envMap = readRuntimeEnv();
    const cfgFile = configPath();
    let cfg = {};
    if (fs.existsSync(cfgFile)) {
      try {
        cfg = JSON.parse(fs.readFileSync(cfgFile, "utf8"));
      } catch {
        cfg = {};
      }
    }
    const token = resolveConfigSecret(cfg?.channels?.telegram?.botToken, envMap) || normalizeLineEndings(envMap.get("OPENCLAW_TELEGRAM_BOT_TOKEN") || "");
    const allowFrom = cfg?.channels?.telegram?.allowFrom || [];
    const setupDetected = Boolean(token && Array.isArray(allowFrom) && allowFrom.length > 0);
    const soulFiles = fs.existsSync(path.join(stateDir, "backups"))
      ? fs.readdirSync(path.join(stateDir, "backups")).filter((name) =>
          /^openclaw-state_.*\.openclawdata$/i.test(name),
        )
      : [];
    let telegramProbe = { ok: false, error: "token missing", hint: "Telegram Bot Token을 입력하세요." };
    if (token) {
      try {
        const r = await fetch(`https://api.telegram.org/bot${token}/getMe`);
        const j = await r.json();
        if (j?.ok) {
          telegramProbe = { ok: true, result: j?.result || null, hint: "정상 연결되었습니다." };
        } else {
          const desc = String(j?.description || "telegram api error");
          const isUnauthorized = desc.toLowerCase().includes("unauthorized");
          telegramProbe = {
            ok: false,
            error: desc,
            hint: isUnauthorized
              ? "토큰이 무효/폐기되었습니다. BotFather에서 새 토큰 발급 후 다시 저장하세요."
              : "토큰이 올바른지 확인하고 다시 저장하세요.",
          };
        }
      } catch (error) {
        const raw = error instanceof Error ? error.message : String(error);
        telegramProbe = {
          ok: false,
          error: raw,
          hint:
            raw.toLowerCase().includes("fetch failed")
              ? "네트워크 또는 DNS 문제일 수 있습니다. api.telegram.org 접속 가능 여부를 확인하세요."
              : "토큰/네트워크 상태를 점검 후 다시 시도하세요.",
        };
      }
    }
    const gateway = await probeGateway();
    const backupStatus = readBackupStatus();
    return json(res, 200, {
      ok: gateway && telegramProbe.ok,
      checks: {
        setupDetected,
        soulBackupDetected: soulFiles.length > 0,
        latestSoulBackup: soulFiles.sort().slice(-1)[0] || null,
        gatewayReachable: gateway,
        telegramProbe,
        backupPassphraseConfigured: false,
        backupStatus,
        telegramAllowFrom: allowFrom,
        adminPasswordConfigured: hasAdminPasswordConfigured(),
      },
    });
  }

  if (req.method === "GET" && url.pathname === "/api/auth/status") {
    return json(res, 200, { passwordConfigured: hasAdminPasswordConfigured() });
  }

  if (req.method === "POST" && url.pathname === "/api/auth/bootstrap") {
    if (!isLikelyLocalRequest(req)) {
      return json(res, 403, { error: "bootstrap is allowed only from local client" });
    }
    const raw = await readBody(req);
    const body = raw ? JSON.parse(raw) : {};
    const password = String(body.password || "");
    if (hasAdminPasswordConfigured()) {
      return json(res, 409, { error: "password already configured" });
    }
    if (!password) return json(res, 400, { error: "password is required" });
    setAdminPassword(password);
    const token = createAdminSession();
    setAdminSessionCookie(req, res, token);
    return json(res, 200, { ok: true });
  }

  if (req.method === "POST" && url.pathname === "/api/auth/login") {
    const loginIp = getClientIp(req);
    const remaining = getRemainingBlockMs(loginIp);
    if (remaining > 0) {
      return json(res, 429, {
        error: "too many login attempts",
        retryAfterSec: Math.ceil(remaining / 1000),
      });
    }
    const raw = await readBody(req);
    const body = raw ? JSON.parse(raw) : {};
    const password = String(body.password || "");
    if (!hasAdminPasswordConfigured()) {
      return json(res, 409, { error: "password is not configured yet" });
    }
    if (!verifyAdminPassword(password)) {
      registerFailedLogin(loginIp);
      return json(res, 401, { error: "invalid password" });
    }
    clearLoginAttempts(loginIp);
    const token = createAdminSession();
    setAdminSessionCookie(req, res, token);
    return json(res, 200, { ok: true });
  }

  if (req.method === "POST" && url.pathname === "/api/auth/logout") {
    const cookies = parseCookies(req);
    const token = cookies.get(adminSessionCookie);
    if (token) adminSessions.delete(token);
    clearAdminSessionCookie(req, res);
    return json(res, 200, { ok: true });
  }

  if (req.method === "GET" && url.pathname === "/api/security/audit") {
    const args = ["security", "audit", "--json"];
    if (url.searchParams.get("deep") === "1") args.push("--deep");
    if (url.searchParams.get("fix") === "1") args.push("--fix");
    const out = await shell("openclaw", args);
    const wrapped = toolResponse("openclaw", out);
    return json(res, wrapped.status, wrapped.body);
  }

  if (req.method === "GET" && url.pathname === "/api/security/deps-audit") {
    const out = await shell("pnpm", ["audit", "--json"], {}, projectRoot);
    const wrapped = toolResponse("pnpm", out);
    return json(res, wrapped.status, wrapped.body);
  }

  if (req.method === "GET" && url.pathname === "/api/security/image-scan") {
    const image = process.env.OPENCLAW_IMAGE || "openclaw:local";
    const out = await shell("trivy", ["image", "--format", "json", image]);
    const wrapped = toolResponse("trivy", out);
    return json(res, wrapped.status, wrapped.body);
  }

  if (req.method === "GET" && url.pathname === "/api/skills") {
    return json(res, 200, { roots: skillsRoots, items: getSkillsView() });
  }

  if (req.method === "POST" && url.pathname === "/api/skills/status") {
    const raw = await readBody(req);
    const body = raw ? JSON.parse(raw) : {};
    if (!body.name || !body.status) {
      return json(res, 400, { error: "name and status are required" });
    }
    if (body.status !== "quarantine" && body.status !== "enabled") {
      return json(res, 400, { error: "status must be quarantine|enabled" });
    }
    const next = updateSkillStatus(body.name, body.status);
    return json(res, 200, { ok: true, item: next });
  }

  return notFound(res);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", "http://127.0.0.1:3000");
    const passwordConfigured = hasAdminPasswordConfigured();
    const cookies = parseCookies(req);
    const sessionToken = cookies.get(adminSessionCookie);
    const authenticated = isAdminSessionValid(sessionToken);

    if (!isAuthExemptPath(url.pathname)) {
      if (!authenticated) {
        if (url.pathname.startsWith("/api/")) {
          return json(res, 401, {
            ok: false,
            error: "authentication required",
            loginPath: "/login",
            passwordConfigured,
          });
        }
        res.writeHead(302, { Location: "/login" });
        return res.end();
      }
    }

    if (url.pathname.startsWith("/api/")) {
      return await handleApi(req, res, url);
    }

    if (url.pathname === "/login") return html(res, pageLogin(passwordConfigured));
    if (url.pathname === "/") return html(res, pageStatus());
    if (url.pathname === "/setup") return html(res, pageSetup());
    if (url.pathname === "/unlock") return html(res, pageUnlock());
    if (url.pathname === "/secrets") return html(res, pageSecrets());
    if (url.pathname === "/config") return html(res, pageConfig());
    if (url.pathname === "/skills") return html(res, pageSkills());
    if (url.pathname === "/security") return html(res, pageSecurity());
    if (url.pathname === "/logs") return html(res, pageLogs());
    if (url.pathname === "/auth/codex") return html(res, pageAuthCodex());

    return notFound(res);
  } catch (error) {
    return json(res, 500, { error: error instanceof Error ? error.message : String(error) });
  }
});

server.listen(3000, "0.0.0.0", () => {
  console.log("openclaw-admin listening on :3000");
});

