# Medicare Portal Infrastructure Modernization Demo on Google Cloud

This is a deployable proof-of-concept for the infrastructure-modernization scenario:

- legacy on-premises virtualization is at capacity;
- applications include VM-based and container-based deployments;
- workloads use local, network, and object storage patterns;
- production requirements include zone separation, geographic redundancy, `<15 minute` RTO for mission-critical VM applications, and automated/auditable deployments.

The demo uses **Terraform + Google Cloud Foundation Fabric v58.0.0** for the core infrastructure and **GitHub Actions + Workload Identity Federation (WIF)** for keyless CI/CD.

> **Cost warning:** GKE, Compute Engine, Local SSD, Filestore, and egress are billable. The default lab leaves the most expensive optional resources disabled. Destroy the environment when you are finished.

## What the default demo actually deploys

| Capability | Demo implementation |
|---|---|
| VM application | Regional Compute Engine managed instance group, three-zone distribution, health check, autohealing |
| Container application | Regional GKE Standard cluster, multi-zone node pool, three replicas, PDB, topology spreading |
| Object storage | Versioned US Cloud Storage bucket with soft delete |
| DR network foundation | Primary and secondary-region subnets |
| Warm DR compute | Available with `enable_dr=true`; off by default |
| Local storage | Local SSD available with `enable_local_ssd=true`; off by default |
| Network file storage | Enterprise/Regional Filestore available with `enable_filestore=true`; off by default |
| Automation | Terraform using Fabric modules |
| Audit trail | Git history + Actions + WIF identity + Cloud Audit Logs |

Read [docs/architecture.md](docs/architecture.md) before presenting the solution and [docs/discovery.md](docs/discovery.md) for the discovery questions/assumptions.

---

# 1. Prerequisites

Run the lab from **Google Cloud Shell** or another workstation with:

```bash
gcloud version
terraform version
git --version
kubectl version --client
gh --version
```

Fabric v58.0.0 requires Terraform `>= 1.12.2` and Google/Google Beta providers `>= 7.40.0, < 8.0.0`. The Terraform configuration in this repo pins those provider constraints.

You need a GCP project with billing enabled. For a clean demo, a dedicated disposable project is preferable.

## Option A: use an existing billed project

```bash
export PROJECT_ID="YOUR_EXISTING_PROJECT_ID"
gcloud config set project "$PROJECT_ID"
gcloud billing projects describe "$PROJECT_ID"
```

## Option B: create a disposable project

Choose a globally unique project ID:

```bash
export PROJECT_ID="YOUR-UNIQUE-MEDICARE-DEMO-ID"
gcloud projects create "$PROJECT_ID" --name="Medicare Modernization Demo"
```

Find your billing account:

```bash
gcloud billing accounts list
```

Then link it:

```bash
export BILLING_ACCOUNT="000000-000000-000000"
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
```

Confirm:

```bash
gcloud billing projects describe "$PROJECT_ID"
```

---

# 2. Clone the demo branch

```bash
cd ~
git clone --branch demo/medicare-gcp-modernization \
  https://github.com/jvnstudio/GitHub.git medicare-gcp-demo

cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo
```

Confirm the files:

```bash
find . -maxdepth 3 -type f | sort
```

You should see:

```text
.github/workflows/medicare-demo-terraform.yml   # at repository root
medicare-gcp-modernization-demo/
├── README.md
├── docs/
│   ├── architecture.md
│   └── discovery.md
├── kubernetes/
│   └── portal.yaml
├── scripts/
│   ├── bootstrap.sh
│   └── demo-resilience.sh
└── terraform/
    ├── main.tf
    ├── outputs.tf
    ├── terraform.tfvars.example
    ├── variables.tf
    └── versions.tf
```

---

# 3. Bootstrap GCP and GitHub keyless authentication

The bootstrap script does four things:

1. enables the required Google Cloud APIs;
2. creates a versioned GCS Terraform-state bucket;
3. creates a project-scoped Terraform service account;
4. creates a GitHub OIDC Workload Identity Pool/provider restricted to `jvnstudio/GitHub`.

