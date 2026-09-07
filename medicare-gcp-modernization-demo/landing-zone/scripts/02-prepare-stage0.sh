#!/usr/bin/env bash
set -euo pipefail

: "${FAST_ORG_ID:?Set FAST_ORG_ID from 01-discover-fast.sh output}"
: "${FAST_BILLING_ACCOUNT:?Set FAST_BILLING_ACCOUNT from 01-discover-fast.sh output}"
: "${FAST_ADMIN_PRINCIPAL:?Set FAST_ADMIN_PRINCIPAL, e.g. user:you@example.com}"
: "${FAST_ADMIN_EMAIL:?Set FAST_ADMIN_EMAIL, e.g. you@example.com}"
: "${FAST_BOOTSTRAP_PROJECT:?Set FAST_BOOTSTRAP_PROJECT to the temporary billed project}"

# Optional organization metadata. FAST Stage 0's schema requires organization.id,
# while domain and directory customer ID are optional. Do not confuse the gcloud
# organization DISPLAY_NAME with an actual Cloud Identity / Workspace domain.
FAST_ORG_DOMAIN="${FAST_ORG_DOMAIN:-}"
FAST_CUSTOMER_ID="${FAST_CUSTOMER_ID:-}"
FAST_ORG_DISPLAY_NAME="${FAST_ORG_DISPLAY_NAME:-}"

FAST_PREFIX="${FAST_PREFIX:-medlz}"
FAST_PRIMARY_REGION="${FAST_PRIMARY_REGION:-us-east4}"
FAST_GITHUB_REPO="${FAST_GITHUB_REPO:-jvnstudio/GitHub}"
FAST_VERSION="v58.0.0"

if [[ ! "${FAST_PREFIX}" =~ ^[a-z][a-z0-9-]{1,8}$ ]]; then
  echo "ERROR: FAST_PREFIX must start with a lowercase letter, contain lowercase letters/numbers/hyphens, and be <= 9 characters." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LZ_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FABRIC_DIR="${LZ_ROOT}/.fabric"
GENERATED_DIR="${LZ_ROOT}/generated"
OUTPUT_DIR="${GENERATED_DIR}/outputs"
DEFAULTS_FILE="${GENERATED_DIR}/defaults.yaml"
CICD_FILE="${GENERATED_DIR}/cicd.yaml"
ENV_FILE="${LZ_ROOT}/.fast.env"

mkdir -p "${GENERATED_DIR}" "${OUTPUT_DIR}"

printf '\n==> Validating bootstrap project %s\n' "${FAST_BOOTSTRAP_PROJECT}"
gcloud config set project "${FAST_BOOTSTRAP_PROJECT}" >/dev/null
BILLING_ENABLED="$(gcloud billing projects describe "${FAST_BOOTSTRAP_PROJECT}" --format='value(billingEnabled)' 2>/dev/null || true)"
if [[ "${BILLING_ENABLED}" != "True" && "${BILLING_ENABLED}" != "true" ]]; then
  echo "ERROR: Bootstrap project ${FAST_BOOTSTRAP_PROJECT} does not have billing enabled." >&2
  exit 1
fi

printf '\n==> Enabling FAST bootstrap APIs on temporary project\n'
gcloud services enable \
  bigquery.googleapis.com \
  cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com \
  essentialcontacts.googleapis.com \
  iam.googleapis.com \
  logging.googleapis.com \
  orgpolicy.googleapis.com \
  serviceusage.googleapis.com

printf '\n==> Getting Cloud Foundation Fabric %s\n' "${FAST_VERSION}"
if [[ ! -d "${FABRIC_DIR}/.git" ]]; then
  git clone --depth 1 --branch "${FAST_VERSION}" \
    https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git \
    "${FABRIC_DIR}"
else
  CURRENT="$(git -C "${FABRIC_DIR}" describe --tags --exact-match 2>/dev/null || true)"
  if [[ "${CURRENT}" != "${FAST_VERSION}" ]]; then
    echo "ERROR: ${FABRIC_DIR} exists but is not pinned to ${FAST_VERSION}. Remove it and rerun." >&2
    exit 1
  fi
fi

