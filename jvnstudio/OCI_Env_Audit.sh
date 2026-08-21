#!/usr/bin/env bash
#
# oci_full_audit.sh
# ----------------------------------------------------------------------------
# Full read-only audit of an OCI tenancy: IAM, RBAC/policies, networking,
# compute, storage, database, security posture, and more.
#
# REQUIREMENTS:
#   - OCI CLI installed and configured (~/.oci/config) OR running in Cloud Shell
#   - jq installed
#   - The user/principal running this needs read (inspect) access. For a full
#     picture, an Auditor group membership (or tenancy-level read) is ideal.
#
# USAGE:
#   chmod +x oci_full_audit.sh
#   ./oci_full_audit.sh [-p PROFILE] [-c ROOT_COMPARTMENT_OCID] [-o OUTPUT_DIR]
#
#   -p PROFILE   OCI CLI config profile (default: DEFAULT)
#   -c OCID      Root compartment to start from (default: tenancy root)
#   -o DIR       Output directory (default: ./oci_audit_<timestamp>)
#   -r REGION    Override region (default: profile region; pass 'all' to loop
#                subscribed regions)
#   -h           Help
#
# OUTPUT:
#   A directory containing per-domain JSON + CSV files and a summary report.
#   Everything is READ-ONLY. No create/update/delete calls are made.
# ----------------------------------------------------------------------------

# -e is intentionally NOT set: many individual `oci` calls are expected to
# fail with permission errors on parts of the tenancy, and the script should
# keep going and just log those rather than dying.
#   -u : treat references to unset variables as an error (catches typos)
#   pipefail : a pipeline's exit status reflects ANY failing command in it,
#              not just the last one
set -uo pipefail

# ---------------------------- Defaults / Args -------------------------------
PROFILE="DEFAULT"            # OCI CLI config profile to use
ROOT_COMP=""                 # Compartment OCID to start scanning from (default: tenancy root, set later)
OUTPUT_DIR=""                # Where results get written (default: timestamped dir, set later)
REGION_OVERRIDE=""           # "" = home region only, "<region>" = one region, "all" = every subscribed region
TS="$(date -u +%Y%m%dT%H%M%SZ)"  # Current UTC timestamp, sortable format, used to name the output dir

# Print this script's own header comments as help text, then exit.
usage() { grep '^#' "$0" | sed 's/^#//'; exit 0; }

# Standard getopts CLI flag parser.
# Leading ':' in the optstring makes getopts handle missing-arg / unknown-flag
# errors itself (the ':' and '\?' cases below), instead of printing its own message.
while getopts ":p:c:o:r:h" opt; do
  case $opt in
    p) PROFILE="$OPTARG" ;;          # -p PROFILE
    c) ROOT_COMP="$OPTARG" ;;        # -c ROOT_COMPARTMENT_OCID
    o) OUTPUT_DIR="$OPTARG" ;;       # -o OUTPUT_DIR
    r) REGION_OVERRIDE="$OPTARG" ;;  # -r REGION | "all"
    h) usage ;;                      # -h : print help and exit
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

