# Pre-flight checks — manual instructions (source of truth)

Run `bash scripts/preflight.sh` first. It automates everything below, but if a
check fails (permissions, CLI version, ...) follow the manual steps in this
file. **These manual steps are the authoritative version** — the script only
saves you typing.

You need: Azure CLI (`az`, https://aka.ms/installazurecli) logged in to your
**Azure for Students** subscription (`az login`, then
`az account set --subscription <id>`), and the Azure portal
(https://portal.azure.com) plus the Foundry portal (https://ai.azure.com).

## 1. Which regions are you allowed to deploy to?

Azure for Students subscriptions have an Azure Policy assignment that restricts
regions. The set is **different per student subscription**.

- **Portal:** search `Subscriptions` → select your subscription → left menu
  **Policies** → **Assignments** → open the assignment named
  **"Allowed resource deployment regions"** (or "Allowed locations") → under
  **Parameters** read `listOfAllowedLocations` — that list is your allowed
  region set. If there is no such assignment, all regions are allowed.
- **CLI:**
  ```bash
  SUB=$(az account show --query id -o tsv)
  az policy assignment list --scope "/subscriptions/$SUB" -o json \
    | jq -r '.[] | . as $a
             | select((($a.properties.policyDefinitionId // $a.policyDefinitionId // "") == "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c")
                      or ((($a.properties.displayName // $a.displayName // "") | test("allowed"; "i"))))
             | ($a.name // empty)'
  # then, per assignment name (note: if SEVERAL assignments match, the effective
  # allowed set is the INTERSECTION of all their location lists):
  az policy assignment show --name <name> --scope "/subscriptions/$SUB" -o json \
    | jq -r '(.properties.parameters // .parameters // {})
             | (.listOfAllowedLocations.value // .allowedLocations.value // .listOfAllowedLocation.value // empty) | .[]?'
  ```

## 2. Which of those regions actually offer the services we need?

You need ONE region that supports all of: Flex Consumption (Functions), Container
Apps, Cognitive Services/Foundry (AIServices + project), Cosmos DB, Storage,
Event Grid, Container Registry, Monitor.

- **CLI:**
  ```bash
  az functionapp list-flexconsumption-locations --query "[].name" -o tsv   # Flex Consumption regions
  az provider show --namespace Microsoft.App --query "resourceTypes[?resourceType=='containerApps'].locations" -o tsv
  az provider show --namespace Microsoft.CognitiveServices --query "resourceTypes[?resourceType=='accounts'].locations" -o tsv
  ```
  (Provider APIs print display names, e.g. "West Europe" — convert with
  `az account list-locations --query "map(&{name:name, displayName:displayName})"`.)
- **Docs:** Flex Consumption regions and Foundry project regions:
  https://learn.microsoft.com/azure/foundry/reference/region-support

Common regions that work on many student subscriptions: `swedencentral`,
`francecentral`, `eastus2`; `westeurope` works only if your policy allows it.
If your allowed set contains no Foundry-capable region at all, open a
region-access support request (portal → Help + support) — see
https://learn.microsoft.com/answers/questions/5916405.

## 3. Do you have model quota (gpt-5-mini TPM) in that region?

Quota is per subscription + region + model. On student subscriptions the default
is often **0 TPM**, and increase requests are frequently denied.

- **CLI:**
  ```bash
  az cognitiveservices usage list --location <region> -o json \
    | jq '[.[] | select(.name.value | test("gpt-5-mini"; "i")) | {name: .name.value, used: .currentValue, limit: .limit}]'
  ```
  (Requires `Reader`/`Cognitive Services Usages Reader` on the subscription —
  you are Owner on your own student subscription.)
  Subscription quota tier:
  ```bash
  az rest --method get --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview"
  ```
- **Foundry portal (per-region model quota):** https://ai.azure.com →
  **Management center** → **Quota** → find gpt-5-mini in your candidate region.
  Alternative: **Models + endpoints** → **Deploy model** → gpt-5-mini → the
  region dropdown shows available quota per region.
- If quota is **0**: click **Request quota increase** in the Quota page (approval
  on student subscriptions is not guaranteed), **or** choose a different allowed
  region where the Quota page shows > 0 TPM (commonly `swedencentral`, `eastus2`).

## 4. Compute quota (informational)

- **Portal:** search `Quotas` → **Quotas** blade → filter by region.
- **CLI:** `az vm list-usage --location <region> -o table`

(Flex Consumption and Container Apps do not consume VM core quota, so this is
informational only.)

## 5. Pick the location and continue

Choose one region that is in your allowed list AND supports all services AND has
gpt-5-mini quota > 0. Use it as the single `location` for the whole deployment:

```bash
az deployment sub create --template-file infrastructure/main.bicep \
  --location <your-region> --parameters rgName=rg-clc3-<lastname> location=<your-region>
```

If the deployment **fails midway** (e.g. Container Apps environment creation
fails with `AKSCapacityHeavyUsage` — region capacity exhaustion):

1. **Delete the partial resource group first** — a resource group's location is
   immutable, so you cannot just change the region on a retry:
   ```bash
   az group delete --name <rgName> --yes --no-wait
   # wait until it is gone: az group show --name <rgName>  (should 404)
   ```
2. **Re-run with a fresh resource-group name AND a new deployment name** (the
   old deployment record still references the old group):
   ```bash
   az deployment sub create --template-file infrastructure/main.bicep \
     --location <next-candidate-region> --name clc3-2026-r2 \
     --parameters rgName=rg-clc3-<lastname>-r2 location=<next-candidate-region>
   ```
   Pick the next candidate region from the `preflight.sh` result table (the one
   with the most remaining gpt-5-mini GlobalStandard quota).