printf '\n==> Generating Medicare FAST defaults\n'
{
  printf 'global:\n'
  printf '  billing_account: %s\n' "${FAST_BILLING_ACCOUNT}"
  printf '  organization:\n'
  printf '    id: %s\n' "${FAST_ORG_ID}"
  if [[ -n "${FAST_ORG_DOMAIN}" ]]; then
    printf '    domain: %s\n' "${FAST_ORG_DOMAIN}"
  fi
  if [[ -n "${FAST_CUSTOMER_ID}" ]]; then
    printf '    customer_id: %s\n' "${FAST_CUSTOMER_ID}"
  fi
  cat <<EOF
observability:
  project_id: \$project_ids:log-0
  number: \$project_numbers:log-0
projects:
  defaults:
    prefix: ${FAST_PREFIX}
    locations:
      bigquery: \$locations:primary
      logging: \$locations:primary
      storage: \$locations:primary
  overrides: {}
context:
  email_addresses:
    gcp-organization-admins: ${FAST_ADMIN_EMAIL}
  iam_principals:
    gcp-organization-admins: ${FAST_ADMIN_PRINCIPAL}
  locations:
    primary: ${FAST_PRIMARY_REGION}
output_files:
  local_path: ${OUTPUT_DIR}
  storage_bucket: \$storage_buckets:iac-0/iac-outputs
  providers:
    0-org-setup:
      bucket: \$storage_buckets:iac-0/iac-org-state
      service_account: \$iam_principals:service_accounts/iac-0/iac-org-rw
    0-org-setup-ro:
      bucket: \$storage_buckets:iac-0/iac-org-state
      service_account: \$iam_principals:service_accounts/iac-0/iac-org-ro
    1-vpcsc:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 1-vpcsc
      service_account: \$iam_principals:service_accounts/iac-0/iac-vpcsc-rw
    1-vpcsc-ro:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 1-vpcsc
      service_account: \$iam_principals:service_accounts/iac-0/iac-vpcsc-ro
    2-networking:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 2-networking
      service_account: \$iam_principals:service_accounts/iac-0/iac-networking-rw
    2-networking-ro:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 2-networking
      service_account: \$iam_principals:service_accounts/iac-0/iac-networking-ro
    2-security:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 2-security
      service_account: \$iam_principals:service_accounts/iac-0/iac-security-rw
    2-security-ro:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 2-security
      service_account: \$iam_principals:service_accounts/iac-0/iac-security-ro
    2-project-factory:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 2-project-factory
      service_account: \$iam_principals:service_accounts/iac-0/iac-pf-rw
    2-project-factory-ro:
      bucket: \$storage_buckets:iac-0/iac-stage-state
      prefix: 2-project-factory
      service_account: \$iam_principals:service_accounts/iac-0/iac-pf-ro
EOF
} >"${DEFAULTS_FILE}"

cat >"${CICD_FILE}" <<EOF
org-setup:
  provider_files:
    apply: 0-org-setup-providers.tf
    plan: 0-org-setup-ro-providers.tf
  repository:
    name: ${FAST_GITHUB_REPO}
    type: github
    apply_branches:
      - main
      - demo/medicare-gcp-modernization
  service_accounts:
    apply: \$iam_principals:service_accounts/iac-0/iac-org-cicd-rw
    plan: \$iam_principals:service_accounts/iac-0/iac-org-cicd-ro
  tfvars_files:
    - 0-org-setup.auto.tfvars
  workload_identity:
    pool: \$workload_identity_pools:iac-0/default
    provider: \$workload_identity_providers:iac-0/default/github-default
    iam_principalsets:
      template: github
EOF

STAGE0_DIR="${FABRIC_DIR}/fast/stages/0-org-setup"
cat >"${STAGE0_DIR}/0-org-setup.auto.tfvars" <<EOF
factories_config = {
  dataset = "datasets/classic"
  paths = {
    defaults       = "${DEFAULTS_FILE}"
    cicd_workflows = "${CICD_FILE}"
  }
}
EOF

cat >"${ENV_FILE}" <<EOF
export FAST_VERSION='${FAST_VERSION}'
export FAST_ORG_ID='${FAST_ORG_ID}'
export FAST_ORG_DISPLAY_NAME='${FAST_ORG_DISPLAY_NAME}'
export FAST_ORG_DOMAIN='${FAST_ORG_DOMAIN}'
export FAST_CUSTOMER_ID='${FAST_CUSTOMER_ID}'
export FAST_BILLING_ACCOUNT='${FAST_BILLING_ACCOUNT}'
export FAST_ADMIN_PRINCIPAL='${FAST_ADMIN_PRINCIPAL}'
export FAST_ADMIN_EMAIL='${FAST_ADMIN_EMAIL}'
export FAST_BOOTSTRAP_PROJECT='${FAST_BOOTSTRAP_PROJECT}'
export FAST_PREFIX='${FAST_PREFIX}'
export FAST_PRIMARY_REGION='${FAST_PRIMARY_REGION}'
export FAST_GITHUB_REPO='${FAST_GITHUB_REPO}'
export FAST_STAGE0_DIR='${STAGE0_DIR}'
export FAST_OUTPUT_DIR='${OUTPUT_DIR}'
EOF

printf '\nPrepared FAST Stage 0.\n'
printf '  Fabric source: %s\n' "${FABRIC_DIR}"
printf '  Stage 0:       %s\n' "${STAGE0_DIR}"
printf '  Defaults:      %s\n' "${DEFAULTS_FILE}"
printf '  CI/CD config:  %s\n' "${CICD_FILE}"
printf '  Environment:   %s\n' "${ENV_FILE}"
printf '  Org domain:    %s\n' "${FAST_ORG_DOMAIN:-<not set>}"
printf '  Customer ID:   %s\n' "${FAST_CUSTOMER_ID:-<not set>}"
printf '\nNext:\n'
printf '  source %q\n' "${ENV_FILE}"
printf '  ./landing-zone/scripts/03-grant-bootstrap-roles.sh\n'
