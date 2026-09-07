#!/usr/bin/env bash
set -euo pipefail

: "${FAST_ORG_ID:?source landing-zone/.fast.env first}"
: "${FAST_BILLING_ACCOUNT:?source landing-zone/.fast.env first}"
: "${FAST_ADMIN_PRINCIPAL:?source landing-zone/.fast.env first}"

MODE="${1:-dry-run}"

ORG_ROLES=(
  roles/logging.admin
  roles/iam.organizationRoleAdmin
  roles/orgpolicy.policyAdmin
  roles/resourcemanager.folderAdmin
  roles/resourcemanager.organizationAdmin
  roles/resourcemanager.projectCreator
  roles/resourcemanager.tagAdmin
  roles/owner
)

cat <<EOF
FAST Stage 0 needs organization-wide bootstrap permissions for the initial principal.

Organization:      ${FAST_ORG_ID}
Billing account:   ${FAST_BILLING_ACCOUNT}
Admin principal:   ${FAST_ADMIN_PRINCIPAL}
Mode:              ${MODE}

These are powerful bootstrap grants. FAST later switches normal Terraform execution to dedicated service accounts with narrower stage-specific privileges.
EOF

run() {
  if [[ "${MODE}" == "--apply" ]]; then
    "$@"
  else
    printf 'DRY RUN: '
    printf '%q ' "$@"
    printf '\n'
  fi
}

printf '\n==> Organization IAM\n'
for role in "${ORG_ROLES[@]}"; do
  run gcloud organizations add-iam-policy-binding "${FAST_ORG_ID}" \
    --member="${FAST_ADMIN_PRINCIPAL}" \
    --role="${role}" \
    --condition=None \
    --quiet
done

printf '\n==> Billing IAM\n'
run gcloud billing accounts add-iam-policy-binding "${FAST_BILLING_ACCOUNT}" \
  --member="${FAST_ADMIN_PRINCIPAL}" \
  --role="roles/billing.admin" \
  --condition=None \
  --quiet

if [[ "${MODE}" != "--apply" ]]; then
  cat <<'EOF'

Nothing was changed. Review the commands above.
If this is a disposable/demo organization and you are authorized to make these grants, run:
  ./landing-zone/scripts/03-grant-bootstrap-roles.sh --apply

If the apply fails with PERMISSION_DENIED, your active identity does not have enough authority to bootstrap FAST. Do not work around that by deploying only at project scope; use the correct organization-admin identity.
EOF
else
  echo
  echo "Bootstrap IAM grants completed."
  echo "Next: ./landing-zone/scripts/04-stage0.sh plan"
fi
