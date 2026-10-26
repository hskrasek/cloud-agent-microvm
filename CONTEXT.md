# cloud-agent-microvm — context and decisions

Cloud agents (Claude Code) running on AWS Lambda MicroVMs. A task is offloaded
from a laptop harness or a Jira webhook, the agent works on a repo, and the
result is a branch or PR. Prototype here on personal stack, target is work
(Bitbucket Cloud, Jira, PHP/Laravel with private Packagist).

## Platform facts that shape the design

- MicroVMs boot from a memory+disk snapshot taken at image build. Anything in
  the Dockerfile is shared by every VM from that image version.
- Lifetime up to 8 hours, suspend/resume preserves state. No 15-minute limit.
- The container must run an HTTP server for build hooks (`/ready`, `/validate`)
  and runtime hooks (`/run`, `/resume`, `/suspend`, `/terminate`). `/run` has a
  60s ceiling, so long work is kicked off in the background.
- Per-VM HTTPS endpoint, token auth (60 min max TTL), any port reachable via
  `X-aws-proxy-port` header or `lambda-microvms.port.<n>` WebSocket subprotocol.
- `SHELL_INGRESS` connector gives a PTY into the running container on :8022.
- Execution role is assumed at runtime via IMDSv2. Bedrock auth rides on it.
- Egress connectors (VPC) are bound at run time and cannot change on resume.

## Decisions

### D1. Base image
`public.ecr.aws/lambda/microvms:al2023-minimal`. Its OpenSSL reseeds entropy on
snapshot resume. Do not swap for a generic AL2023 image.

### D2. No heredocs in the Dockerfile
The service builder is not confirmed to honour `# syntax=` BuildKit directives.
Ship scripts as files in the zip and `COPY` them.

### D3. One process is both hook server and app server
`worker.mjs` on :8080 serves `/ready`, `/validate`, `/run`, plus `/stream`
(WebSocket of Claude Code `stream-json` output), `/log`, and a static viewer
page. No separate frontend deploy.

### D4. Per-task state enters via `runHookPayload`, never the image
Payload shape: `{ repo, branch, task, source, requestedBy }`. `/run` clones the
repo and spawns `claude -p` in the background, returns 200 immediately.

### D5. Git credentials never reach the agent
Rejected: SSH key in the Dockerfile. It would live in image layers, snapshot,
and S3 zip, be shared by every VM, need a rebuild to rotate, and be readable
by a prompt-injected agent with workspace-wide blast radius.
Instead: token in Secrets Manager, fetched via execution role in `/run` by the
root worker process. The worker writes it to the agent's git credential store
only for the clone and the final push, and deletes it in between. Claude Code
runs with no credentials on disk; the prompt tells it to commit and not push.
The worker pushes `agent/<id>` after Claude exits (only if there are new
commits) and opens a PR against the repo's default branch via the GitHub
REST API, body = task + the agent's final summary + trailers. `branch` in
the payload is optional; empty means the default branch (looked up via API).
The PAT therefore needs Contents and Pull requests write. Per-repo future: Bitbucket Repository Access Tokens or GitHub App
installation tokens are a change to the fetch step only.

### D6. Commits: author = requesting human, committer = bot, Claude co-author
Revised 2026-10-26 at Hunter's direction (originally: bot author, human in a
trailer). Git already separates author from committer, so the commit records
all three truthfully: `user.name`/`user.email` in the clone are set from
`requestedBy`, `GIT_COMMITTER_*` is the `cloud-agent` identity, and Claude
Code's default `Co-Authored-By: Claude <model>` trailer stays on. GitHub
renders this as "hskrasek and claude committed". The author email must be a
verified email on the human's GitHub account for the avatar/link to resolve.
Falls back to the bot as author when `requestedBy` is absent (e.g. a webhook
with no assignee). `Requested-by`/`Source` live in the PR body, not commit
trailers. Trade-off accepted: blame points at the human, who is also the PR
reviewer/owner, so the audit trail is "asked for and owns" rather than
"typed".

### D7. One HTTP control plane, thin clients
Control plane = one Lambda event function with function URL + a table keyed by
ticket/task id (idempotency for Jira retries, webhook verification). MCP server
and web page are thin clients over it. Not built until Jira or a second
harness (Cursor) needs it. Solo laptop use is a skill wrapping a script that
calls `run-microvm` directly with the developer's own credentials.
Open: whose AWS identity launches runs? Developer SSO creds (near trust-free
control plane) vs control plane's own role (anyone reaching it can launch).
Jira forces the latter; decide before building it.

### D8. Shell ingress is the human escape hatch, not the control plane
Attach `SHELL_INGRESS` at run. Used to inspect a stuck run or drive `claude`
interactively against the agent's working tree. Replaces a "send follow-up
message" feature for now.

### D9. Egress is enforced in the network, not in the VM
Rejected: in-VM iptables. The agent is the threat; a prompt-injected agent
with root flushes the rules. iptables also cannot filter by domain and the
targets (Bitbucket, Packagist, Bedrock) sit behind rotating CDN IPs.
Layer 1 (prototype, and defense in depth at work): Claude Code's built-in
sandbox with `sandbox.network.allowedDomains`, agent runs as a non-root user,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. Needs bubblewrap in the image.
Verify the settings key names and that the guest kernel allows unprivileged
user namespaces.
Layer 2 (work): `VPC_EGRESS` connector, AWS services over PrivateLink
(Bedrock, Secrets Manager, CloudWatch Logs), AWS Network Firewall stateful
domain allowlist with default drop, Route 53 Resolver DNS Firewall with the
same list, NAT gateway for the allowed public hosts. Nothing in the guest can
reach any of it.
Consequence: `WebFetch` and public package registries fail unless listed.
That is the point. Allow a docs host deliberately if needed.

