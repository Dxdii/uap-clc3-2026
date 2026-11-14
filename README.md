# uap-clc3-2026 — Image analysis with Azure AI Foundry, Flex Consumption Functions and Container Apps

Hands-on exercise for the 3rd-semester master course (UAP/CLC3).

You will deploy a small serverless pipeline:

```
you ──POST image──▶ Container App (upload) ──▶ Blob Storage ('imageanalysis')
                                                          │ BlobCreated event (Event Grid)
                                                          ▼
                                        Flex Consumption Function 'AnalyzeImage'
                                        (blob input binding → Foundry SDK → gpt-4o-mini)
                                                          │
                                                          ▼ Cosmos DB output binding
                                        Cosmos DB 'ImageAnalysis' / 'results'
```

* **Upload** happens in an **Azure Container App** (FastAPI), authenticated with a managed identity.
* **Analysis** happens in an **Azure Function on the Flex Consumption plan** (Python 3.13): the uploaded
  blob is the **input binding** (blob trigger with Event Grid source), the image is sent to a
  **Microsoft Foundry** project via the **Foundry SDK** (`azure-ai-projects`), and the JSON result is
  written to **Cosmos DB** via the **output binding**.
* No keys anywhere in code — everything uses **managed identities (Entra ID)**.

---

## 0. Requirements

