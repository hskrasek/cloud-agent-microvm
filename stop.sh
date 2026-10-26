#!/usr/bin/env bash
# Usage: ./stop.sh <microvm-id>
set -euo pipefail
ID=${1:?usage: $0 <microvm-id>}
aws lambda-microvms terminate-microvm --region us-east-2 --microvm-identifier "$ID"