Run:

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh "$PROJECT_ID" "jvnstudio/GitHub"
```

The script writes non-secret values to:

```text
.bootstrap.env
```

Load them:

```bash
source .bootstrap.env
```

Check them:

```bash
printf 'Project: %s\nState bucket: %s\nService account: %s\nWIF provider: %s\n' \
  "$GCP_PROJECT_ID" \
  "$TF_STATE_BUCKET" \
  "$GCP_TF_SERVICE_ACCOUNT" \
  "$GCP_WIF_PROVIDER"
```

No GCP service-account JSON key is created.

---

# 4. Configure GitHub repository variables

Authenticate GitHub CLI if needed:

```bash
gh auth status || gh auth login
```

Set the non-secret repository variables used by the workflow:

```bash
gh variable set GCP_PROJECT_ID \
  --body "$GCP_PROJECT_ID" \
  --repo "$GITHUB_REPO"

gh variable set TF_STATE_BUCKET \
  --body "$TF_STATE_BUCKET" \
  --repo "$GITHUB_REPO"

gh variable set GCP_TF_SERVICE_ACCOUNT \
  --body "$GCP_TF_SERVICE_ACCOUNT" \
  --repo "$GITHUB_REPO"

gh variable set GCP_WIF_PROVIDER \
  --body "$GCP_WIF_PROVIDER" \
  --repo "$GITHUB_REPO"
```

Verify:

```bash
gh variable list --repo "$GITHUB_REPO"
```

These are identifiers, not private keys or passwords.

---

# 5. Configure Terraform variables

```bash
cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo/terraform
cp terraform.tfvars.example terraform.tfvars
```

Replace the placeholder project ID:

```bash
sed -i "s/REPLACE_WITH_YOUR_GCP_PROJECT_ID/$PROJECT_ID/" terraform.tfvars
cat terraform.tfvars
```

The initial lab should remain:

```hcl
vm_target_size   = 3
enable_gke       = true
enable_dr        = false
enable_filestore = false
enable_local_ssd = false
```

This gives you the core proof points without the extra DR/Filestore/Local-SSD spend.

---

# 6. Initialize and validate Terraform

Initialize the remote GCS backend:

```bash
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET"
```

Run formatting and validation:

```bash
terraform fmt -recursive
terraform validate
```

Create a plan:

```bash
terraform plan -out=tfplan
```

Read the plan. You should see resources for networking, a regional MIG, regional GKE, node pool, and object storage.

Apply:

```bash
terraform apply tfplan
```

After completion:

```bash
terraform output
```

---

# 7. Validate the VM workload

The VM application uses a **regional managed instance group**. Fabric's `compute-vm` module creates the instance template; Fabric's `compute-mig` module manages the regional group, health check, and autohealing.

List the group:

```bash
gcloud compute instance-groups managed list
```

Show zone distribution:

```bash
gcloud compute instance-groups managed list-instances medicare-portal-primary \
  --region=us-east4 \
  --format='table(instance.basename(),zone.basename(),instanceStatus,currentAction)'
```

You should see instances distributed across zones such as:

```text
us-east4-a
us-east4-b
us-east4-c
```

List their demo public addresses:

```bash
gcloud compute instances list \
  --filter='name~medicare-portal-primary' \
  --format='table(name,zone.basename(),networkInterfaces[0].accessConfigs[0].natIP,status)'
```

Curl one of the IP addresses:

```bash
export VM_IP="REPLACE_WITH_ONE_EXTERNAL_IP"
curl "http://$VM_IP/"
curl "http://$VM_IP/health"
```

Expected health response:

```text
ok
```

> Production difference: the VMs should normally be private and behind a global external Application Load Balancer and Cloud Armor. Public VM NICs are used here only so the lab is easy to demonstrate.

---

# 8. Demonstrate VM autohealing

Record the current instance list:

```bash
gcloud compute instance-groups managed list-instances medicare-portal-primary \
  --region=us-east4
```

Choose one managed VM and delete it:

```bash
export FAILED_VM="REPLACE_WITH_VM_NAME"
export FAILED_ZONE="REPLACE_WITH_VM_ZONE"

gcloud compute instances delete "$FAILED_VM" \
  --zone="$FAILED_ZONE" \
  --quiet
