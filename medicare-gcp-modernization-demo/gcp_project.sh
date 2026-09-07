#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-Medicare Modernization Demo}"

# Google Cloud project IDs are globally unique. Generate a short, valid ID
# instead of relying on a fixed demo name that may already be taken.
if [[ -z "${PROJECT_ID:-}" ]]; then
  RAND_SUFFIX="$(printf '%04x' $((RANDOM % 65536)))"
  PROJECT_ID="medicare-demo-$(date +%y%m%d)-${RAND_SUFFIX}"
fi

if [[ ! "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  echo "ERROR: PROJECT_ID '$PROJECT_ID' is not a valid Google Cloud project ID." >&2
  echo "Use 6-30 lowercase letters, digits, or hyphens; start with a letter and do not end with a hyphen." >&2
  exit 1
fi

echo "Creating Google Cloud project: $PROJECT_ID"
gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"

gcloud config set project "$PROJECT_ID"

cat > .project.env <<EOF
export PROJECT_ID="$PROJECT_ID"
EOF

echo
echo "Project created successfully."
echo "PROJECT_ID=$PROJECT_ID"
echo "Saved to .project.env"
echo
echo "Next:" 
echo "  source .project.env"
echo "  gcloud billing accounts list"
echo

if [[ -n "${BILLING_ACCOUNT:-}" ]]; then
  echo "Linking billing account: $BILLING_ACCOUNT"
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
  gcloud billing projects describe "$PROJECT_ID"
else
  echo "Then set and link your billing account:"
  echo '  export BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"'
  echo '  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"'
  echo '  gcloud billing projects describe "$PROJECT_ID"'
fi