## Before this goes to work: observe-only phase for the allowlist

Do not build the allowlist by guessing and whack-a-mole. Stand up Layer 2 in
alert-only mode first and let real runs tell you what they need:

- Network Firewall: stateful rule group with `alert` action on all traffic
  (no drop), alert logs to CloudWatch or S3. Alerts carry SNI / HTTP Host.
- DNS Firewall: rule action `ALERT` on `*`, query logs on. Shows every domain
  resolved, including ones that never completed a TLS handshake.
- VPC flow logs on the connector subnet for anything that is not HTTP/DNS.
- Claude Code sandbox: run with the allowlist empty and the sandbox in a
  permissive/logging mode if it has one; otherwise read its denied-domain
  messages from the stream-json transcript.

Run a representative set of real tasks (PHP install, test suite, git push,
PR creation) across a week or two, aggregate distinct domains from the logs,
and that aggregate becomes the first allowlist. Flip rules from `alert` to
`drop` in one change. Keep alert logging on afterwards so new legitimate
needs show up as a log line, not as a broken run.

## Learned from the first real runs (2026-10-25)

- Bedrock: the first invoke of a model auto-creates the AWS Marketplace
  agreement and needs `aws-marketplace:ViewSubscriptions` and `Subscribe` on
  the caller. Without them: 403 "Model access is denied". Exec role has them.
- Sandbox: bubblewrap in the guest fails with "Can't mount proc" unless
  `sandbox.enableWeakerNestedSandbox: true`. With it, the sandbox works.
- Sandbox mounts a fresh `/dev` per Bash command, so anything placed in
  `/dev/shm` by the worker is invisible to git inside Claude Code. Git
  credentials live in `/home/agent/.git-credentials` (mode 600) instead.
- AL2023 default `nodejs` is 18. Image uses `nodejs24` + `nodejs24-npm`
  (24.21 at time of writing), the newest line in the AL2023 repos.
- A trivial task (write one file, commit) took ~10 s of agent time and ~$0.07.
- Commit identity is set by the worker (repo-local `user.*` for author,
  `GIT_COMMITTER_*` env for committer); Claude Code's default attribution
  adds the `Co-Authored-By` trailer. See D6.
- Marketplace: the Sonnet/Haiku agreements were created once by the exec role
  during run 2; the permission was then removed from the role. A new model
  family needs a one-time agreement from a principal that has
  `aws-marketplace:ViewSubscriptions` + `Subscribe`.
- Sandbox read-only noise seen when git ran inside Claude Code's Bash:
  `.git/config` is a sandbox protected path even inside the writable cwd (so
  `git push -u` cannot record upstream); `$HOME` is read-only inside the
  sandbox (so the credential store cannot take its `.lock`); a `stat` of a
  missing `.gitmodules` returns EACCES instead of ENOENT. All cosmetic, and all
  gone now that the worker does the push outside the sandbox.

## Open questions

- Local-to-cloud handoff content: the `handoff` skill output as the task body.

## Prototype contract (personal AWS + GitHub)

Fixed names so infra, scripts, image, and worker.mjs agree. Change here first.

- Region `us-east-2`, account `559450879245`. Managed base image
  `arn:aws:lambda:us-east-2:aws:microvm-image:al2023-1`.
- Image name `cloud-agent`. Artifact bucket
  `cloud-agent-microvm-artifacts-559450879245-us-east-2`, key `cloud-agent.zip`.
- Roles `cloud-agent-microvm-build` and `cloud-agent-microvm-exec`.
- Secret `cloud-agent/github-token`, plain string value (fine-grained PAT).
  Container env `GH_TOKEN_SECRET=cloud-agent/github-token`.
- Hook server: `worker.mjs` (ESM) at `/opt/worker/worker.mjs`, entrypoint of the
  image, on :8080, also the app port. Platform hooks are `POST
  /aws/lambda-microvms/runtime/v1/{ready,validate,run,resume,suspend,terminate}`.
  `/run` body is `{ microvmId, runHookPayload: "<JSON string>" }`. App routes:
  `GET /` (serves `index.html`), `GET /log` (ndjson so far), WebSocket
  `/stream` (backlog then live, one JSON line per message, Claude Code
  `stream-json` plus `{type:"worker",event:...}` lines from the worker).
- `runHookPayload` JSON: `{ repo, branch, task, source, requestedBy }`.
  `repo` is an HTTPS GitHub URL. `requestedBy` is `Name <email>`.
- Container user `agent` (non-root), home `/home/agent`, repo cloned to
  `/workspace/repo`. Claude Code user settings at
  `/home/agent/.claude/settings.json`. Session artifacts and the stream log
  live in `/mnt/session/outputs` (env `SESSION_OUTPUTS`), owned by `agent`;
  `/log` serves `$SESSION_OUTPUTS/stream.jsonl`.
- Worker deps via `package.json` (`ws`, `@aws-sdk/client-secrets-manager`),
  installed into `/opt/worker` at image build. Based on the AWS sample
  aws-samples/sample-lambda-microvm-claude-managed-agents worker.mjs.
- Files in repo root: `Dockerfile`, `worker.mjs`, `package.json`, `index.html`,
  `settings.json`, `deploy.sh`, `run.sh`, `.infra/` (OpenTofu).
- OpenTofu state in existing bucket `tofu-state-559450879245-us-east-2`,
  key `cloud-agent-microvm/terraform.tfstate`. Image creation and runs are
  done by scripts via the CLI, not Tofu (no provider resource for
  lambda-microvms yet).