```

Now watch the MIG:

```bash
watch -n 5 'gcloud compute instance-groups managed list-instances medicare-portal-primary --region=us-east4'
```

The managed instance group recreates capacity automatically.

This is your talking point:

> "A single VM failure is handled by autohealing. A zone failure is handled by the regional MIG maintaining capacity across zones. A region failure is a separate DR problem and requires secondary-region infrastructure and replicated state."

You can also use the helper:

```bash
cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo
./scripts/demo-resilience.sh "$PROJECT_ID"
```

---

# 9. Deploy the container workload to regional GKE

Get credentials:

```bash
gcloud container clusters get-credentials medicare-gke-primary \
  --region=us-east4 \
  --project="$PROJECT_ID"
```

If `kubectl` reports an authentication plugin problem, ensure the GKE auth plugin is installed in your environment.

Show nodes and zones:

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

Deploy the portal:

```bash
cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo
kubectl apply -f kubernetes/portal.yaml
```

Wait for the Deployment:

```bash
kubectl rollout status deployment/medicare-portal --timeout=5m
```

Inspect Pods:

```bash
kubectl get pods -o wide
```

The manifest requests three replicas and uses topology spreading across `topology.kubernetes.io/zone`.

Inspect the disruption budget:

```bash
kubectl get pdb medicare-portal
```

Inspect the service:

```bash
kubectl get service medicare-portal
```

Wait until `EXTERNAL-IP` is populated:

```bash
kubectl get service medicare-portal -w
```

Stop the watch with `Ctrl+C`, then:

```bash
export GKE_IP="REPLACE_WITH_SERVICE_EXTERNAL_IP"
curl "http://$GKE_IP/"
```

You should see **Medicare Portal - Container Workload**.

---

# 10. Demonstrate Kubernetes self-healing

List the Pods:

```bash
kubectl get pods -l app=medicare-portal -o wide
```

Delete one:

```bash
export POD="$(kubectl get pods -l app=medicare-portal \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl delete pod "$POD"
```

Immediately inspect the Deployment:

```bash
kubectl get pods -l app=medicare-portal -o wide -w
```

Kubernetes creates a replacement because the Deployment's desired replica count remains three.

Talking point:

> "The container platform handles Pod and node failure differently from the VM platform, but both are designed around declared desired state and automated recovery."

---

# 11. Demonstrate object storage

Get the Fabric-created bucket:

```bash
cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo/terraform
export OBJECT_BUCKET="$(terraform output -raw object_bucket)"
echo "$OBJECT_BUCKET"
```

Upload an object:

```bash
echo "Medicare modernization demo $(date -Is)" >/tmp/demo-object.txt
gcloud storage cp /tmp/demo-object.txt "gs://$OBJECT_BUCKET/demo-object.txt"
```

Read it:

```bash
gcloud storage cat "gs://$OBJECT_BUCKET/demo-object.txt"
```

Upload a second version:

```bash
echo "Updated demo $(date -Is)" >/tmp/demo-object.txt
gcloud storage cp /tmp/demo-object.txt "gs://$OBJECT_BUCKET/demo-object.txt"
```

The Terraform module enables bucket versioning and soft deletion. Use this point to explain why object data is separated from VM-local state.

---

# 12. Optional: demonstrate Local SSD

Local SSD should represent **scratch/cache/transient** data only, never the authoritative member record.

Enable it:

```bash
cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo/terraform
terraform apply -var='enable_local_ssd=true'
```

This may replace/recreate VM template/group instances and incurs additional cost.

Disable after the demonstration:

```bash
terraform apply -var='enable_local_ssd=false'
```

Talking point:

> "Local SSD solves a performance problem, not a durability problem. Durable state belongs on durable block, file, database, or object services."

---

# 13. Optional: demonstrate network file storage

Enterprise/Regional Filestore is disabled by default because it is expensive compared with the rest of this lab.

Enable only when you intentionally want to show the shared-NFS pattern:

```bash
terraform apply -var='enable_filestore=true'
```

Then:

```bash
terraform output filestore_ip
```

Disable when finished:

```bash
terraform apply -var='enable_filestore=false'
```

For the presentation, the important decision is not merely "use Filestore". Ask about protocol, capacity, throughput, latency, RPO, and whether the shared-filesystem layer itself must meet the same `<15 minute` regional recovery target.

---

# 14. Optional: create warm DR VM capacity

Enable the secondary-region regional MIG:

```bash
terraform apply -var='enable_dr=true'
```

List the DR group:

```bash
gcloud compute instance-groups managed list-instances medicare-portal-dr \
  --region=us-central1