# ---------------------------- Preflight -------------------------------------
# Both binaries are hard requirements - bail immediately if either is missing.
command -v oci >/dev/null 2>&1 || { echo "ERROR: oci CLI not found."; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found."; exit 1; }

# OCI_OPTS holds the flags appended to EVERY `oci` call below.
OCI_OPTS=(--profile "$PROFILE")
# Only add --region if the user gave a specific single region (not the
# special "all" value, which is handled later by looping per-region).
[[ -n "$REGION_OVERRIDE" && "$REGION_OVERRIDE" != "all" ]] && OCI_OPTS+=(--region "$REGION_OVERRIDE")

# ---------------------------- Resolve tenancy OCID ---------------------------
# Method 1: list top-level compartments (in-subtree=false). Every compartment's
# "compartment-id" field points to its PARENT, and a top-level compartment's
# parent is the tenancy itself - so grab that field from the first result.
# "// empty" converts a missing/null value to an empty string.
# stderr is suppressed here since this is just a first attempt.
TENANCY_OCID="$(oci "${OCI_OPTS[@]}" iam compartment list --compartment-id-in-subtree false --all 2>/dev/null \
  | jq -r '.data[0]."compartment-id" // empty' 2>/dev/null)"

if [[ -z "$TENANCY_OCID" ]]; then
  # Method 2 (fallback): if the principal can't even list compartments,
  # read the tenancy OCID straight out of ~/.oci/config.
  # The region-subscription call here is a throwaway/no-op (output discarded);
  # the real work is the awk script that follows it.
  #
  # awk logic, field separator '=':
  #   - p = "[PROFILE]" e.g. "[DEFAULT]" - the config section header to find
  #   - when a line matches that header, set flag f=1 and skip to next line
  #   - if any other "[...]" header is seen, we've left the section -> f=0
  #   - while f is true and the line mentions "tenancy", strip spaces and
  #     print everything after the '='
  # head -1 takes just the first match in case of duplicates.
  TENANCY_OCID="$(oci "${OCI_OPTS[@]}" iam region-subscription list 2>/dev/null >/dev/null; \
    awk -F= -v p="[$PROFILE]" '
      $0==p{f=1;next} /^\[/{f=0} f&&/tenancy/{gsub(/ /,"");print $2}' ~/.oci/config | head -1)"
fi

# If we still don't have it, nothing downstream can work - stop here.
[[ -z "$TENANCY_OCID" ]] && { echo "ERROR: could not resolve tenancy OCID. Check profile '$PROFILE'."; exit 1; }

# If the user didn't pass -c, default the scan root to the tenancy root (scan everything).
[[ -z "$ROOT_COMP" ]] && ROOT_COMP="$TENANCY_OCID"

# ---------------------------- Output directory setup -------------------------
# If no -o was given, name the output dir using the timestamp.
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="./oci_audit_${TS}"
# Create the output dir plus all domain subfolders in one shot.
# -p = create parents as needed, don't error if they already exist.
mkdir -p "$OUTPUT_DIR"/{iam,network,compute,storage,database,security,governance,logging,raw}

SUMMARY="$OUTPUT_DIR/SUMMARY.md"   # Path to the final markdown report, written at the end

# ---------------------------- Helper functions -------------------------------

# Timestamped progress message. $* = all args joined as one string.
log()  { echo "[$(date -u +%H:%M:%S)] $*"; }

# save <subdir/name>
# Used as the right side of a pipe: <json on stdin> | save iam/users
# - Writes stdin to $OUTPUT_DIR/<subdir/name>.json
# - Re-reads that file to count items in .data[] (standard OCI CLI response shape)
# - Prints a one-line confirmation with the record count ("?" if jq/parse fails)
save() {
  local f="$OUTPUT_DIR/$1.json"
  cat > "$f"
  local n; n="$(jq '.data | length' "$f" 2>/dev/null || echo "?")"
  echo "  -> $1.json ($n records)"
}

# ocirun <oci subcommand and args...>
# Central wrapper for every "global" / tenancy-wide OCI CLI call.
# - "${OCI_OPTS[@]}" injects --profile (and possibly --region)
# - "$@" passes through whatever subcommand/args were given
# - stderr is appended to a shared error log (so permission-denied messages
#   for compartments we can't read get recorded but don't print to terminal
#   or stop the script)
# - "|| echo '{"data":[]}'" : if the command exits non-zero (e.g. 403/404),
#   substitute empty-data JSON so downstream jq calls don't choke on missing
#   or invalid JSON.
ocirun() { oci "${OCI_OPTS[@]}" "$@" 2>>"$OUTPUT_DIR/raw/errors.log" || echo '{"data":[]}'; }

log "Tenancy : $TENANCY_OCID"
log "Root cmp: $ROOT_COMP"
log "Output  : $OUTPUT_DIR"
echo

# ---------------------------- Compartment tree ------------------------------
log "Enumerating compartments (active, full subtree)..."
# --compartment-id-in-subtree true  -> recursively return every descendant compartment
# --lifecycle-state ACTIVE          -> skip deleted/deleting compartments
# --access-level ANY                -> don't restrict to only "manage"-level access
# --all                              -> auto-paginate through all result pages
ocirun iam compartment list \
  --compartment-id "$ROOT_COMP" \
  --compartment-id-in-subtree true \
  --lifecycle-state ACTIVE \
  --access-level ANY \
  --all | save iam/compartments

# Build the master list of compartment OCIDs that the rest of the script will
# iterate over.
#   - jq extracts the "id" field of every compartment object (the trailing "?"
#     guards against .data being null/empty)
#   - that's combined with ROOT_COMP itself, since the root compartment is NOT
#     included in its own subtree listing
#   - mapfile -t reads each line of the process substitution into the COMP_IDS
#     array, stripping trailing newlines
mapfile -t COMP_IDS < <(jq -r '.data[]?.id' "$OUTPUT_DIR/iam/compartments.json"; echo "$ROOT_COMP")

# Dedupe and sort:
#   - printf prints each array element on its own line
#   - sort -u sorts and removes duplicates
#   - ($(...)) re-splits the output back into an array on whitespace/newlines
COMP_IDS=($(printf '%s\n' "${COMP_IDS[@]}" | sort -u))

# ${#COMP_IDS[@]} = number of elements in the array
log "Found ${#COMP_IDS[@]} compartment(s) to scan."
echo

# ============================================================================
#  IAM / RBAC
# ============================================================================
log "=== IAM / RBAC ==="

# Users, groups, and dynamic groups are TENANCY-WIDE constructs in OCI (not
# per-compartment), so these are always queried against $TENANCY_OCID.
ocirun iam user list --compartment-id "$TENANCY_OCID" --all | save iam/users
ocirun iam group list --compartment-id "$TENANCY_OCID" --all | save iam/groups
ocirun iam dynamic-group list --compartment-id "$TENANCY_OCID" --all | save iam/dynamic_groups

# ---- Group membership mapping: build a flat "user belongs to group" list ----
log "Mapping group memberships..."
# Placeholder/defensive write - gets overwritten once the loop below finishes.
echo '{"data":[]}' > "$OUTPUT_DIR/iam/group_memberships.json"

acc='[]'   # JSON-array accumulator for membership records
# Process substitution feeds one line per group, formatted "<group-id> <group-name>",
# into the while-read loop, which splits each line into gid/gname on whitespace.
while read -r gid gname; do
  [[ -z "$gid" ]] && continue   # skip blank lines

  # List the users in this group, then reshape each into
  # {group: "<groupname>", user: "<username>", user_id: "<userocid>"},
  # wrapped in an array.
  m="$(ocirun iam group list-users --group-id "$gid" --compartment-id "$TENANCY_OCID" --all \
        | jq --arg g "$gname" '[.data[]? | {group:$g, user:.name, user_id:.id}]')"

  # Merge this group's membership array (m) into the running accumulator (acc)
  # via JSON array concatenation. -n = no input file (only --argjson vars used).
  # -c = compact (single-line) output.
  acc="$(jq -c --argjson a "$acc" --argjson b "$m" -n '$a + $b')"
done < <(jq -r '.data[]? | "\(.id) \(.name)"' "$OUTPUT_DIR/iam/groups.json")

# Wrap the final accumulated array in the standard {"data": [...]} shape and save.
echo "{\"data\":$acc}" | save iam/group_memberships

# ---- Policies: the core RBAC artifact ----
# Unlike users/groups, IAM policies are attached to SPECIFIC compartments -
# a policy in compartment X only shows up when listing policies for X.
# So loop over every compartment OCID gathered earlier.
log "Collecting IAM policies across all compartments..."
pacc='[]'
for c in "${COMP_IDS[@]}"; do
  # Reshape each returned policy object down to just the fields we care about:
  # name, id, compartment_id (renamed from the API's "compartment-id"),
  # statements (the actual policy rule text array), and description.
  p="$(ocirun iam policy list --compartment-id "$c" --all \
        | jq '[.data[]? | {name, id, compartment_id:."compartment-id", statements, description}]')"
  # Concatenate this compartment's policies into the running accumulator.
  pacc="$(jq -c --argjson a "$pacc" --argjson b "$p" -n '$a + $b')"
done
echo "{\"data\":$pacc}" | save iam/policies

# Flatten the nested structure - each policy has an ARRAY of statement strings -
# into one CSV row per individual statement.
#   - ".data[]? as $p"        : iterate over each policy, bind to $p
#   - "$p.statements[]?"      : iterate over each statement string in that policy
#   - "[$p.name, $p.compartment_id, .]" : build a 3-element row (policy name,
#                                          compartment, statement text)
#   - "@csv"                  : format that array as a properly quoted CSV row
#   - "-r"                    : raw output so the CSV text isn't jq-quoted
jq -r '.data[]? as $p | ($p.statements[]? | [$p.name, $p.compartment_id, .] | @csv)' \
  "$OUTPUT_DIR/iam/policies.json" > "$OUTPUT_DIR/iam/policy_statements.csv"

# Prepend a CSV header row. Bash can't directly prepend a line to a file, so:
#   echo header | cat - file   -> concatenates stdin (the header) then the file
#   redirect to a temp file, then mv it over the original.
echo "policy_name,compartment_id,statement" | cat - "$OUTPUT_DIR/iam/policy_statements.csv" \
  > "$OUTPUT_DIR/iam/policy_statements.tmp" && mv "$OUTPUT_DIR/iam/policy_statements.tmp" "$OUTPUT_DIR/iam/policy_statements.csv"

# Newer tenancies use "Identity Domains" (IAM v2) instead of / alongside
# classic users & groups - list them in case this tenancy uses that model.
ocirun iam domain list --compartment-id "$TENANCY_OCID" --all | save iam/identity_domains

# ---- Per-user credential / MFA audit ----
log "Auditing per-user credentials & MFA (this can take a while)..."
ucred='[]'   # accumulator: one JSON object per user
# Same while-read pattern as group memberships, but iterating over every user
# from iam/users.json.
while read -r uid uname; do
  [[ -z "$uid" ]] && continue

  # Uploaded API signing keys -> fingerprint, lifecycle state, creation time
  keys="$(ocirun iam user api-key list --user-id "$uid" | jq '[.data[]? | {fingerprint, state:."lifecycle-state", created:."time-created"}]')"
  # Auth tokens (e.g. for Object Storage Swift API) -> similarly reduced
  toks="$(ocirun iam auth-token list --user-id "$uid" | jq '[.data[]? | {id, state:."lifecycle-state", created:."time-created"}]')"
  # Registered MFA devices -> whether each is activated
  mfa="$(ocirun iam mfa-totp-device list --user-id "$uid" | jq '[.data[]? | {activated:."is-activated"}]')"
  # Full user object -> .capabilities (map of booleans: can_use_console_password,
  # can_use_api_keys, etc. - which auth methods are enabled for this user)
  caps="$(ocirun iam user get --user-id "$uid" | jq '.data.capabilities')"

  # Build one JSON object per user combining all of the above.
  # mfa_active: filter the mfa array for activated==true devices and check
  # whether that filtered array's length is > 0 - i.e. does this user have
  # at least one active MFA device.
  entry="$(jq -n --arg u "$uname" --arg id "$uid" \
            --argjson k "$keys" --argjson t "$toks" --argjson m "$mfa" --argjson c "$caps" \
            '{user:$u, user_id:$id, api_keys:$k, auth_tokens:$t, mfa_devices:$m, capabilities:$c,
              mfa_active: ([$m[]?|select(.activated==true)]|length>0)}')"

  # Append this single object (wrapped as a one-element array via [$e]) to ucred.
  ucred="$(jq -c --argjson a "$ucred" --argjson e "$entry" -n '$a + [$e]')"
done < <(jq -r '.data[]? | "\(.id) \(.name)"' "$OUTPUT_DIR/iam/users.json")
echo "{\"data\":$ucred}" | save iam/user_credentials

# Security flag: filter the just-built user-credentials list down to users
# where mfa_active is false, print just their usernames (one per line).
jq -r '.data[]? | select(.mfa_active==false) | .user' "$OUTPUT_DIR/iam/user_credentials.json" \
  > "$OUTPUT_DIR/security/users_without_mfa.txt"

echo

# ============================================================================
#  GOVERNANCE: tenancy, regions, quotas, tags, budgets
# ============================================================================
log "=== Governance ==="
# Tenancy-wide lookups:
#   - region_subscriptions: which OCI regions this tenancy is subscribed to
#     (drives the later per-region scan loop)
#   - tag_namespaces: defined cost/governance tag namespaces
#   - availability_domains: AD1/AD2/AD3-style fault domains in the home region
ocirun iam region-subscription list | save governance/region_subscriptions
ocirun iam tag-namespace list --compartment-id "$TENANCY_OCID" --all | save governance/tag_namespaces
ocirun iam availability-domain list --compartment-id "$TENANCY_OCID" | save governance/availability_domains

# Quotas are per-compartment, so loop and concatenate like the IAM policies above.
# "jq '.data // []'" defaults to an empty array if .data is null.
qacc='[]'; bacc='[]'
for c in "${COMP_IDS[@]}"; do
  q="$(ocirun limits quota list --compartment-id "$c" --all | jq '.data // []')"
  qacc="$(jq -c --argjson a "$qacc" --argjson b "$q" -n '$a + $b')"
done
echo "{\"data\":$qacc}" | save governance/quotas

# Budgets are typically tenancy-scoped, so fetch directly from the tenancy
# root in a single call (no per-compartment loop needed).
ocirun budgets budget list --compartment-id "$TENANCY_OCID" --all | save governance/budgets
echo

# ============================================================================
#  REGION LOOP: everything region-scoped
# ============================================================================
# Decide which region(s) to scan:
#   -r all       -> every subscribed region (from governance/region_subscriptions.json)
#   -r <region>  -> just that one region
#   (neither)    -> whichever region is marked is-home-region == true
if [[ "$REGION_OVERRIDE" == "all" ]]; then
  mapfile -t REGIONS < <(jq -r '.data[]?."region-name"' "$OUTPUT_DIR/governance/region_subscriptions.json")
else
  # ${VAR:-default} : if REGION_OVERRIDE is empty, fall back to querying for
  # the home region's region-name.
  REGIONS=("${REGION_OVERRIDE:-$(oci "${OCI_OPTS[@]}" iam region-subscription list \
    | jq -r '.data[] | select(."is-home-region"==true)."region-name"')}")
fi
log "Region(s) to scan: ${REGIONS[*]}"   # ${REGIONS[*]} joins all elements with spaces
echo

# scan_region <region-name>
# Runs every region-scoped lookup (networking, compute, storage, database,
# security, logging) for a single region, across all compartments in COMP_IDS.
scan_region() {
  local REGION="$1"
  local RO=(--profile "$PROFILE" --region "$REGION")

  # Region-scoped equivalent of ocirun: same error-logging/fallback behavior,
  # but pinned to $REGION (last --region flag wins, overriding any global one).
  local rrun; rrun() { oci "${RO[@]}" "$@" 2>>"$OUTPUT_DIR/raw/errors.log" || echo '{"data":[]}'; }

  # Region-scoped equivalent of save: appends ".$REGION" to the filename so
  # results from multiple regions coexist without overwriting each other,
  # e.g. network/vcns.us-ashburn-1.json
  local rsave; rsave() { local f="$OUTPUT_DIR/$1.$REGION.json"; cat > "$f"; \
    echo "  -> $1.$REGION.json ($(jq '.data|length' "$f" 2>/dev/null || echo '?'))"; }

  log "--- Region: $REGION ---"

  # ---- NETWORKING ----
  # One JSON-array accumulator per resource type, all starting empty.
  # (lpg/local-peering-gateways is declared but currently unused/unpopulated.)
  local nv='[]' sub='[]' sl='[]' nsg='[]' rt='[]' ig='[]' ng='[]' sg='[]' lpg='[]' drg='[]'
  for c in "${COMP_IDS[@]}"; do
    # VCNs
    nv="$(jq -c --argjson a "$nv" --argjson b "$(rrun network vcn list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Subnets
    sub="$(jq -c --argjson a "$sub" --argjson b "$(rrun network subnet list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Security Lists
    sl="$(jq -c --argjson a "$sl" --argjson b "$(rrun network security-list list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Network Security Groups
    nsg="$(jq -c --argjson a "$nsg" --argjson b "$(rrun network nsg list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Route Tables
    rt="$(jq -c --argjson a "$rt" --argjson b "$(rrun network route-table list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Internet Gateways
    ig="$(jq -c --argjson a "$ig" --argjson b "$(rrun network internet-gateway list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # NAT Gateways
    ng="$(jq -c --argjson a "$ng" --argjson b "$(rrun network nat-gateway list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Service Gateways
    sg="$(jq -c --argjson a "$sg" --argjson b "$(rrun network service-gateway list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Dynamic Routing Gateways
    drg="$(jq -c --argjson a "$drg" --argjson b "$(rrun network drg list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
  done
  # Wrap each accumulated array in {"data": [...]} and save with region suffix.
  echo "{\"data\":$nv}"  | rsave network/vcns
  echo "{\"data\":$sub}" | rsave network/subnets
  echo "{\"data\":$sl}"  | rsave network/security_lists
  echo "{\"data\":$nsg}" | rsave network/nsgs
  echo "{\"data\":$rt}"  | rsave network/route_tables
  echo "{\"data\":$ig}"  | rsave network/internet_gateways
  echo "{\"data\":$ng}"  | rsave network/nat_gateways
  echo "{\"data\":$sg}"  | rsave network/service_gateways
  echo "{\"data\":$drg}" | rsave network/drgs

  # ---- Security flag: ingress rules open to the entire internet ----
  # Reuse the security-lists data ($sl) just gathered. For each security list
  # ($s), iterate its ingress-security-rules, filter for source == 0.0.0.0/0,
  # and output [display-name, OCID, protocol, source] as a CSV row.
  # ">>" appends, since scan_region runs once per region and all regions'
  # results should land in the same file.
  echo "{\"data\":$sl}" | jq -r '
    .data[]? as $s | $s."ingress-security-rules"[]?
    | select(.source=="0.0.0.0/0")
    | [$s."display-name", $s.id, .protocol, (.source)] | @csv' \
    >> "$OUTPUT_DIR/security/open_ingress_0.0.0.0.csv"

  # ---- COMPUTE ----
  # Every VM instance in every compartment, for this region.
  local inst='[]'
  for c in "${COMP_IDS[@]}"; do
    inst="$(jq -c --argjson a "$inst" --argjson b "$(rrun compute instance list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
  done
  echo "{\"data\":$inst}" | rsave compute/instances

  # ---- BLOCK / OBJECT STORAGE ----
  local bv='[]' bk='[]'
  # The Object Storage namespace is a unique tenancy-wide string required for
  # all bucket operations. Extract it as a raw string, or empty if it fails.
  local ns; ns="$(rrun os ns get | jq -r '.data // empty')"
  for c in "${COMP_IDS[@]}"; do
    # Block volumes - listed unconditionally
    bv="$(jq -c --argjson a "$bv" --argjson b "$(rrun bv volume list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Object Storage buckets - only if we successfully got a namespace,
    # since bucket listing requires --namespace-name
    [[ -n "$ns" ]] && bk="$(jq -c --argjson a "$bk" --argjson b "$(rrun os bucket list --compartment-id "$c" --namespace-name "$ns" --all|jq '.data//[]')" -n '$a+$b')"
  done
  echo "{\"data\":$bv}" | rsave storage/block_volumes
  echo "{\"data\":$bk}" | rsave storage/buckets

  # ---- Security flag: publicly accessible buckets ----
  if [[ -n "$ns" ]]; then
    # Extract every bucket name from $bk, then for each (skipping blanks),
    # fetch its details and pull out "public-access-type" (default "UNKNOWN"
    # if absent). OCI's safe default is "NoPublicAccess" - anything else
    # (ObjectRead, ObjectReadWithoutList, UNKNOWN, etc.) means some form of
    # public exposure, so record it as region,bucket,access_type.
    echo "{\"data\":$bk}" | jq -r '.data[]?.name' | while read -r b; do
      [[ -z "$b" ]] && continue
      acc="$(rrun os bucket get --namespace-name "$ns" --bucket-name "$b" \
              | jq -r '.data."public-access-type" // "UNKNOWN"')"
      [[ "$acc" != "NoPublicAccess" ]] && echo "$REGION,$b,$acc" >> "$OUTPUT_DIR/security/public_buckets.csv"
    done
  fi

  # ---- DATABASE ----
  local adb='[]' dbs='[]'
  for c in "${COMP_IDS[@]}"; do
    # Autonomous Databases (e.g. APEX/ADB workloads)
    adb="$(jq -c --argjson a "$adb" --argjson b "$(rrun db autonomous-database list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
    # Traditional DB Systems (VM/BM-based, e.g. for RAC)
    dbs="$(jq -c --argjson a "$dbs" --argjson b "$(rrun db system list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
  done
  echo "{\"data\":$adb}" | rsave database/autonomous_databases
  echo "{\"data\":$dbs}" | rsave database/db_systems

  # ---- SECURITY SERVICES ----
  # KMS Vaults across all compartments - relevant for encryption-at-rest key
  # management in FedRAMP/IL5 contexts.
  local vaults='[]'
  for c in "${COMP_IDS[@]}"; do
    vaults="$(jq -c --argjson a "$vaults" --argjson b "$(rrun kms management vault list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
  done
  echo "{\"data\":$vaults}" | rsave security/vaults
  # Cloud Guard configuration is tenancy-scoped - single call, no per-compartment loop.
  rrun cloud-guard configuration get | rsave security/cloud_guard_config

  # ---- LOGGING / AUDIT ----
  # All Logging service log groups across compartments, for this region.
  local lg='[]'
  for c in "${COMP_IDS[@]}"; do
    lg="$(jq -c --argjson a "$lg" --argjson b "$(rrun logging-management log-group list --compartment-id "$c" --all|jq '.data//[]')" -n '$a+$b')"
  done
  echo "{\"data\":$lg}" | rsave logging/log_groups
}

# Run the region scan once per region in REGIONS, skipping any empty entries.
for R in "${REGIONS[@]}"; do
  [[ -z "$R" ]] && continue
  scan_region "$R"
done
echo

# ============================================================================
#  SUMMARY REPORT
# ============================================================================
log "Writing summary report..."

# count <file> : length of .data[] in a single JSON file, or 0 if missing/invalid.
count() { jq '.data | length' "$1" 2>/dev/null || echo 0; }

# multi <pattern> : sums .data[] lengths across all region-suffixed variants
# of a file, e.g. network/vcns.*.json matches network/vcns.us-ashburn-1.json,
# network/vcns.uk-london-1.json, etc.
# [[ -e "$f" ]] guards against the glob matching nothing literally (which
# would otherwise pass the literal pattern string as $f).
multi() { local n=0; for f in "$OUTPUT_DIR"/$1.*.json; do [[ -e "$f" ]] && n=$((n+$(count "$f"))); done; echo "$n"; }

# Wrapping the whole block in { ... } > "$SUMMARY" redirects every echo inside
# to the summary file at once, instead of redirecting each line individually.
{
  echo "# OCI Environment Audit"
  echo
  echo "- **Generated (UTC):** $TS"
  echo "- **Tenancy:** \`$TENANCY_OCID\`"
  echo "- **Root compartment:** \`$ROOT_COMP\`"
  echo "- **Regions scanned:** ${REGIONS[*]}"
  echo "- **Profile:** $PROFILE"
  echo
  echo "## Inventory counts"
  echo
  echo "| Domain | Resource | Count |"
  echo "|---|---|---|"
  # Single-file / tenancy-wide resources -> count()
  echo "| IAM | Compartments | $(count "$OUTPUT_DIR/iam/compartments.json") |"
  echo "| IAM | Users | $(count "$OUTPUT_DIR/iam/users.json") |"
  echo "| IAM | Groups | $(count "$OUTPUT_DIR/iam/groups.json") |"
  echo "| IAM | Dynamic Groups | $(count "$OUTPUT_DIR/iam/dynamic_groups.json") |"
  echo "| IAM | Identity Domains | $(count "$OUTPUT_DIR/iam/identity_domains.json") |"
  echo "| IAM | Policies | $(count "$OUTPUT_DIR/iam/policies.json") |"
  # Line count of policy_statements.csv minus 1 to exclude the header row.
  echo "| IAM | Policy statements | $(( $(wc -l < "$OUTPUT_DIR/iam/policy_statements.csv") - 1 )) |"
  echo "| Governance | Region subscriptions | $(count "$OUTPUT_DIR/governance/region_subscriptions.json") |"
  echo "| Governance | Tag namespaces | $(count "$OUTPUT_DIR/governance/tag_namespaces.json") |"
  echo "| Governance | Budgets | $(count "$OUTPUT_DIR/governance/budgets.json") |"
  # Region-suffixed resources -> multi()
  echo "| Network | VCNs | $(multi network/vcns) |"
  echo "| Network | Subnets | $(multi network/subnets) |"
  echo "| Network | Security Lists | $(multi network/security_lists) |"
  echo "| Network | NSGs | $(multi network/nsgs) |"
  echo "| Network | DRGs | $(multi network/drgs) |"
  echo "| Compute | Instances | $(multi compute/instances) |"
  echo "| Storage | Block Volumes | $(multi storage/block_volumes) |"
  echo "| Storage | Buckets | $(multi storage/buckets) |"
  echo "| Database | Autonomous DBs | $(multi database/autonomous_databases) |"
  echo "| Database | DB Systems | $(multi database/db_systems) |"
  echo "| Security | Vaults | $(multi security/vaults) |"
  echo "| Logging | Log Groups | $(multi logging/log_groups) |"
  echo
  echo "## Security flags (review these)"
  echo
  # wc -l on the flag files, defaulting to 0 if a file doesn't exist.
  uno="$(wc -l < "$OUTPUT_DIR/security/users_without_mfa.txt" 2>/dev/null || echo 0)"
  echo "- **Users without active MFA:** $uno  (see \`security/users_without_mfa.txt\`)"
  if [[ -f "$OUTPUT_DIR/security/public_buckets.csv" ]]; then
    echo "- **Public object-storage buckets:** $(wc -l < "$OUTPUT_DIR/security/public_buckets.csv")  (see \`security/public_buckets.csv\`)"
  else
    echo "- **Public object-storage buckets:** 0"
  fi
  if [[ -f "$OUTPUT_DIR/security/open_ingress_0.0.0.0.csv" ]]; then
    echo "- **Security-list rules open to 0.0.0.0/0:** $(wc -l < "$OUTPUT_DIR/security/open_ingress_0.0.0.0.csv")  (see \`security/open_ingress_0.0.0.0.csv\`)"
  else
    echo "- **Security-list rules open to 0.0.0.0/0:** 0"
  fi
  echo
  echo "## Notes"
  echo "- All calls are read-only. Empty results may indicate no resources OR missing read permissions."
  echo "- Permission/other errors are logged in \`raw/errors.log\`."
  echo "- For IL5/FedRAMP review, start with \`iam/policy_statements.csv\` and the security flags above."
} > "$SUMMARY"

log "DONE."
echo
echo "Review the report:  $SUMMARY"
echo "All artifacts in:   $OUTPUT_DIR/"
