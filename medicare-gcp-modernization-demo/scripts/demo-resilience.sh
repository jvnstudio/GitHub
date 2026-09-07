#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${1:-}"
PRIMARY_REGION="${2:-us-east4}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Usage: $0 <gcp-project-id> [primary-region]" >&2
  exit 1
fi

gcloud config set project "${PROJECT_ID}" >/dev/null

cat <<'EOF'

============================================================
1. VM regional managed instance group
============================================================
EOF

gcloud compute instance-groups managed list-instances medicare-portal-primary \
  --region="${PRIMARY_REGION}" \
  --format='table(instance.basename():label=INSTANCE,zone.basename():label=ZONE,instanceStatus:label=STATUS,currentAction:label=ACTION)'

printf '\nVM public addresses:\n'
gcloud compute instances list \
  --filter='name~medicare-portal-primary' \
  --format='table(name,zone.basename(),networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)'

read -r -p $'\nDelete one MIG VM to demonstrate autohealing? [y/N] ' answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  read -r INSTANCE ZONE < <(
    gcloud compute instance-groups managed list-instances medicare-portal-primary \
      --region="${PRIMARY_REGION}" \
      --limit=1 \
      --format='value(instance.basename(),zone.basename())'
  )

  echo "Deleting ${INSTANCE} in ${ZONE}. The regional MIG should recreate capacity automatically."
  gcloud compute instances delete "${INSTANCE}" --zone="${ZONE}" --quiet

  echo
  echo "Watch recovery with:"
  echo "gcloud compute instance-groups managed list-instances medicare-portal-primary --region=${PRIMARY_REGION}"
fi

cat <<'EOF'

============================================================
2. Regional GKE workload
============================================================
EOF

gcloud container clusters get-credentials medicare-gke-primary \
  --region="${PRIMARY_REGION}" \
  --project="${PROJECT_ID}"

kubectl apply -f "${ROOT_DIR}/kubernetes/portal.yaml"
kubectl rollout status deployment/medicare-portal --timeout=5m

echo
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get pods -o wide
kubectl get service medicare-portal

read -r -p $'\nDelete one application Pod to demonstrate Kubernetes self-healing? [y/N] ' answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  POD="$(kubectl get pods -l app=medicare-portal -o jsonpath='{.items[0].metadata.name}')"
  kubectl delete pod "${POD}"
  kubectl rollout status deployment/medicare-portal --timeout=5m
  kubectl get pods -o wide
fi

cat <<'EOF'

============================================================
3. What to show the audience
============================================================
- The VM MIG distributes capacity across zones and recreates a deleted VM.
- GKE maintains the requested replica count after a Pod failure.
- `kubectl get pods -o wide` shows scheduling across nodes/zones.
- `kubectl get service medicare-portal` shows the container app endpoint.
- GitHub Actions shows the auditable Terraform plan/apply trail.
- Cloud Audit Logs records the Google Cloud API changes.
EOF
