#!/usr/bin/env bash
set -euo pipefail

missing=0

check_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing: $name"
    missing=1
  else
    echo "Found: $name"
  fi
}

check_command aws
check_command docker
check_command git
check_command jq

if command -v terraform >/dev/null 2>&1; then
  echo "Found: terraform"
elif command -v tofu >/dev/null 2>&1; then
  echo "Found: tofu"
else
  echo "Missing: terraform or tofu"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  echo "Install the missing tools, then run this script again."
  exit 1
fi

echo "All required local tools are available."

