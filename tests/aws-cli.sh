#!/usr/bin/env bash
#
# Exercises common AWS CLI workflows against the emulator. Expects the
# environment exported by the action (AWS_ENDPOINT_URL, credentials, etc.).

set -euo pipefail

suffix="${GITHUB_RUN_ID:-local}-${RANDOM}"

echo "--- STS: caller identity"
account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${account}" == "000000000000" ]] || {
  echo "Unexpected account: ${account}"
  exit 1
}

echo "--- S3: bucket and object round trip"
bucket="test-bucket-${suffix,,}"
bucket="${bucket//_/-}"
echo "hello from setup-aws-emulator" >"${RUNNER_TEMP:-/tmp}/upload.txt"
aws s3 mb "s3://${bucket}"
aws s3 cp "${RUNNER_TEMP:-/tmp}/upload.txt" "s3://${bucket}/path/upload.txt"
aws s3 ls "s3://${bucket}/path/"
aws s3 cp "s3://${bucket}/path/upload.txt" "${RUNNER_TEMP:-/tmp}/download.txt"
diff "${RUNNER_TEMP:-/tmp}/upload.txt" "${RUNNER_TEMP:-/tmp}/download.txt"

echo "--- DynamoDB: table, put, get"
table="test-table-${suffix}"
aws dynamodb create-table \
  --table-name "${table}" \
  --attribute-definitions AttributeName=pk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST >/dev/null
aws dynamodb wait table-exists --table-name "${table}"
aws dynamodb put-item --table-name "${table}" \
  --item '{"pk": {"S": "item-1"}, "value": {"S": "hello"}}'
value="$(aws dynamodb get-item --table-name "${table}" \
  --key '{"pk": {"S": "item-1"}}' --query 'Item.value.S' --output text)"
[[ "${value}" == "hello" ]] || {
  echo "Unexpected DynamoDB value: ${value}"
  exit 1
}

echo "--- SQS: send and receive"
queue_url="$(aws sqs create-queue --queue-name "test-queue-${suffix}" --query QueueUrl --output text)"
aws sqs send-message --queue-url "${queue_url}" --message-body "ping" >/dev/null
body="$(aws sqs receive-message --queue-url "${queue_url}" --wait-time-seconds 1 \
  --query 'Messages[0].Body' --output text)"
[[ "${body}" == "ping" ]] || {
  echo "Unexpected SQS message: ${body}"
  exit 1
}

echo "--- SSM Parameter Store: put and get"
aws ssm put-parameter --name "/test/${suffix}/greeting" --type String --value "hi" >/dev/null
param="$(aws ssm get-parameter --name "/test/${suffix}/greeting" --query Parameter.Value --output text)"
[[ "${param}" == "hi" ]] || {
  echo "Unexpected SSM parameter: ${param}"
  exit 1
}

echo "All AWS CLI checks passed."