```

This proves that secondary-region networking and compute can be deployed ahead of a disaster.

**Important:** this lab does not pretend that creating a second MIG alone satisfies the `<15 minute` RTO. Production mission-critical state also requires tested data replication (for example block/database/application replication) and traffic failover orchestration.

Disable DR compute after the demonstration if you no longer need it:

```bash
terraform apply -var='enable_dr=false'
```

---

# 15. Run Terraform through GitHub Actions

The repository contains:

```text
.github/workflows/medicare-demo-terraform.yml
```

The workflow:

- uses GitHub OIDC;
- exchanges the GitHub identity through GCP Workload Identity Federation;
- does **not** use a service-account JSON key;
- runs `terraform fmt`, `init`, `validate`, and `plan`;
- runs `apply` or `destroy` only through an explicit manual dispatch.

## Pull-request audit demonstration

Create a small Terraform change on a feature branch, for example changing:

```hcl
vm_target_size = 3
```

to:

```hcl
vm_target_size = 4
```

Commit and push:

```bash
git checkout -b demo/scale-medicare-mig
# edit the relevant variable/tfvars example or Terraform default
git add .
git commit -m "Demo scaling Medicare portal VM capacity"
git push -u origin demo/scale-medicare-mig
```

Open a PR:

```bash
gh pr create \
  --repo jvnstudio/GitHub \
  --base main \
  --head demo/scale-medicare-mig \
  --title "Demo: scale Medicare portal capacity" \
  --body "Shows auditable Terraform plan through GitHub Actions and GCP Workload Identity Federation."
```

Show the audience:

1. the Git diff;
2. the PR author;
3. the Terraform workflow/plan;
4. the reviewer/approval process;
5. the corresponding GCP audit events after an approved manual apply.

## Manually run plan/apply/destroy from GitHub CLI

List workflows:

```bash
gh workflow list --repo jvnstudio/GitHub
```

Manual plan:

```bash
gh workflow run "Medicare GCP modernization demo" \
  --repo jvnstudio/GitHub \
  --ref demo/medicare-gcp-modernization \
  -f operation=plan
```

Manual apply:

```bash
gh workflow run "Medicare GCP modernization demo" \
  --repo jvnstudio/GitHub \
  --ref demo/medicare-gcp-modernization \
  -f operation=apply
```

Manual destroy:

```bash
gh workflow run "Medicare GCP modernization demo" \
  --repo jvnstudio/GitHub \
  --ref demo/medicare-gcp-modernization \
  -f operation=destroy
```

Follow runs:

```bash
gh run list --repo jvnstudio/GitHub
```

---

# 16. Demonstrate Cloud Audit Logs

After a Terraform apply, inspect recent administrative activity:

```bash
gcloud logging read \
  'logName:"cloudaudit.googleapis.com%2Factivity"' \
  --project="$PROJECT_ID" \
  --limit=30 \
  --freshness=1h \
  --format='table(timestamp,protoPayload.authenticationInfo.principalEmail,protoPayload.methodName,resource.type)'
```

Use this to connect the two audit layers:

```text
GitHub
  commit -> pull request -> review -> workflow -> Terraform plan

Google Cloud
  federated principal -> API call -> resource mutation -> Cloud Audit Log
```

---

# 17. Migration story to present with the demo

The live lab is the **target-state proof**. For the actual migration, use waves rather than a big-bang cutover:

| Wave | Example treatment |
|---|---|
| Discovery | Inventory VMs, dependencies, CPU/RAM, IOPS, throughput, latency, RTO/RPO |
| Low-risk VM wave | Rehost to Compute Engine |
| Stateless VM wave | Rehost/replatform into regional MIGs |
| Container-ready apps | Modernize to GKE |
| Stateful apps | Move only after state/replication design is proven |
| Mission-critical apps | Cut over after DR rehearsal proves RTO/RPO |
| Optimization | Rightsize, remove temporary hybrid dependencies, retire on-prem capacity |

For a VMware source, discuss **Migrate to Virtual Machines** as the migration service. Maintain hybrid connectivity during migration so dependent systems can be moved in controlled waves.

Performance validation must measure actual utilization rather than copying old VMware allocations directly. Capture at least:

- CPU peak/average;
- memory peak/average;
- block IOPS;
- block throughput;
- storage latency;
- network throughput/latency;
- NFS throughput;
- application concurrency;
- dependency latency.

---

# 18. How to present the `<15 minute` RTO requirement

Use this hierarchy:

```text
VM process/instance failure
  -> MIG autohealing

