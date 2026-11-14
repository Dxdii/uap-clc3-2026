#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Step 0 of the uap-clc3-2026 exercise.
#
# Checks, for the CURRENT Azure subscription:
#   1. which regions the subscription is ALLOWED to deploy to (Azure Policy
#      "Allowed resource deployment regions" / "Allowed locations")
#   2. which regions actually offer the services we need (Flex Consumption,
#      Container Apps, Cognitive Services/Foundry, Cosmos DB, Storage, ...)
#   3. the gpt-4o-mini quota (TPM) per candidate region
#   4. compute quota per candidate region (informational)
#
# Output: a table of candidate regions and a final RECOMMENDED LOCATION line.
#
# The script is DEFENSIVE on purpose: if a check cannot run (missing role,
# CLI too old, ...), it prints the equivalent MANUAL step (see
# scripts/README.md) and continues. It never hard-fails.
#
# Requirements: Azure CLI (az), jq. Run inside the devcontainer or any shell
# with both installed:   bash scripts/preflight.sh
# =============================================================================
set -uo pipefail

MODEL_FAMILY="gpt-4o-mini"          # model we deploy in the Foundry project
POLICY_DEF_ID="/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
# regions we probe for model quota first (EU first, then common student regions)
QUOTA_PROBE_ORDER="swedencentral francecentral westeurope northeurope germanywestcentral uksouth eastus2 eastus australiaeast westus westus3"

