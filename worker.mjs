// In-MicroVM worker: Lambda MicroVM lifecycle hooks + Claude Code runner + viewer.
// Skeleton follows aws-samples/sample-lambda-microvm-claude-managed-agents.
//
// Hooks (POST, called by the platform) on HOOK_PREFIX:
//   /ready /validate            image build (snapshot gate, smoke test)
//   /run /resume /suspend /terminate   runtime
// App routes (reached through the per-VM HTTPS proxy with an auth token):
//   GET /          viewer (index.html)
//   GET /log       stream.jsonl so far
//   WS  /stream    live stream-json lines (backlog first, then live)
//
// /run receives { microvmId, runHookPayload: "<JSON>" } where the inner JSON is
// { repo, branch, task, source, requestedBy }. It acks 200, then in the
// background fetches the GitHub token, clones the repo as the `agent` user, and
// runs `claude -p` with stream-json output.

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { WebSocketServer } from "ws";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const PORT = Number(process.env.PORT || 8080);
const HOOK_PREFIX = "/aws/lambda-microvms/runtime/v1";
const REGION = process.env.AWS_REGION || "us-east-2";
const OUT = process.env.SESSION_OUTPUTS || "/mnt/session/outputs";
const LOG = path.join(OUT, "stream.jsonl");
const REPO_DIR = "/workspace/repo";
const AGENT = { uid: 1000, gid: 1000, home: "/home/agent" }; // ponytail: uid fixed by useradd in Dockerfile
const BOT = { name: "cloud-agent", email: "cloud-agent@users.noreply.github.com" };

const here = path.dirname(new URL(import.meta.url).pathname);
const INDEX = path.join(here, "index.html");

let started = false;
const clients = new Set();

fs.mkdirSync(OUT, { recursive: true });

// ---- helpers ---------------------------------------------------------------

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

function json(res, code, body) {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function emit(obj) {
  const line = JSON.stringify(obj);
  fs.appendFileSync(LOG, line + "\n");
  for (const ws of clients) if (ws.readyState === 1) ws.send(line);
}

function agentEnv(extra = {}) {
  return {
    PATH: process.env.PATH,
    HOME: AGENT.home,
    USER: "agent",
    AWS_REGION: REGION,
    CLAUDE_CODE_USE_BEDROCK: "1",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
    GIT_TERMINAL_PROMPT: "0",
    ...extra,
  };
}

// Run a command; resolve with { code, stdout }. `asRoot` keeps the worker's uid.
function run(cmd, args, { cwd, env, onLine, asRoot = false } = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, {
      cwd,
      env: asRoot ? { ...process.env, ...env } : agentEnv(env),
      ...(asRoot ? {} : { uid: AGENT.uid, gid: AGENT.gid }),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    if (onLine) createInterface({ input: p.stdout }).on("line", onLine);
    else p.stdout.on("data", (d) => (stdout += d));
    p.stderr.on("data", (d) => process.stderr.write(`[${cmd}] ${d}`));
    p.on("error", reject);
    p.on("close", (code) => resolve({ code, stdout }));
  });
}

async function githubToken() {
  const sm = new SecretsManagerClient({ region: REGION });
  const r = await sm.send(new GetSecretValueCommand({ SecretId: process.env.GH_TOKEN_SECRET }));
  if (!r.SecretString) throw new Error("GitHub token secret is empty");
  return r.SecretString.trim();
}

// Git config for the root-run clone/push, passed via env so nothing lands in
// argv, in any .git/config, or on disk. Repo-local hooks and helpers are
// neutralised because the agent controls that repo's contents.
function gitEnv(token) {
  const cfg = [
    ["safe.directory", REPO_DIR],
    ["safe.directory", `${REPO_DIR}/.git`],
    ["core.hooksPath", "/dev/null"],
    ["credential.helper", ""],
    ["http.proxy", ""],
    // URL-scoped: the header is only ever sent to github.com.
    ["http.https://github.com/.extraHeader", `Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`],
  ];
  const env = { GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_COUNT: String(cfg.length) };
  cfg.forEach(([k, v], i) => { env[`GIT_CONFIG_KEY_${i}`] = k; env[`GIT_CONFIG_VALUE_${i}`] = v; });
  return env;
}

