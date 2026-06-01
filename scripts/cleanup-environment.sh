#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION}"
: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET}"
: "${TF_LOCK_TABLE:?Set TF_LOCK_TABLE}"
: "${TF_STATE_KEY:?Set TF_STATE_KEY}"
: "${PROJECT_NAME:?Set PROJECT_NAME}"
: "${ENVIRONMENT:?Set ENVIRONMENT}"
: "${IMAGE_URI:?Set IMAGE_URI to any valid image URI or placeholder}"

CONTAINER_PORT="${CONTAINER_PORT:-8080}"
INFRA_DIR="${INFRA_DIR:-infra}"

if command -v terraform >/dev/null 2>&1; then
  TF_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
  TF_BIN="tofu"
else
  echo "terraform or tofu is required."
  exit 1
fi

cd "${INFRA_DIR}"

"${TF_BIN}" init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=${TF_LOCK_TABLE}" \
  -backend-config="encrypt=true"

"${TF_BIN}" destroy -auto-approve \
  -var="project_name=${PROJECT_NAME}" \
  -var="environment=${ENVIRONMENT}" \
  -var="aws_region=${AWS_REGION}" \
  -var="image_uri=${IMAGE_URI}" \
  -var="container_port=${CONTAINER_PORT}"

