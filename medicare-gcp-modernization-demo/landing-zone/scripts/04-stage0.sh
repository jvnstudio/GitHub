#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LZ_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${LZ_ROOT}/.fast.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Run 01-discover-fast.sh and 02-prepare-stage0.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${FAST_STAGE0_DIR:?FAST_STAGE0_DIR missing from .fast.env}"
: "${FAST_BOOTSTRAP_PROJECT:?FAST_BOOTSTRAP_PROJECT missing from .fast.env}"

ACTION="${1:-plan}"
PLAN_FILE="${FAST_STAGE0_DIR}/fast-stage0.tfplan"

gcloud config set project "${FAST_BOOTSTRAP_PROJECT}" >/dev/null
cd "${FAST_STAGE0_DIR}"

case "${ACTION}" in
  init)
    terraform init
    ;;
  validate)
    terraform init
    terraform validate
    ;;
  plan)
    terraform init
    terraform validate
    terraform plan -out="${PLAN_FILE}"
    echo
    echo "FAST Stage 0 plan saved to: ${PLAN_FILE}"
    echo "Review the plan carefully. It contains organization-, folder-, project-, IAM-, policy- and logging-level changes."
    echo "When satisfied, run: ./landing-zone/scripts/04-stage0.sh apply"
    ;;
  apply)
    if [[ ! -f "${PLAN_FILE}" ]]; then
      echo "ERROR: No saved plan at ${PLAN_FILE}. Run plan first." >&2
      exit 1
    fi
    echo
    echo "You are about to apply FAST Stage 0 to organization ${FAST_ORG_ID}."
    echo "This is an organization-level change, not a project-only lab."
    echo
    read -r -p "Type APPLY_FAST_STAGE0 to continue: " CONFIRM
    if [[ "${CONFIRM}" != "APPLY_FAST_STAGE0" ]]; then
      echo "Cancelled."
      exit 1
    fi
    terraform apply "${PLAN_FILE}"
    echo
    echo "First FAST Stage 0 apply completed."
    echo "Next inspect outputs with: ./landing-zone/scripts/04-stage0.sh outputs"
    echo "Then follow landing-zone/README.md for provider/backend migration."
    ;;
  outputs)
    terraform output
    ;;
  *)
    echo "Usage: $0 {init|validate|plan|apply|outputs}" >&2
    exit 1
    ;;
esac
