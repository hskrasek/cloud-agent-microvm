# cloud-agent-microvm

Run [Claude Code](https://claude.com/claude-code) as a cloud agent inside an
[AWS Lambda MicroVM](https://docs.aws.amazon.com/lambda/). You hand it a repo and a
task; it works in an isolated Firecracker VM and opens a pull request.

This is a prototype on a personal AWS account and GitHub. The long-term target is
Bitbucket Cloud and Jira. Design decisions and lessons from real runs are in
[CONTEXT.md](CONTEXT.md).

## How it works

1. `run.sh` launches a MicroVM from the `cloud-agent` image. The repo URL, task and
   requester go in as the run hook payload.
2. `worker.mjs` (the image entrypoint, port 8080) handles the platform hooks. On `/run`
   it fetches a GitHub token from Secrets Manager, clones the repo, then starts
   `claude -p` in the background as a non-root `agent` user.
3. The worker streams Claude's `stream-json` output over a WebSocket (`/stream`) and
   serves it as ndjson at `/log`. `index.html` is the live viewer.
4. When Claude exits, the worker pushes `agent/<id>` and opens a PR. Claude never holds
   git credentials.
5. Commits are authored by the requesting human, committed by the `cloud-agent` bot,
   and carry Claude's `Co-Authored-By` trailer.

Bedrock auth uses the VM's execution role. A shell into the running VM is available
through `SHELL_INGRESS`.

## Layout

| Path | Purpose |
| --- | --- |
| `worker.mjs`, `package.json` | Hook server, app server and git/PR logic |
| `Dockerfile`, `settings.json` | Image build and Claude Code settings (sandbox, allowed domains) |
| `index.html` | Live viewer, opened from disk |
| `deploy.sh` | Zip the artifact, upload to S3, create or version the image |
| `run.sh` / `stop.sh` | Launch / terminate a MicroVM |
| `demo.sh` | Paced walkthrough: run, watch, shell in, suspend/resume, PR, stop |
| `.infra/` | OpenTofu: artifact bucket, build and exec roles, GitHub token secret |

## Prerequisites

- AWS CLI with the `lambda-microvms` commands, credentials for `us-east-2`
- [OpenTofu](https://opentofu.org/), `python3`, `zip`
- `websocat` (for shell access and `demo.sh`)
- A fine-grained GitHub PAT with Contents and Pull requests write on the target repo
- Bedrock access for the Claude models. The first use of each model family needs a
  principal with `aws-marketplace:ViewSubscriptions` and `Subscribe`.

## Setup

```sh
# 1. Infrastructure. backend.hcl (gitignored) names your state bucket.
cd .infra
tofu init -backend-config=backend.hcl
tofu apply
cd ..

# 2. Store the GitHub PAT as a plain string in the secret
aws secretsmanager put-secret-value --region us-east-2 \
  --secret-id cloud-agent/github-token --secret-string "<PAT>"

# 3. Build the image
./deploy.sh
```

## Usage

```sh
./run.sh https://github.com/OWNER/REPO "Add a CODE_OF_CONDUCT.md and commit it" [branch]
```

`run.sh` prints the MicroVM id, endpoint, a viewer URL, a `curl` command for the log,
and the commands to open a shell. Open the `viewer:` URL in a browser to watch the run.
Stop the VM with:

```sh
./stop.sh <microvm-id>
```

Run the guided demo with `./demo.sh [repo-url] ["task"]`, or attach to a VM you already
started with `./demo.sh --prestarted <microvm-id>`.

## Security model

- Git credentials are never in the image or on the agent's disk. The root worker writes
  them only for the clone and the push.
- Claude Code runs as a non-root user with its built-in sandbox and a network
  allowlist. Network-level egress control (VPC connector, Network Firewall, DNS
  Firewall) is the planned work setup. See D5 and D9 in `CONTEXT.md`.
- Auth tokens for the endpoint and shell are short-lived (60 and 15 minutes).

## License

MIT. See [LICENSE](LICENSE). The vendored AWS skill in `.agents/skills` is covered by
[NOTICE](NOTICE).
