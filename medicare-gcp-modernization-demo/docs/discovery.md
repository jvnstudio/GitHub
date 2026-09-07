# Discovery Questions and Working Assumptions

These are the questions I would use before finalizing the production architecture. The answers below are **demo assumptions**, not facts about an actual Medicare environment.

| Discovery question | Demo assumption | Why it matters |
|---|---|---|
| Which applications are mission-critical? | Member portal and eligibility-facing services | Determines warm DR scope and recovery priority |
| Does the `<15 minute` RTO apply to a zone failure, region failure, or both? | Both | Forces a secondary-region design rather than only multi-zone HA |
| What is the RPO for critical state? | `<5 minutes` working assumption | Drives database/block replication design |
| Which VM applications are stateless? | Web/application tiers are mostly stateless | Good candidates for regional MIGs |
| Which applications can be containerized? | Newer stateless services | Drives GKE migration wave |
| Does local disk contain authoritative data? | No; local storage is scratch/cache only | Makes Local SSD safe for selected workloads |
| Which workloads require NFS/SMB/shared file access? | A subset of legacy apps require NFS | Drives Filestore sizing/tier and DR discussion |
| Must shared file storage also recover in `<15 minutes`? | Not assumed; must be confirmed | Storage RTO/RPO can materially change cost/design |
| What hypervisor is used today? | VMware vSphere | Supports a Migrate to Virtual Machines discovery path |
| What are peak CPU and memory utilization values? | Unknown | Must be measured to right-size GCE/GKE |
| What disk IOPS, throughput, and latency are required? | Unknown | Determines Hyperdisk/Persistent Disk/Filestore selection |
| How much east-west traffic exists between applications? | Significant dependencies remain during migration | Requires dependency mapping and migration waves |
| How long will on-prem dependencies remain? | Months during transition | Requires hybrid connectivity |
| What connectivity exists today? | No production GCP link yet | Start demo with VPN; production evaluates redundant Interconnect |
| Is the portal internet-facing? | Yes | Global load balancing, TLS, WAF/Cloud Armor become relevant |
| What data residency constraints apply? | US only working assumption | Constrains region/object-storage placement |
| Does the environment contain PII/PHI? | Assume potentially yes | Requires security/compliance discovery and stronger controls |
| Is a specific federal authorization boundary required? | Unknown | Do not claim compliance until boundary/control requirements are known |
| Which identity provider is authoritative? | Enterprise IdP + Google Cloud IAM federation | Determines workforce access model |
| What CI/CD platform exists? | GitHub | Drives GitHub Actions + WIF recommendation |
| Are long-lived service-account keys allowed? | No | WIF/OIDC is the preferred CI identity pattern |
| Is deployment approval required? | Yes | Pull request review plus explicit apply |
| What audit retention is required? | Unknown | Drives centralized logging retention/export |
| Are maintenance windows defined? | Yes, but exact windows unknown | Impacts GKE upgrades and VM migration sequencing |
| How frequently must DR be exercised? | Quarterly working assumption | Drives automated recovery testing/runbooks |
| What is the acceptable failback window? | Longer than failover window | Allows controlled synchronization before primary restoration |

## Migration classification questions

For each application, collect at minimum:

- business owner and technical owner;
- criticality tier;
- RTO and RPO;
- CPU/memory peak and average;
- block storage capacity, IOPS, throughput, and latency;
- local/scratch disk requirements;
- shared filesystem protocol and throughput;
- object storage volume/access pattern;
- inbound/outbound dependencies;
- database type and replication behavior;
- operating system/version;
- licensing constraints;
- maintenance window;
- candidate strategy: retain, retire, rehost, replatform, refactor, replace.

## Recommendation logic

### Keep as VM initially when

- the application depends heavily on the OS/runtime;
- commercial software certification requires a VM;
- modernization risk is higher than rehosting risk;
- the application needs a rapid capacity-relief move first.

### Move to GKE when

- the application is already containerized or straightforward to containerize;
- horizontal scaling is useful;
- state is externalized;
- deployment velocity/portability justifies Kubernetes operational overhead.

### Use Local SSD when

- data is disposable or reconstructable;
- latency/IOPS are more important than persistence;
- loss of the VM/local disk does not cause business data loss.

### Use network file storage when

- multiple VMs/Pods need POSIX-style shared file access;
- changing the application to object storage is not immediately practical.

### Use Cloud Storage when

- data is object-oriented rather than block/file mounted;
- extremely high durability and geographic storage choices are desired;
- applications can use object APIs or a supported object-FUSE pattern.
