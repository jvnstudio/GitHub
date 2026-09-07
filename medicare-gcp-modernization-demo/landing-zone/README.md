# Medicare GCP Landing Zone — Fabric FAST v58.0.0

This directory builds the **landing-zone layer first** using Google Cloud Foundation Fabric FAST. The existing `terraform/` workload demo remains Layer 2 and should only be adapted to consume FAST-created projects/network contracts after the landing zone is working.

## Architecture sequence

```text
GCP Organization
  |
  +-- FAST Stage 0: Organization Setup
  |     +-- organization/folder hierarchy
  |     +-- organization policies and IAM
  |     +-- centralized logging foundation
  |     +-- IaC projects, state buckets, service accounts
  |     +-- GitHub Workload Identity Federation contracts
  |
  +-- FAST Stage 1: VPC Service Controls (optional / requirements-driven)
  |
  +-- FAST Stage 2: Networking
  |     +-- Shared VPC host projects
  |     +-- primary/DR networking
  |     +-- DNS/firewall/hybrid connectivity foundations
  |
  +-- FAST Stage 2: Security
  |     +-- centralized KMS / CA and security resources
  |
  +-- FAST Stage 2: Project Factory
        +-- Medicare application/service projects
        +-- Shared VPC attachment
        +-- workload service accounts / CMEK integration

Then the Medicare workload layer deploys Compute Engine MIGs, GKE, storage and DR into the governed application projects.
```

## Important prerequisite

A **real FAST landing zone requires a Google Cloud Organization**. A standalone personal GCP project cannot substitute for an organization because Stage 0 manages organization IAM, organization policies, folders, tags, projects and shared foundations.

Your existing `medicare-demo-260907-4f00` project can be reused as FAST's temporary billed **bootstrap/quota project** for the first Stage 0 apply. Once FAST creates its `iac-0` project and the generated providers/backend are migrated, the temporary project can be removed if it is no longer needed.

FAST recommends starting with an empty organization. If the organization already contains projects, IAM bindings or organization policies, treat the deployment as brownfield and import/preserve those settings before applying.

---

# Phase A — Pull the landing-zone scripts

From Cloud Shell:

```bash
cd ~/medicare-gcp-demo/medicare-gcp-modernization-demo
git pull origin demo/medicare-gcp-modernization
chmod +x landing-zone/scripts/*.sh
```

# Phase B — Discover organization and billing prerequisites

```bash
./landing-zone/scripts/01-discover-fast.sh "$PROJECT_ID"
```

The command shows:

- active gcloud identity;
- temporary bootstrap project and billing status;
- organizations visible to the identity;
- open billing accounts;
- exact `export FAST_...` commands to use.

If the command prints `BLOCKER: FAST Stage 0 requires a Google Cloud Organization`, stop. Use an account with access to a Cloud Identity / Google Workspace organization before continuing.

If exactly one organization and one billing account are shown, export the values printed by the script. Example only:

```bash
export FAST_ORG_ID="123456789012"
export FAST_ORG_DOMAIN="example.com"
export FAST_CUSTOMER_ID="C012abcde"
export FAST_BILLING_ACCOUNT="012345-ABCDEF-012345"
export FAST_ADMIN_PRINCIPAL="user:you@example.com"
export FAST_ADMIN_EMAIL="you@example.com"
export FAST_BOOTSTRAP_PROJECT="medicare-demo-260907-4f00"
```

For this demo we use the signed-in user as the initial organization-admin principal. FAST supports any principal, although a Google Group is preferred for production administration.

Optional customization:

```bash
export FAST_PREFIX="medlz"             # <= 9 chars, globally contributes to project IDs
export FAST_PRIMARY_REGION="us-east4"
export FAST_GITHUB_REPO="jvnstudio/GitHub"
```

# Phase C — Prepare pinned FAST source and Medicare configuration

```bash
./landing-zone/scripts/02-prepare-stage0.sh
source landing-zone/.fast.env
```

This script:

1. verifies the temporary bootstrap project has billing;
2. enables the APIs FAST documents for first bootstrap;
3. clones Cloud Foundation Fabric at **v58.0.0** into `landing-zone/.fabric`;
4. keeps Google's Classic FAST dataset intact;
5. generates Medicare-specific `defaults.yaml` and `cicd.yaml` outside the vendor source;
6. generates `0-org-setup.auto.tfvars` pointing FAST to those overrides;
7. configures local output persistence so generated provider/contract files are easy to inspect.

Inspect the generated configuration before doing anything to the organization:

