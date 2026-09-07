#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null || true)}"

printf '\n=== FAST Landing Zone prerequisite discovery ===\n\n'

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1)"
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  echo "ERROR: No active gcloud account. Run: gcloud auth login" >&2
  exit 1
fi
printf 'Active account: %s\n' "${ACTIVE_ACCOUNT}"

if [[ -n "${BOOTSTRAP_PROJECT_ID}" && "${BOOTSTRAP_PROJECT_ID}" != "(unset)" ]]; then
  printf 'Bootstrap/quota project: %s\n' "${BOOTSTRAP_PROJECT_ID}"
  BILLING_ENABLED="$(gcloud billing projects describe "${BOOTSTRAP_PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null || true)"
  printf 'Bootstrap project billing enabled: %s\n' "${BILLING_ENABLED:-unknown}"
else
  echo "Bootstrap/quota project: not configured"
fi

printf '\n--- Organizations visible to this account ---\n'
ORG_ROWS="$(gcloud organizations list --format='csv[no-heading](ID,DISPLAY_NAME,DIRECTORY_CUSTOMER_ID)' 2>/dev/null || true)"
if [[ -z "${ORG_ROWS}" ]]; then
  echo "NONE"
  echo
  echo "BLOCKER: FAST Stage 0 requires a Google Cloud Organization."
  echo "A standalone personal project is not enough for a real FAST landing zone."
  echo "Use an account with Organization Admin access to a Cloud Identity / Google Workspace organization."
  exit 2
fi
printf '%s\n' "${ORG_ROWS}"

printf '\n--- Open billing accounts visible to this account ---\n'
BILLING_ROWS="$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](ACCOUNT_ID,NAME)' 2>/dev/null || true)"
if [[ -z "${BILLING_ROWS}" ]]; then
  echo "NONE"
  echo
  echo "BLOCKER: FAST needs a billing account available to the bootstrap principal."
  exit 3
fi
printf '%s\n' "${BILLING_ROWS}"

ORG_COUNT="$(printf '%s\n' "${ORG_ROWS}" | sed '/^$/d' | wc -l | tr -d ' ')"
BILLING_COUNT="$(printf '%s\n' "${BILLING_ROWS}" | sed '/^$/d' | wc -l | tr -d ' ')"

printf '\n--- Selection guidance ---\n'
if [[ "${ORG_COUNT}" == "1" ]]; then
  IFS=',' read -r ORG_ID ORG_DISPLAY_NAME ORG_CUSTOMER_ID <<<"${ORG_ROWS}"
  printf 'export FAST_ORG_ID=%q\n' "${ORG_ID}"
  printf 'export FAST_ORG_DISPLAY_NAME=%q\n' "${ORG_DISPLAY_NAME}"
  # gcloud organizations list returns DISPLAY_NAME, which is not guaranteed to
  # be a DNS/Cloud Identity domain. FAST only requires organization.id in the
  # Stage 0 schema, so leave domain unset unless you know the actual domain.
  printf "export FAST_ORG_DOMAIN=''\n"
  printf 'export FAST_CUSTOMER_ID=%q\n' "${ORG_CUSTOMER_ID}"
else
  echo "Multiple organizations found. Choose the correct row and export FAST_ORG_ID."
  echo "Set FAST_ORG_DOMAIN only if you know the actual Cloud Identity/Workspace domain."
  echo "Set FAST_CUSTOMER_ID if DIRECTORY_CUSTOMER_ID is present."
fi

if [[ "${BILLING_COUNT}" == "1" ]]; then
  IFS=',' read -r BILLING_ACCOUNT_ID BILLING_NAME <<<"${BILLING_ROWS}"
  printf 'export FAST_BILLING_ACCOUNT=%q\n' "${BILLING_ACCOUNT_ID}"
else
  echo "Multiple billing accounts found. Choose the correct ACCOUNT_ID and export FAST_BILLING_ACCOUNT."
fi

printf 'export FAST_ADMIN_PRINCIPAL=%q\n' "user:${ACTIVE_ACCOUNT}"
printf 'export FAST_ADMIN_EMAIL=%q\n' "${ACTIVE_ACCOUNT}"
[[ -n "${BOOTSTRAP_PROJECT_ID}" && "${BOOTSTRAP_PROJECT_ID}" != "(unset)" ]] && printf 'export FAST_BOOTSTRAP_PROJECT=%q\n' "${BOOTSTRAP_PROJECT_ID}"

cat <<'EOF'

FAST recommends using a Google Group for the organization-admin principal in production.
For this personal demo, a user principal is supported and keeps the setup simpler.

Important: organization DISPLAY_NAME is not assumed to be a domain. FAST Stage 0
only requires the organization ID; domain/customer ID are included only when known.

Next, export the values printed above (or choose the correct organization/billing account if multiple rows were returned), then run:
  ./landing-zone/scripts/02-prepare-stage0.sh
EOF