* VS Code + Docker
* An **Azure for Students** subscription (https://azure.microsoft.com/free/students)
* GitHub account, curl or Postman
* Azure CLI (`az`) and `jq` locally, or just use the devcontainer (step 2)

## 1. Fork and clone

1. Fork this repository on GitHub (button *Fork*), then clone **your** fork:
   ```bash
   git clone https://github.com/<your-github-user>/uap-clc3-2026.git
   cd uap-clc3-2026
   ```

## 2. Open in the dev container

1. Make sure Docker is running.
2. In VS Code: command palette → **Dev Containers: Reopen in Container**.
   The container has Python 3.13, Azure CLI, Azure Functions Core Tools, Bicep and jq preinstalled.

## 3. Step 0 — pre-flight checks (mandatory, do this first)

Your student subscription restricts **which regions** you may deploy to, and model **quota** differs
per region. Discover both before deploying anything:

```bash
az login                                  # browser/device-code login
az account set --subscription <id>        # select your Azure for Students subscription
bash scripts/preflight.sh                 # prints candidate regions + gpt-4o-mini quota + RECOMMENDED LOCATION
```

If the script cannot run a check automatically, it prints the manual step — the authoritative manual
instructions are in [`scripts/README.md`](scripts/README.md):

1. **Allowed regions:** portal → Subscriptions → your subscription → **Policies** → **Assignments** →
   *Allowed resource deployment regions* → read `listOfAllowedLocations`.
2. **Service regions:** `az functionapp list-flexconsumption-locations`, `az provider show ...` (see script).
3. **Model quota (gpt-4o-mini TPM):** Foundry portal https://ai.azure.com → **Management center** → **Quota**,
   or CLI `az cognitiveservices usage list --location <region>`. If quota is **0 TPM**: request an increase
   (approval on student subscriptions is *not* guaranteed) or pick another allowed region
   (commonly `swedencentral`, `francecentral`, `eastus2`).

> Keep the **`RECOMMENDED LOCATION`** from the script — you need it in step 4.
> If Container Apps environment creation later fails with `AKSCapacityHeavyUsage`, re-run the deployment
> in the next candidate region from the script output.

### Set a budget alert (free) — before deploying anything

```bash
az consumption budget create \
  --budget-name clc3-budget --amount 40 --time-grain Monthly \
  --start-date $(date +%Y-%m-01) \
  --notifications '{"Alert80":{"enabled":true,"operator":"GreaterThan","threshold":80,"contactEmails":["<your-student-email>"]}}'
```

### Accept the Responsible AI terms (once per subscription)

Same as in previous semesters: create any Cognitive Services resource once in the portal
(portal.azure.com → Create a resource → Cognitive Services → check *Responsible AI terms* → create →
then delete the resource group again), **or** in your subscription: Access control (IAM) → add
*Cognitive Services Contributor* for your user, then create+delete a throwaway Cognitive Services
resource in **West Europe** and tick the Responsible AI checkbox. Without this, the Foundry resource
cannot be created.

## 4. Deploy the infrastructure

```bash
cd infrastructure
az deployment sub create \
  --name clc3-2026 \
  --location <RECOMMENDED LOCATION from step 3> \
  --template-file main.bicep \
  --parameters rgName=rg-clc3-<your-lastname> location=<RECOMMENDED LOCATION from step 3>
```

* Use your **lastname** in the resource group name to avoid collisions with other students.
* If the deployment fails on **role assignments** (AAD propagation delay), simply **re-run the exact same
  command**.
* If the deployment fails **midway** (e.g. `AKSCapacityHeavyUsage`): a resource group's location is
  immutable — first `az group delete --name <rgName> --yes`, then re-run with a **fresh rgName and a new
  deployment name** (`--name clc3-2026-r2`) in the next candidate region from `scripts/preflight.sh`.
* The deployment prints outputs at the end: `functionAppName`, `uploadAppFqdn`, `foundryProjectEndpoint`,
  `cosmosAccountEndpoint`, `acrLoginServer`, ... Save them. The upload token is a **secure** output —
  fetch it explicitly (step 7 shows how).

What gets created (all in one resource group, one region): Log Analytics + App Insights, a GPv2 storage
account with the `imageanalysis` container and an Event Grid system topic, a **Foundry resource
(AIServices) with project `clc3-project` and a `gpt-4o-mini` deployment**, a **serverless Cosmos DB**
(database `ImageAnalysis`, container `results`, partition key `/filename`), a **Flex Consumption
function app** (`func-...`), a **Container Apps environment + ACR + upload app** (placeholder image
listening on 8080), and all RBAC role assignments. The Event Grid **subscription** to the function is
created in step 5 (after the code is published — the webhook endpoint is validated against the function).

## 5. Deploy the function (Flex Consumption — Python)

```bash
cd src/image-analysis-function
pip install -r requirements.txt          # local build inputs
func azure functionapp publish <functionAppName from step 4 outputs> --build local
```

Flex Consumption has **no remote build**, hence `--build local`. Then check the portal: resource group →
function app → **Functions** → you should see `AnalyzeImage` (trigger: Blob, enabled).

**Create the Event Grid subscription (after the code is published!)** — the blob trigger uses the
Event Grid source, and its endpoint is the *blob extension webhook*, validated against the published
function, so this must happen after `func ... publish` (the CI workflow does it automatically):

```bash
SUB=$(az account show --query id -o tsv)
RG=rg-clc3-<your-lastname>
APP=<functionAppName>
ST=<storageAccountName from step 4 outputs>
BLOBS_KEY=$(az rest --method POST \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/host/default/listkeys?api-version=2024-11-01" \
  --query systemKeys.blobs_extension -o tsv)
az eventgrid event-subscription create \
  --source-resource-id "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ST" \
  --name "sub-$APP-AnalyzeImage" \
  --endpoint-type webhook \
  --endpoint "https://$APP.azurewebsites.net/runtime/webhooks/blobs?functionName=Host.Functions.AnalyzeImage&code=$BLOBS_KEY" \
  --included-event-types Microsoft.Storage.BlobCreated \
  --subject-begins-with "/blobServices/default/containers/imageanalysis/blobs/"
```

## 6. Deploy the upload Container App

Build the image into your ACR and update the app:

```bash
az acr build --registry <acrName from step 4> --image upload-app:latest --file src/upload-app/Dockerfile src/upload-app
az containerapp update --name <containerAppName> --resource-group rg-clc3-<your-lastname> \
  --image <acrLoginServer>/upload-app:latest
```

(The CI workflow tags the image with the commit SHA **and** `latest`; `latest` is what infra redeploys
reuse, so re-running the infra deployment does not reset the app to the placeholder image.)

## 7. Test end-to-end

The upload endpoint is protected by a shared token (the app has public ingress, so anonymous uploads
would trigger billable AI calls). Get your token from the deployment outputs and upload:

```bash
TOKEN=$(az deployment sub show --name clc3-2026 \
  --query "properties.outputs.uploadToken.value" -o tsv)
curl -H "X-Upload-Token: $TOKEN" -F "file=@test.jpeg" https://<uploadAppFqdn>/upload
```

(or use the HTML form at `https://<uploadAppFqdn>/` — it asks for the token — or Postman.
Uploads are limited to 10 MB; larger files get a `413`.)

Then verify:

1. **Storage:** portal → storage account → Containers → `imageanalysis` → your file is there.
2. **Function ran:** portal → function app → **Monitor** (or App Insights → Transactions/Logs) →
   you should see an `AnalyzeImage` execution within seconds (Event Grid delivery).
3. **Cosmos DB:** portal → Cosmos DB account → Data Explorer → `ImageAnalysis` → `results` →
   a document with `id`/`filename` = your image name and the `analysis` JSON from the model.

## 8. CI/CD (optional but recommended)

The workflows in `.github/workflows/` deploy infra, function and container app on push to `main`.
Set these in your fork (Settings → Secrets and variables → Actions):

* Secret `AZURE_CREDENTIALS` — service principal JSON. The infra template creates RBAC role
  assignments, so the SP needs **both** `Contributor` and `Role Based Access Control Administrator`
  at subscription scope (plain Contributor fails with AuthorizationFailed on the role assignments):
  ```bash
  az ad sp create-for-rbac --name clc3-2026-deployer \
    --role Contributor --role "Role Based Access Control Administrator" \
    --scopes /subscriptions/<your-sub-id> --sdk-auth
  ```
  (Even better: replace it with OIDC federation, see the comment in the workflow file.)
* Variables: `RESOURCE_GROUP`, `LOCATION`, `DEPLOYMENT_NAME`, `FUNCTION_APP_NAME`, `STORAGE_ACCOUNT_NAME`,
  `IMAGE_CONTAINER_NAME`, `ACR_NAME`, `CONTAINER_APP_NAME` (values from the infra deployment outputs).

## 9. Expected costs (Azure for Students credit: ~USD 80–100)

| Component | Cost driver | Expected |
|---|---|---|
| ACR (Basic) | **$0.17/day** — the only fixed cost | ~$2.50 for 2 weeks, ~$5/month |
| Container App | free grant (180k vCPU-s, 360k GiB-s, 2M requests/month); scales to zero | ≈ $0 |
| Flex Consumption function | free grant (250k executions + 100k GB-s/month) | ≈ $0 |
| gpt-4o-mini | $0.15/1M input + $0.60/1M output tokens | ≈ **$0.001 per image** |
| Cosmos DB (serverless) | $0.25 per million RUs | ≈ $0 |
| Storage / Event Grid / logs | pennies; first 100k events + 5 GB logs free | ≈ $0 |

**Total: ≈ $3 if you delete the resource group after the exercise; ≈ $20–25 worst case if you leave it
running all semester** — well below your credit. The budget alert from step 3 emails you at 80%.

## 10. Troubleshooting

* **Function never triggers** → check the Event Grid subscription: storage account → Events →
  the system topic must have a subscription named `sub-<funcapp>-AnalyzeImage` with
  `Microsoft.Storage.BlobCreated` filtered to the `imageanalysis` container and a **webhook** endpoint
  `/runtime/webhooks/blobs?functionName=Host.Functions.AnalyzeImage&code=<blobs_extension key>`
  (re-create it with the command in step 5 if missing). On Flex Consumption the blob trigger *requires*
  the Event Grid source (polling is not supported).
* **401 from /upload** → you forgot the `X-Upload-Token` header (see step 7).
* **`AKSCapacityHeavyUsage` when deploying** → the region is out of Container Apps capacity; delete the
  partial resource group, then re-run `az deployment sub create` with a fresh rgName/deployment name in
  the next candidate region from `scripts/preflight.sh`.
* **Model deployment fails / quota 0 TPM** → see step 3; request quota increase or switch region/model
  (`modelName`/`modelVersion` params in `infrastructure/main.bicep`).
* **Role assignment errors right after deployment** → re-run the deployment (AAD propagation delay).
* **Re-deploying after deleting the resource group** → Cognitive Services accounts are soft-deleted;
  purge them first: portal → Cognitive Services → *Manage deleted resources* → **Purge**.
* **403 from the function on Cosmos/Storage/Foundry** → the managed identity role assignments
  (RBAC module) may not have propagated yet; wait a minute and retry.

## 11. Cleanup (do this when you are done!)

```bash
az group delete --name rg-clc3-<your-lastname> --yes --no-wait
```

This removes everything including the ACR (the only daily-rated resource). Remember to purge
soft-deleted Cognitive Services accounts afterwards (see troubleshooting) if you want to re-use the names.

## 12. Repo layout

```
├── docs/implementation-plan.md    detailed design + research + cost validation
├── scripts/preflight.sh           Step 0: allowed regions + quotas (see scripts/README.md)
├── infrastructure/main.bicep      subscription-scope deployment + modules/
├── src/upload-app/                Container App (FastAPI) — image upload
├── src/image-analysis-function/   Flex Consumption function (blob trigger → Foundry SDK → Cosmos output)
└── .github/workflows/             infra-deploy / function-deploy / containerapp-deploy
```