```bash
cat landing-zone/generated/defaults.yaml
cat landing-zone/generated/cicd.yaml
cat landing-zone/.fabric/fast/stages/0-org-setup/0-org-setup.auto.tfvars
```

# Phase D — Review bootstrap IAM grants

First run in dry-run mode:

```bash
./landing-zone/scripts/03-grant-bootstrap-roles.sh
```

It prints the exact organization and billing IAM changes but makes no changes.

The initial FAST principal needs broad bootstrap authority, including organization/folder/project/policy/logging roles. This is temporary bootstrap authority; FAST then creates dedicated stage-specific read/write service accounts and generated provider files.

If you are authorized to administer this disposable/demo organization, apply the grants:

```bash
./landing-zone/scripts/03-grant-bootstrap-roles.sh --apply
```

A `PERMISSION_DENIED` here means the signed-in account is not authorized to bootstrap the organization. Do not fall back to a project-only deployment and call it a landing zone; switch to the correct organization-admin identity.

# Phase E — Plan FAST Stage 0

```bash
./landing-zone/scripts/04-stage0.sh plan
```

Do not immediately apply. Inspect the Terraform plan carefully. FAST Stage 0 is expected to manage organization/folder/project/IAM/policy/logging/IaC resources, not just resources inside the temporary project.

For an organization that already has organization policies configured, inspect them before applying:

```bash
gcloud org-policies list --organization "$FAST_ORG_ID"
```

If policies already exist that FAST also defines, follow Fabric's brownfield import procedure by adding `org_policies_imports` to the generated Stage 0 tfvars before apply.

Also inspect current organization IAM if this is not an empty org:

```bash
gcloud organizations get-iam-policy "$FAST_ORG_ID"
```

# Phase F — First Stage 0 apply

Only after the plan is understood:

```bash
./landing-zone/scripts/04-stage0.sh apply
```

The helper asks you to type `APPLY_FAST_STAGE0` before it executes the saved plan.

After completion:

```bash
./landing-zone/scripts/04-stage0.sh outputs
```

You should now have FAST-managed IaC resources and local generated files under:

```text
landing-zone/generated/outputs/
```

In particular, Stage 0 should generate provider files such as:

```text
providers/0-org-setup-providers.tf
providers/0-org-setup-ro-providers.tf
```

and contracts/tfvars consumed by later stages.

# Phase G — Migrate Stage 0 to FAST's backend and service account

FAST intentionally uses two apply cycles:

1. first apply with the bootstrap user's credentials and temporary quota project;
2. then use the newly generated provider file, migrate state to FAST's GCS backend, and re-apply while impersonating the FAST service account.

From the Stage 0 directory you can ask FAST to show the appropriate links:

```bash
source landing-zone/.fast.env
cd "$FAST_STAGE0_DIR"
../fast-links.sh "$FAST_OUTPUT_DIR"
```

The output includes the provider-file command. Because our Stage 0 tfvars is already generated in the Stage 0 directory, do not replace it with a different tfvars file.

After linking/copying the generated `0-org-setup-providers.tf`, set the newly created `iac-0` project as the gcloud quota project if needed, then migrate state:

```bash
terraform init -migrate-state
terraform apply
```

We will perform this migration together after the first Stage 0 apply so we can use the actual generated project/provider names rather than guessing them.

---

# What comes after Stage 0

Once Stage 0 is stable, proceed in this order:

```text
Stage 0  Organization Setup
  |
  +--> Stage 1 VPC-SC          (only if discovery/compliance requires it)
  |
  +--> Stage 2 Networking      (Shared VPC, primary + DR)
  |
  +--> Stage 2 Security        (central KMS / security services)
  |
  +--> Stage 2 Project Factory (Medicare prod/nonprod/DR projects)
  |
  +--> Medicare workload layer (MIG + GKE + storage + DR)
```

Do **not** deploy the existing workload Terraform into the temporary bootstrap project once the FAST application projects exist. The workload Terraform will be refactored to consume the project IDs, Shared VPC subnet links, KMS keys and other contracts generated by FAST.

## FAST design choice for this demo

We start with the **Classic FAST dataset**, not the Hardened dataset. Classic is easier to understand during a live architecture demo and remains compatible with the standard networking, security and project-factory stages. After the architecture works, security controls can be strengthened or the Hardened dataset evaluated.

## Cost and blast-radius warning

FAST Stage 0 creates multiple projects and shared resources and changes organization-level IAM/policies. Use a disposable/sandbox organization where possible. Review Terraform plans and destroy/cleanup deliberately; do not experiment against an employer or production organization without authorization.
