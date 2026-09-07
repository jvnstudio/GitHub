#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-}"
GITHUB_REPO="${2:-jvnstudio/GitHub}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Usage: $0 <gcp-project-id> [github-owner/repo]" >&2
  exit 1
fi

REGION="us-east4"
STATE_BUCKET="${PROJECT_ID}-medicare-tfstate"
SA_ID="medicare-demo-tf"
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_ID="github-actions"
PROVIDER_ID="github"
OUTPUT_FILE="$(cd "$(dirname "$0")/.." && pwd)/.bootstrap.env"

printf '\n==> Configuring project %s\n' "${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

printf '\n==> Enabling APIs\n'
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  file.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com

printf '\n==> Creating Terraform state bucket if needed\n'
if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --location=US \
    --uniform-bucket-level-access
fi

gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning >/dev/null

printf '\n==> Creating Terraform service account if needed\n'
if ! gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_ID}" \
    --display-name="Medicare modernization demo Terraform"
fi

# These are intentionally project-scoped demo roles. Production should split
# plan/apply identities and reduce permissions further, as FAST itself does.
ROLES=(
  roles/compute.admin
  roles/container.admin
  roles/storage.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountUser
  roles/resourcemanager.projectIamAdmin
  roles/serviceusage.serviceUsageAdmin
)

printf '\n==> Granting demo Terraform roles\n'
for role in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done

printf '\n==> Creating Workload Identity Pool if needed\n'
if ! gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --location=global \
    --display-name="GitHub Actions"
fi

printf '\n==> Creating GitHub OIDC provider if needed\n'
if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --workload-identity-pool="${POOL_ID}" \
  --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --workload-identity-pool="${POOL_ID}" \
    --location=global \
    --display-name="GitHub" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.actor=assertion.actor" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'"
fi

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
POOL_NAME="$(gcloud iam workload-identity-pools describe "${POOL_ID}" --location=global --format='value(name)')"
WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

printf '\n==> Allowing only %s to impersonate the Terraform service account\n' "${GITHUB_REPO}"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${POOL_NAME}/attribute.repository/${GITHUB_REPO}" \
  --quiet >/dev/null

cat >"${OUTPUT_FILE}" <<EOF
export GCP_PROJECT_ID='${PROJECT_ID}'
export GCP_REGION='${REGION}'
export TF_STATE_BUCKET='${STATE_BUCKET}'
export GCP_TF_SERVICE_ACCOUNT='${SA_EMAIL}'
export GCP_WIF_PROVIDER='${WIF_PROVIDER}'
export GITHUB_REPO='${GITHUB_REPO}'
EOF

printf '\nBootstrap complete.\n\n'
printf 'Environment file: %s\n\n' "${OUTPUT_FILE}"
printf 'Run:\n'
printf '  source %q\n' "${OUTPUT_FILE}"
printf '  gh variable set GCP_PROJECT_ID --body "$GCP_PROJECT_ID" --repo "$GITHUB_REPO"\n'
printf '  gh variable set TF_STATE_BUCKET --body "$TF_STATE_BUCKET" --repo "$GITHUB_REPO"\n'
printf '  gh variable set GCP_TF_SERVICE_ACCOUNT --body "$GCP_TF_SERVICE_ACCOUNT" --repo "$GITHUB_REPO"\n'
printf '  gh variable set GCP_WIF_PROVIDER --body "$GCP_WIF_PROVIDER" --repo "$GITHUB_REPO"\n\n'
printf 'No GCP service-account key file was created.\n'