Zone failure
  -> regional MIG + regional GKE + zone-resilient data services

Region failure
  -> secondary region + warm capacity + replicated data + traffic failover

Data corruption/deletion
  -> backup / point-in-time recovery
```

Do **not** say that backups alone provide a sub-15-minute regional RTO.

Your production statement should be:

> "I would validate the exact RPO during discovery, pre-provision the DR network and compute, continuously replicate critical state to the secondary region, automate the failover steps, and measure the complete application recovery time through recurring DR exercises."

---

# 19. Production changes beyond the lab

The lab intentionally optimizes for a short live demonstration. A production Medicare-style environment should evaluate and typically add:

- Fabric FAST organization/landing-zone stages;
- Shared VPC and separate application/service projects;
- private VM/GKE networking;
- global external Application Load Balancer;
- Cloud Armor;
- redundant Interconnect or appropriately designed HA VPN;
- centralized Cloud DNS;
- organization policies and hierarchical firewall policies;
- least-privilege split Terraform plan/apply service accounts;
- centralized KMS/CMEK where required;
- Secret Manager;
- VPC Service Controls where applicable;
- centralized logging/security projects;
- Security Command Center;
- explicit database/block/file replication design;
- Backup and DR policies;
- formal DR runbooks, exercises, and evidence.

---

# 20. Cleanup

Delete the Kubernetes workload first (optional; Terraform will delete the cluster anyway):

```bash
kubectl delete -f ~/medicare-gcp-demo/medicare-gcp-modernization-demo/kubernetes/portal.yaml || true
```

Destroy Terraform resources:

```bash
cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo/terraform
source ../.bootstrap.env

terraform destroy \
  -var="project_id=$PROJECT_ID"
```

If the project is disposable, the simplest final cleanup is deleting the project:

```bash
gcloud projects delete "$PROJECT_ID"
```

If keeping the project, separately remove the bootstrap resources when you no longer need them:

```bash
gcloud iam workload-identity-pools providers delete github \
  --workload-identity-pool=github-actions \
  --location=global \
  --quiet

gcloud iam workload-identity-pools delete github-actions \
  --location=global \
  --quiet

gcloud iam service-accounts delete "$GCP_TF_SERVICE_ACCOUNT" --quiet
```

The Terraform state bucket is intentionally outside Terraform so the deployment cannot destroy the state it is currently using. Remove it manually only after the infrastructure is destroyed and the state is no longer required.

---

# 21. Five-minute live demo sequence

If interview time is short, use this order:

1. **Architecture:** show `docs/architecture.md` and explain zone HA versus regional DR.
2. **IaC:** show the Fabric modules in `terraform/main.tf`.
3. **VM resilience:** show three-zone MIG, delete one VM, show recreation.
4. **Container resilience:** show GKE nodes/zones, delete one Pod, show replacement.
5. **Storage:** show the Cloud Storage bucket and explain Local SSD / Filestore choices.
6. **Automation:** show GitHub WIF workflow and Terraform plan history.
7. **Audit:** show recent Cloud Audit Log events.
8. **Close:** explain that `<15 minute` regional RTO requires warm infrastructure + replication + tested failover, not just backup.

## Suggested closing statement

> "The migration strategy separates immediate capacity relief from modernization. VM workloads can first move to resilient Compute Engine patterns while suitable services move to regional GKE. State is externalized to the storage technology that matches its access and durability needs. Zone failures are handled inside the primary region, while regional disasters use pre-created secondary-region infrastructure and replicated state. Terraform and Cloud Foundation Fabric make the target environment repeatable, and GitHub Actions with Workload Identity Federation provides a keyless, reviewable, auditable deployment path."
