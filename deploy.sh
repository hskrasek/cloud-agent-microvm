#!/usr/bin/env bash
# Package the image artifact, upload to S3, create or version the MicroVM image, wait for the build.
set -euo pipefail
cd "$(dirname "$0")"

REGION=us-east-2
NAME=cloud-agent
IMAGE_ARN="arn:aws:lambda:${REGION}:$(aws sts get-caller-identity --query Account --output text):microvm-image:${NAME}"
BASE_IMAGE_ARN="arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1"
BUCKET=$(tofu -chdir=.infra output -raw artifact_bucket)
BUILD_ROLE=$(tofu -chdir=.infra output -raw build_role_arn)
ARTIFACT="s3://${BUCKET}/${NAME}.zip"

HOOKS='{
  "port": 8080,
  "microvmImageHooks": {
    "ready": "ENABLED", "readyTimeoutInSeconds": 120,
    "validate": "ENABLED", "validateTimeoutInSeconds": 180
  },
  "microvmHooks": {
    "run": "ENABLED", "runTimeoutInSeconds": 30,
    "resume": "ENABLED", "resumeTimeoutInSeconds": 30,
    "suspend": "ENABLED", "suspendTimeoutInSeconds": 30,
    "terminate": "ENABLED", "terminateTimeoutInSeconds": 30
  }
}'

mkdir -p build
rm -f "build/${NAME}.zip"
zip -q -j "build/${NAME}.zip" Dockerfile worker.mjs package.json index.html settings.json
aws s3 cp "build/${NAME}.zip" "$ARTIFACT" --region "$REGION"

if ! aws lambda-microvms get-microvm-image --region "$REGION" --image-identifier "$IMAGE_ARN" >/dev/null 2>&1; then
  echo "creating image ${NAME}"
  VERSION=$(aws lambda-microvms create-microvm-image --region "$REGION" \
    --name "$NAME" \
    --base-image-arn "$BASE_IMAGE_ARN" \
    --build-role-arn "$BUILD_ROLE" \
    --code-artifact "{\"uri\":\"${ARTIFACT}\"}" \
    --hooks "$HOOKS" \
    --query imageVersion --output text)
else
  echo "updating image ${IMAGE_ARN} (new version)"
  VERSION=$(aws lambda-microvms update-microvm-image --region "$REGION" \
    --image-identifier "$IMAGE_ARN" \
    --base-image-arn "$BASE_IMAGE_ARN" \
    --build-role-arn "$BUILD_ROLE" \
    --code-artifact "{\"uri\":\"${ARTIFACT}\"}" \
    --hooks "$HOOKS" \
    --query imageVersion --output text)
fi

echo "waiting on ${IMAGE_ARN} version ${VERSION}"
while :; do
  INFO=$(aws lambda-microvms get-microvm-image-version --region "$REGION" \
    --image-identifier "$IMAGE_ARN" --image-version "$VERSION" --output json)
  STATE=$(echo "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))')
  echo "  state: ${STATE}"
  case "$STATE" in
    SUCCESSFUL) break ;;
    FAILED)
      echo "build failed:" >&2
      echo "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stateReason",""))' >&2
      echo "logs: CloudWatch log group /aws/lambda-microvms/${NAME} (region ${REGION})" >&2
      exit 1 ;;
  esac
  sleep 15
done

echo "image:   ${IMAGE_ARN}"
echo "version: ${VERSION}"