// ---- the job ---------------------------------------------------------------

const REPO_URL = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+(\.git)?$/;
const REF_NAME = /^[\w./-]+$/;

async function runJob(job) {
  const { repo, task, source = "unknown", requestedBy = "" } = job;
  if (!REPO_URL.test(repo)) throw new Error("repo must be an https://github.com/<owner>/<name> URL");
  const token = await githubToken();

  // GitHub REST, scoped to this repo. Node 24 has fetch built in.
  const [owner, name] = new URL(repo).pathname.replace(/\.git$/, "").split("/").filter(Boolean);
  const gh = async (path, init = {}) => {
    const r = await fetch(`https://api.github.com/repos/${owner}/${name}${path}`, {
      ...init,
      headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json", "user-agent": "cloud-agent", ...init.headers },
    });
    if (!r.ok) throw new Error(`GitHub ${init.method || "GET"} ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
    return r.json();
  };

  const branch = job.branch || (await gh("")).default_branch;
  if (!REF_NAME.test(branch) || branch.startsWith("-")) throw new Error("invalid branch name");
  emit({ type: "worker", event: "start", repo, branch, source, requestedBy });

  // The token lives only in this root process and the env of the git
  // commands it runs. The agent uid never sees it.
  const gitRoot = (args, env = {}) => run("git", args, { asRoot: true, env: { ...gitEnv(token), ...env } });
  const git = (...a) => run("git", a, { cwd: REPO_DIR });

  emit({ type: "worker", event: "clone" });
  const clone = await gitRoot(["clone", "--depth", "50", "--branch", branch, "--", repo, REPO_DIR]);
  if (clone.code !== 0) throw new Error(`git clone exited ${clone.code}`);
  await run("chown", ["-R", `${AGENT.uid}:${AGENT.gid}`, "--", REPO_DIR], { asRoot: true });
  for (const [k, v] of [["user.name", BOT.name], ["user.email", BOT.email]]) {
    const r = await git("config", k, v);
    if (r.code !== 0) throw new Error(`git config ${k} failed`);
  }

  const workBranch = `agent/${Date.now().toString(36)}`;
  await git("checkout", "-b", workBranch);

  const prompt = [
    task,
    "",
    "---",
    `You are working in a clone of ${repo} on branch ${workBranch} (based on ${branch}).`,
    "When done, commit your changes with a concise imperative message.",
    "Do not push and do not change remotes; the branch is pushed for you after you finish.",
  ].join("\n");

  // Trailers come from Claude Code's attribution setting, not the prompt, so
  // the model cannot forget or reword them. Replaces the default Co-Authored-By.
  const trailers = [requestedBy && `Requested-by: ${requestedBy}`, source && `Source: ${source}`]
    .filter(Boolean).join("\n");
  const settings = JSON.stringify({ attribution: { commit: trailers, pr: "", sessionUrl: false } });

  emit({ type: "worker", event: "claude_start", branch: workBranch });
  let summary = "";
  const r = await run(
    "claude",
    ["-p", prompt, "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions", "--settings", settings],
    {
      cwd: REPO_DIR,
      onLine: (line) => {
        try {
          const msg = JSON.parse(line);
          if (msg.type === "result" && typeof msg.result === "string") summary = msg.result;
          emit(msg);
        } catch { emit({ type: "raw", line }); }
      },
    },
  );
  emit({ type: "worker", event: "claude_done", exitCode: r.code });

  // Push from a fresh root-owned bare clone so nothing the agent left in
  // /workspace/repo (config, hooks, background processes) touches the push.
  const bare = fs.mkdtempSync("/root/push-");
  await gitRoot(["clone", "--bare", "--quiet", "--", REPO_DIR, bare]);
  const ahead = await gitRoot(["-C", bare, "rev-list", "--count", `${branch}..${workBranch}`]);
  const commits = Number(ahead.stdout.trim()) || 0;
  let pushed = false;
  let pr = null;
  if (commits > 0) {
    const push = await gitRoot(["-C", bare, "push", "--", repo, `${workBranch}:refs/heads/${workBranch}`]);
    pushed = push.code === 0;
    if (!pushed) emit({ type: "worker", event: "error", message: `git push exited ${push.code}` });
  }
  if (pushed) {
    const title = (await gitRoot(["-C", bare, "log", "-1", "--format=%s", workBranch])).stdout.trim() || `Agent: ${task.slice(0, 60)}`;
    const body = [
      "## Task", "", task, "",
      "## Agent summary", "", summary || "_none_", "",
      "---",
      requestedBy && `Requested-by: ${requestedBy}`,
      `Source: ${source}`,
    ].filter((x) => x !== undefined && x !== false).join("\n");
    try {
      const created = await gh("/pulls", { method: "POST", body: JSON.stringify({ title, head: workBranch, base: branch, body }) });
      pr = created.html_url;
      emit({ type: "worker", event: "pr", url: pr });
    } catch (err) {
      emit({ type: "worker", event: "error", message: String(err.message || err) });
    }
  }
  fs.rmSync(bare, { recursive: true, force: true });
  emit({ type: "worker", event: "done", exitCode: r.code, branch: workBranch, commits, pushed, pr });
  // ponytail: no self-terminate; idlePolicy or stop.sh reclaims the VM. Add
  // TerminateMicrovm here (needs lambda:TerminateMicrovm on the exec role) when
  // the 30-minute idle tail starts costing real money.
}

function ackThenRun(res, job) {
  json(res, 200, { status: "accepted" });
  if (started) return;
  started = true;
  runJob(job).catch((err) => {
    console.error("worker: job failed", err);
    emit({ type: "worker", event: "error", message: String(err?.message || err) });
  });
}

// ---- server ----------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const url = req.url.split("?")[0];

  if (req.method === "POST" && url.startsWith(HOOK_PREFIX + "/")) {
    const hook = url.slice(HOOK_PREFIX.length + 1);
    switch (hook) {
      case "ready":
      case "resume":
      case "suspend":
      case "terminate":
        return json(res, 200, { status: "ok" });
      case "validate": {
        // Smoke test + lets the platform sample pages claude touches at startup.
        const r = await run("claude", ["--version"]);
        return json(res, r.code === 0 ? 200 : 503, { claude: r.stdout.trim(), code: r.code });
      }
      case "run": {
        try {
          const raw = await readBody(req);
          const envelope = raw ? JSON.parse(raw) : {};
          const inner = typeof envelope.runHookPayload === "string"
            ? JSON.parse(envelope.runHookPayload)
            : envelope.runHookPayload || envelope;
          if (!inner.repo || !inner.task) return json(res, 400, { error: "payload needs repo and task" });
          return ackThenRun(res, inner);
        } catch (err) {
          console.error("worker: /run error", err);
          return json(res, 400, { error: "invalid run payload" });
        }
      }
      default:
        res.writeHead(404); return res.end();
    }
  }

  if (req.method === "GET" && url === "/") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return fs.createReadStream(INDEX).pipe(res);
  }
  if (req.method === "GET" && url === "/log") {
    res.writeHead(200, { "content-type": "application/x-ndjson" });
    return fs.existsSync(LOG) ? fs.createReadStream(LOG).pipe(res) : res.end();
  }
  res.writeHead(404); res.end();
});

const wss = new WebSocketServer({ server, path: "/stream" });
wss.on("connection", (ws) => {
  clients.add(ws);
  if (fs.existsSync(LOG)) {
    for (const line of fs.readFileSync(LOG, "utf8").split("\n")) if (line) ws.send(line);
  }
  ws.on("close", () => clients.delete(ws));
});

server.listen(PORT, "0.0.0.0", () => console.log(`worker: listening on :${PORT}`));
