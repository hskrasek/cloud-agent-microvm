#!/usr/bin/env bash
# Usage: ./run.sh <repo-https-url> "<task text>" [branch]
set -euo pipefail
cd "$(dirname "$0")"

REPO=${1:?usage: $0 <repo-https-url> "<task text>" [branch]}
TASK=${2:?usage: $0 <repo-https-url> "<task text>" [branch]}
BRANCH=${3:-}  # empty = repo default branch

REGION=us-east-2
NAME=cloud-agent
IMAGE_ARN="arn:aws:lambda:${REGION}:$(aws sts get-caller-identity --query Account --output text):microvm-image:${NAME}"
SHELL_INGRESS="arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:SHELL_INGRESS"
EXEC_ROLE=$(tofu -chdir=.infra output -raw exec_role_arn)
REQUESTED_BY="$(git config user.name) <$(git config user.email)>"

PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"repo":sys.argv[1],"branch":sys.argv[2],"task":sys.argv[3],"source":"local","requestedBy":sys.argv[4]}))' \
  "$REPO" "$BRANCH" "$TASK" "$REQUESTED_BY")

VERSION=$(aws lambda-microvms get-microvm-image --region "$REGION" \
  --image-identifier "$IMAGE_ARN" --query latestActiveImageVersion --output text)

echo "running ${IMAGE_ARN} v${VERSION}"
RUN=$(aws lambda-microvms run-microvm --region "$REGION" \
  --image-identifier "$IMAGE_ARN" \
  --image-version "$VERSION" \
  --execution-role-arn "$EXEC_ROLE" \
  --run-hook-payload "$PAYLOAD" \
  --ingress-network-connectors "[\"${SHELL_INGRESS}\"]" \
  --idle-policy '{"maxIdleDurationSeconds":1800,"suspendedDurationSeconds":3600,"autoResumeEnabled":true}' \
  --maximum-duration-in-seconds 28800 \
  --logging "{\"cloudWatch\":{\"logGroup\":\"/aws/lambda-microvms/${NAME}\"}}" \
  --output json)
ID=$(echo "$RUN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["microvmId"])')
ENDPOINT=$(echo "$RUN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoint"])')
[[ "$ENDPOINT" == https://* ]] || ENDPOINT="https://${ENDPOINT}"

while :; do
  STATE=$(aws lambda-microvms get-microvm --region "$REGION" --microvm-identifier "$ID" --query state --output text)
  echo "  state: ${STATE}"
  case "$STATE" in
    RUNNING) break ;;
    TERMINATING|TERMINATED)
      aws lambda-microvms get-microvm --region "$REGION" --microvm-identifier "$ID" --query stateReason --output text >&2
      exit 1 ;;
  esac
  sleep 3
done

TOKEN=$(aws lambda-microvms create-microvm-auth-token --region "$REGION" \
  --microvm-identifier "$ID" --expiration-in-minutes 60 \
  --allowed-ports '[{"port":8080}]' \
  --query 'authToken."X-aws-proxy-auth"' --output text)

cat <<EOF

microvm:  ${ID}
viewer:   ${ENDPOINT}/#token=${TOKEN}
log:      curl -s "${ENDPOINT}/log" -H "X-aws-proxy-auth: ${TOKEN}"

shell:
  TOKEN=\$(aws lambda-microvms create-microvm-shell-auth-token --region ${REGION} \\
    --microvm-identifier ${ID} --expiration-in-minutes 15 \\
    --query 'authToken."X-aws-proxy-auth"' --output text)
  websocat "${ENDPOINT/https:/wss:}/shell" \\
    -H "Sec-WebSocket-Protocol: lambda-microvms.authentication.\${TOKEN}, lambda-microvms, lambda-microvms.port.8022"

stop:     ./stop.sh ${ID}
EOF
