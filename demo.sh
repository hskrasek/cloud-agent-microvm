#!/usr/bin/env bash
# Paced demo: run a task, watch it, shell in, suspend/resume, show the PR, stop.
# Usage: ./demo.sh [repo-https-url] ["task text"]
#        ./demo.sh --prestarted <microvm-id>   # attach to a VM run.sh already launched (skips step 1)
set -euo pipefail
cd "$(dirname "$0")"

PRESTARTED=; [[ ${1:-} == --prestarted ]] && { PRESTARTED=${2:?microvm id}; shift 2; }
REPO=${1:-https://github.com/hskrasek/hunterskrasek.com}
TASK=${2:-"Add a CODE_OF_CONDUCT.md based on the Contributor Covenant, under 60 lines, and commit it"}
REGION=us-east-2
command -v websocat >/dev/null || { echo "brew install websocat first" >&2; exit 1; }

step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
pause() { read -rp $'\n[enter] '; }
state() { aws lambda-microvms get-microvm --region "$REGION" --microvm-identifier "$ID" --query state --output text; }
wait_state() { until [[ "$(state)" == "$1" ]]; do printf '  %s\r' "$(state)"; sleep 2; done; echo "  $1"; }
shell() {
  local tok
  tok=$(aws lambda-microvms create-microvm-shell-auth-token --region "$REGION" \
    --microvm-identifier "$ID" --expiration-in-minutes 15 \
    --query 'authToken."X-aws-proxy-auth"' --output text)
  echo "  (type 'exit' to return to the demo)"
  stty raw -echo  # raw PTY passthrough; the remote side echoes
  websocat -b "${ENDPOINT/https:/wss:}/shell" \
    -H "Sec-WebSocket-Protocol: lambda-microvms.authentication.${tok}, lambda-microvms, lambda-microvms.port.8022" || true
  stty sane; echo
}

if [[ -n $PRESTARTED ]]; then
  step "1. (prestarted) attaching to $PRESTARTED"
  ID=$PRESTARTED
  ENDPOINT=$(aws lambda-microvms get-microvm --region "$REGION" --microvm-identifier "$ID" --query endpoint --output text)
  [[ "$ENDPOINT" == https://* ]] || ENDPOINT="https://${ENDPOINT}"
  TOKEN=$(aws lambda-microvms create-microvm-auth-token --region "$REGION" \
    --microvm-identifier "$ID" --expiration-in-minutes 60 \
    --allowed-ports '[{"port":8080}]' --query 'authToken."X-aws-proxy-auth"' --output text)
  VIEWER="file://${PWD}/index.html#host=${ENDPOINT#https://}&token=${TOKEN}"
else
  step "1. Launch: task + repo go in, nothing else leaves the laptop"
  echo "  repo: $REPO"
  echo "  task: $TASK"
  OUT=$(./run.sh "$REPO" "$TASK" | tee /dev/stderr)
  ID=$(sed -n 's/^microvm: *//p' <<<"$OUT")
  ENDPOINT=$(sed -n 's/^endpoint: *//p' <<<"$OUT")
  VIEWER=$(sed -n 's/^viewer: *//p' <<<"$OUT")
  TOKEN=${VIEWER##*token=}
fi
trap 'echo; echo "cleaning up $ID"; ./stop.sh "$ID" >/dev/null' EXIT

step "2. Watch: live stream in the browser"
open "$VIEWER"
echo "  waiting for the worker's done event..."
until grep -q '^{"type":"worker","event":"done"' <<<"$(curl -s "$ENDPOINT/log" -H "X-aws-proxy-auth: $TOKEN")"; do sleep 2; done
curl -s "$ENDPOINT/log" -H "X-aws-proxy-auth: $TOKEN" | grep -E '"event":"(pr|done)"'
pause

step "3. Shell: the human escape hatch (D8), separate 15-min token, root in the same container"
echo "  try: git -C /workspace/repo -c safe.directory=/workspace/repo log --format='%an | %cn | %s' -3"
echo "       ps -u agent -o pid,ppid,comm   # what the agent left running"
echo "       ls /root; tail -2 /mnt/session/outputs/stream.jsonl"
pause; shell

step "4. Suspend: VM frozen, nothing billed for compute, state kept"
pause
aws lambda-microvms suspend-microvm --region "$REGION" --microvm-identifier "$ID" >/dev/null
wait_state SUSPENDED

step "5. Resume: same VM, same filesystem, shell back in to prove it"
pause
aws lambda-microvms resume-microvm --region "$REGION" --microvm-identifier "$ID" >/dev/null
wait_state RUNNING
pause; shell

step "6. Result: the PR on GitHub (author = you, committer = bot, Claude co-author)"
# The log also carries model output, so only trust a worker line with a GitHub PR URL.
PR=$(curl -s "$ENDPOINT/log" -H "X-aws-proxy-auth: $TOKEN" \
  | sed -n 's#^{"type":"worker","event":"pr","url":"\(https://github\.com/[A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*/pull/[0-9]*\)"}$#\1#p' | tail -1)
[[ -n "$PR" ]] && open "$PR" || echo "  no PR event (agent made no commits?)"
pause

step "7. Stop"