info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
manual(){ printf '\033[1;35m[MANUAL]\033[0m %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "required command '$1' not found"; return 1; }
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- 0. login / subscription -------------------------------------------------
info "Step 0: checking Azure CLI login ..."
if ! require_cmd az || ! require_cmd jq; then
  err "Install Azure CLI (https://aka.ms/installazurecli) and jq first."
  exit 1
fi
if ! az account show >/dev/null 2>&1; then
  warn "not logged in — running 'az login' (follow the browser/device-code instructions)"
  az login || { err "az login failed"; exit 1; }
fi
SUB="$(az account show --query id -o tsv)"
SUBNAME="$(az account show --query name -o tsv)"
info "subscription: $SUBNAME ($SUB)"

# display-name -> region-name map (provider APIs return display names)
az account list-locations --query "[].{name: name, displayName: displayName}" -o json > "$TMPD/locations.json" 2>/dev/null \
  || az account list-locations -o json > "$TMPD/locations.json"

# --- 1. allowed regions from Azure Policy ------------------------------------
info "Step 1: reading 'Allowed resource deployment regions' policy assignment ..."
ALLOWED="$TMPD/allowed.txt"; : > "$ALLOWED"
if az policy assignment list --scope "/subscriptions/$SUB" -o json > "$TMPD/assignments.json" 2>"$TMPD/assignments.err"; then
  jq -r --arg def "$POLICY_DEF_ID" '
    .[] | select(.properties.policyDefinitionId == $def
                 or (.properties.displayName | test("allowed (resource deployment )?regions|allowed locations"; "i")))
       | .name' "$TMPD/assignments.json" > "$TMPD/assignment_names.txt" 2>/dev/null || true
  while read -r aname; do
    [ -z "$aname" ] && continue
    az policy assignment show --name "$aname" --scope "/subscriptions/$SUB" -o json 2>/dev/null \
      | jq -r '.properties.parameters
                 | (.listOfAllowedLocations.value // .allowedLocations.value // .listOfAllowedLocation.value // empty)
                 | .[]?' \
      >> "$ALLOWED" || true
  done < "$TMPD/assignment_names.txt"
else
  warn "could not list policy assignments: $(head -c 200 "$TMPD/assignments.err")"
  manual "Allowed regions: portal -> Subscriptions -> your subscription -> Policies -> Assignments -> open 'Allowed resource deployment regions' -> read the listOfAllowedLocations parameter. See scripts/README.md section 1."
fi
if [ -s "$ALLOWED" ]; then
  sort -u "$ALLOWED" > "$TMPD/allowed_sorted.txt"; mv "$TMPD/allowed_sorted.txt" "$ALLOWED"
  info "allowed regions (policy): $(paste -sd, "$ALLOWED")"
else
  warn "no allowed-regions policy assignment found at subscription scope -> ALL regions are allowed for this subscription."
  jq -r '.[].name' "$TMPD/locations.json" > "$ALLOWED"
fi

# --- 2. service availability per region --------------------------------------
info "Step 2: collecting service region availability ..."
provider_locations() { # $1 namespace, $2 resourceType -> region names
  az provider show --namespace "$1" -o json 2>/dev/null \
    | jq -r --slurpfile loc "$TMPD/locations.json" --arg rt "$2" '
        ($loc[0] | map({(.displayName): .name}) | add // {}) as $m
        | .resourceTypes[] | select(.resourceType == $rt) | .locations[] | $m[.] // empty' \
    2>/dev/null || true
}
flex_locations() {
  az functionapp list-flexconsumption-locations --query "[].name" -o json 2>/dev/null \
    | jq -r '.[]?' || true
}
{ provider_locations Microsoft.App containerApps
  provider_locations Microsoft.Web sites
  provider_locations Microsoft.CognitiveServices accounts
  provider_locations Microsoft.DocumentDB databaseAccounts
  provider_locations Microsoft.Storage storageAccounts
  provider_locations Microsoft.EventGrid systemTopics
  provider_locations Microsoft.ContainerRegistry registries
  provider_locations Microsoft.OperationalInsights workspaces
  flex_locations
} | sort -u > "$TMPD/service_regions_raw.txt"

# per-service files (for the intersection we use the union of required services)
provider_locations Microsoft.App containerApps | sort -u > "$TMPD/r_aca.txt"
flex_locations | sort -u > "$TMPD/r_flex.txt"
provider_locations Microsoft.CognitiveServices accounts | sort -u > "$TMPD/r_ai.txt"
{ provider_locations Microsoft.Web sites
  provider_locations Microsoft.DocumentDB databaseAccounts
  provider_locations Microsoft.Storage storageAccounts
  provider_locations Microsoft.EventGrid systemTopics
  provider_locations Microsoft.ContainerRegistry registries
  provider_locations Microsoft.OperationalInsights workspaces
} | sort -u > "$TMPD/r_other.txt"

if [ ! -s "$TMPD/r_aca.txt" ] || [ ! -s "$TMPD/r_flex.txt" ] || [ ! -s "$TMPD/r_ai.txt" ]; then
  warn "could not query provider region lists (az provider show) — falling back to the allowed-region list as candidates."
  manual "Service regions: compare your allowed regions with https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan (Flex regions), the Container Apps region list, and the Foundry projects region list https://learn.microsoft.com/azure/foundry/reference/region-support. See scripts/README.md section 2."
  cp "$ALLOWED" "$TMPD/r_flex.txt"; cp "$ALLOWED" "$TMPD/r_aca.txt"; cp "$ALLOWED" "$TMPD/r_ai.txt"; cp "$ALLOWED" "$TMPD/r_other.txt"
fi

# intersection: allowed AND flex AND aca AND ai AND other
jq -n --rawfile a "$ALLOWED" --rawfile f "$TMPD/r_flex.txt" --rawfile c "$TMPD/r_aca.txt" \
      --rawfile i "$TMPD/r_ai.txt" --rawfile o "$TMPD/r_other.txt" \
  'def arr($s): $s | split("\n") | map(select(length > 0));
   arr($a) as $A | arr($f) as $F | arr($c) as $C | arr($i) as $I | arr($o) as $O
   | [$A[] | select(. as $x | $F | index($x)) | select(. as $x | $C | index($x))
        | select(. as $x | $I | index($x)) | select(. as $x | $O | index($x))]' \
  > "$TMPD/candidates.json"
CANDIDATES="$(jq -r '.[]' "$TMPD/candidates.json" 2>/dev/null | paste -sd' ' -)"
if [ -z "${CANDIDATES// }" ]; then
  err "intersection of allowed + service regions is EMPTY."
  manual "No common region. Check scripts/README.md section 2: either request region access (support request) or re-check your allowed-regions policy."
  exit 2
fi
info "candidate regions (allowed ∩ Flex ∩ ContainerApps ∩ AI ∩ core services): $CANDIDATES"

# --- 3. model quota (TPM) per candidate region --------------------------------
info "Step 3: probing $MODEL_FAMILY quota (TPM) in candidate regions (this can take a minute) ..."
: > "$TMPD/quota.tsv"
# probe EU/common regions first, then the rest of the candidates
CAND_SPACE="$(jq -r '.[]' "$TMPD/candidates.json" | tr '\n' ' ')"
PROBE="$(for r in $QUOTA_PROBE_ORDER; do echo "$r"; done; jq -r '.[]' "$TMPD/candidates.json")"
PROBE="$(echo "$PROBE" | awk '!seen[$0]++' | tr '\n' ' ')"
for region in $PROBE; do
  case " $CAND_SPACE " in *" $region "*) ;; *) continue;; esac
  usage="$(az cognitiveservices usage list --location "$region" -o json 2>"$TMPD/usage.err")" || {
    warn "az cognitiveservices usage list failed for $region: $(head -c 150 "$TMPD/usage.err")"
    manual "Model quota for $region: portal -> Quotas, or Foundry portal https://ai.azure.com -> Management center -> Quota. CLI: az cognitiveservices usage list --location $region. See scripts/README.md section 3."
    printf '%s\tUNKNOWN\n' "$region" >> "$TMPD/quota.tsv"; continue
  }
  limit="$(jq -r --arg m "$MODEL_FAMILY" '
      ([.[] | select(.name.value | test($m; "i"))]) as $all
      | (([$all[] | select(.name.value == ("OpenAI.GlobalStandard." + $m))] | first) // $all[0] | .limit // "n/a")' <<<"$usage" 2>/dev/null)"
  printf '%s\t%s\n' "$region" "${limit:-n/a}" >> "$TMPD/quota.tsv"
done

info "subscription quota tier:"
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview" -o json 2>/dev/null \
  | jq -r '.value[0].properties.currentTierName // "unknown"' 2>/dev/null \
  || manual "Quota tier: Foundry portal -> Management center -> Quota. See scripts/README.md section 3."

# --- 4. compute quota (informational) -----------------------------------------
info "Step 4: compute quota for the first candidate region (informational) ..."
FIRST="$(head -1 "$TMPD/quota.tsv" | cut -f1)"
az vm list-usage --location "$FIRST" -o table 2>/dev/null | head -20 \
  || manual "Compute quota: portal -> search 'Quotas' -> pick region $FIRST. CLI: az vm list-usage --location $FIRST."

# --- 5. verdict ---------------------------------------------------------------
info "================= PRE-FLIGHT RESULT ================="
printf '%-22s %s\n' "REGION" "gpt-4o-mini GlobalStandard quota limit (K TPM)"
while IFS=$'\t' read -r r l; do printf '%-22s %s\n' "$r" "$l"; done < "$TMPD/quota.tsv"

RECOMMENDED="$(awk -F'\t' '$2 ~ /^[0-9]+(\.[0-9]+)?$/ && $2+0 > 0 {print $1; exit}' "$TMPD/quota.tsv")"
if [ -z "$RECOMMENDED" ]; then
  # fall back to first candidate with numeric-but-zero or unknown, else first candidate
  RECOMMENDED="$(awk -F'\t' 'NR==1{print $1}' "$TMPD/quota.tsv")"
  warn "no candidate region shows $MODEL_FAMILY quota > 0."
  manual "Request a quota increase (Foundry portal -> Management center -> Quota -> Request increase; on Azure for Students approval is NOT guaranteed) or pick a region where the Quota page shows > 0 TPM. See scripts/README.md section 3."
fi
printf '\nRECOMMENDED LOCATION: %s\n' "$RECOMMENDED"
info "Use this value as the 'location' parameter of: az deployment sub create --template-file infrastructure/main.bicep --location $RECOMMENDED --parameters location=$RECOMMENDED"
info "If Container Apps environment creation fails with AKSCapacityHeavyUsage, re-run with the next region from the table above."
info "======================================================="
