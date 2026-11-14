# Practical Exam — 3-Phase Deployment Plan (uap-clc3-2026)

**Format:** ~3 hours, individual work. Students deploy the reference architecture step by step in
their own Azure for Students subscription and own private fork, practicing the lecture concepts.

**Diagrams:** [architecture](diagrams/architecture.mermaid) ·
[infrastructure/Bicep](diagrams/infrastructure.mermaid) ·
[CI/CD](diagrams/cicd.mermaid) · [observability](diagrams/observability.mermaid)

## Concepts covered (exam objectives → phase)

| # | Concept | Phase |
|---|---|---|
| 1 | Deployment methods in Azure (Portal / CLI / Bicep / CI) | 1, 2, 3 |
| 2 | IaC with Bicep — structure, params, modules, dynamic values, resource chaining | 1 |
| 3 | Core Azure services configured via the Azure Portal | 1, 3 |
| 4 | CI/CD — getting code into Azure services | 2 |
| 5 | Azure Foundry — models, versions, inputs/outputs, usage | 2, 3 |
| 6 | Observability — logs, errors, service communication, metrics | 3 |

## Ground rules

1. Fork stays **private** (the `AZURE_CLI_TOKENS` secret carries your subscription credentials).
2. Run `scripts/preflight.sh` first; use its `RECOMMENDED LOCATION` everywhere (single region).
3. Set a budget alert before deploying (Phase 1, step 5).
4. Phases build on each other — do them in order.
5. Cleanup is mandatory at the end (Phase 3, last step).
6. Pitfalls with fixes: `docs/validation.md` (E1–E12, C1–C3).

---

# Phase 1 — Foundation: IaC (Bicep) + Portal exploration (~60 min)

**Concepts:** 1, 2, 3. **Deliverable:** infrastructure deployed once via Bicep/CLI; every resource opened and understood in the Portal.

## Exact steps

1. **Fork & clone** (README step 1): fork `juergenbr/uap-clc3-2026` on GitHub (keep it **private**), clone it, `cd uap-clc3-2026`.
2. **Dev container** (README step 2): VS Code → command palette → *Dev Containers: Reopen in Container* (Docker must run). The image has Python 3.13, az CLI, Functions Core Tools, Bicep, jq, gh.
3. **Logins:**
   ```bash
   az login                                   # browser/device-code
   az account set --subscription <your-student-sub-id>
   gh auth login                              # once; needed by preflight step 6
   ```
4. **Preflight** (README step 3):
   ```bash
   bash scripts/preflight.sh                  # region policy + service availability + gpt-5-mini quota
   ```
   Note the printed `RECOMMENDED LOCATION` (call it `$LOC`) and the candidate-region list. If a check can't run automatically, the script prints the manual step (authoritative: `scripts/README.md`): Portal → Subscriptions → *Policies* → *Allowed resource deployment regions*; `az functionapp list-flexconsumption-locations`; quota via ai.azure.com → Management center → Quota or `az cognitiveservices usage list --location $LOC`.
5. **Budget alert (free):**
   ```bash
   az consumption budget create --budget-name clc3-budget --amount 40 --time-grain Monthly \
     --start-date $(date +%Y-%m-01) \
     --notifications '{"Alert80":{"enabled":true,"operator":"GreaterThan","threshold":80,"contactEmails":["<you@students.fhooe.at>"]}}'
   ```
6. **Responsible AI terms** (once per subscription): Portal → Create a resource → *Cognitive Services* → tick *Responsible AI terms* → create in West Europe → delete the RG again (README step 3). Without this the Foundry resource fails.
7. **Read the IaC before deploying** (15 min): open `infrastructure/main.bicep` and skim `infrastructure/modules/*.bicep`. Identify: params (`rgName`, `location`, `uploadToken`, model params), `var nameSuffix = take(uniqueString(subscription().subscriptionId, rgName), 16)`, the module blocks, module outputs feeding other modules' params, `dependsOn`. See [infrastructure diagram](diagrams/infrastructure.mermaid).
8. **Deploy via CLI + Bicep** (README step 4). From the repo root:
   ```bash
   UPLOAD_TOKEN=$(openssl rand -hex 16); echo "SAVE THIS upload token: $UPLOAD_TOKEN"
   az deployment sub create --name clc3-2026 --location $LOC \
     --template-file infrastructure/main.bicep \
     --parameters rgName=rg-clc3-<your-lastname> location=$LOC uploadToken=$UPLOAD_TOKEN
   ```
   If it fails on **role assignments** (AAD propagation), re-run the identical command. If it fails midway (e.g. `AKSCapacityHeavyUsage`): `az group delete --name <rg> --yes`, then re-run with a fresh rgName, new deployment name, and the next candidate region from preflight. **Save the printed outputs** (`functionAppName`, `uploadAppFqdn`, `acrName`, `acrLoginServer`, `containerAppName`, `storageAccountName`, `cosmosAccountEndpoint`, `foundryProjectEndpoint`, …).
9. **Watch the deployment in the Portal**: subscription → **Deployments** → `clc3-2026` → operations/resources/outputs. (This is a *deployment method* observation: same ARM engine as Portal/CLI.)
10. **Explore every resource in the Portal** (RG → Overview → click each):
    - Storage `st*`: Data storage → Containers → `imageanalysis`; note Event Grid **system topic** `systopic-*`; Access control (IAM) → role assignments.
    - Foundry `ais-*` → project `clc3-project` → **Model catalog / Deployments**: `gpt-5-mini`, version `2025-08-07`, SKU `GlobalStandard`, capacity. Endpoint + keys blade (note RBAC, not keys).
    - Cosmos `cosmos-*`: Data Explorer → `ImageAnalysis` / `results` → partition key `/filename`; Settings → serverless.
    - Container Apps env `cae-*` + app `ca-upload-*`: note placeholder image, unhealthy revision until Phase 2 (expected), ingress FQDN.
    - Function app `func-*` + plan `asp-*`: Overview → Flex Consumption; Configuration → app settings (identity-based connections, `APPLICATIONINSIGHTS_CONNECTION_STRING` with AAD).
    - ACR `acr*`: Repositories (empty until Phase 2); Access control → AcrPull assignment.
    - LAW `log-*` + App Insights `appi-*`: retention 30 days; workspace-based App Insights.

## Questions to answer (Phase 1)

1. Name the deployment methods available in Azure and state which one you used in step 8 and why it fits IaC.
2. What does `take(uniqueString(subscription().subscriptionId, rgName), 16)` guarantee, and why is the length capped at 16 for storage/ACR/Cosmos names?
3. Trace one example of resource chaining: how does `function.bicep` learn the storage account name? (`storage.outputs.*` → module params)
4. What is the purpose of `dependsOn` in `main.bicep`, and which dependency is implicit via outputs?
5. In the Portal, where do you see which role assignments exist, and which built-in roles are used? (Storage Blob Data Contributor/Owner, AcrPull, Azure AI User, …)
6. Which resource in the RG currently costs a fixed daily amount, and how much? (ACR Basic, $0.17/day)
7. Why does the container app show an unhealthy revision at this point? What fixes it in Phase 2?

---

# Phase 2 — Ship it: CI/CD + Foundry model (~60 min)

**Concepts:** 4, 5, 1. **Deliverable:** function + container app code deployed (manual path *and* via GitHub Actions); Foundry model inspected in the portal.

## Exact steps

1. **Wire the fork for CI**: re-run `bash scripts/preflight.sh` (step 6 pushes secret `AZURE_CLI_TOKENS` + `UPLOAD_TOKEN` and the variables via `gh`; manual equivalent: `scripts/README.md` §6). Verify: your fork → Settings → Secrets and variables → Actions.
2. **Trigger CI**: push any change under `infrastructure/**` to `main` (or *Actions → infra-deploy → Run workflow*). Watch it run. Then run **containerapp-deploy** and **function-deploy** the same way. Meanwhile read the three workflow files.
3. **Manual function deploy** (README step 5) — do this too, to compare with CI:
   ```bash
   cd src/image-analysis-function
   pip install -r requirements.txt
   func azure functionapp publish <functionAppName> --build local
   # macOS Apple Silicon: pre-build Linux wheels first (README step 5 gotcha):
   #   rm -rf .python_packages && mkdir -p .python_packages/lib/site-packages
   #   pip install --platform manylinux2014_x86_64 --python-version 3.13 --abi cp313 --only-binary=:all: --target .python_packages/lib/site-packages -r requirements.txt
   ```
   Portal: function app → **Functions** → `AnalyzeImage` present (trigger: Blob, Event Grid source, enabled).
4. **Event Grid subscription** (README step 5, after publish — webhook is validated against the function):
   ```bash
   SUB=$(az account show --query id -o tsv); RG=rg-clc3-<your-lastname>
   APP=<functionAppName>; ST=<storageAccountName>
   HOST=$(az functionapp show --name "$APP" --resource-group "$RG" --query properties.defaultHostName -o tsv)
   BLOBS_KEY=$(az rest --method POST --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/host/default/listkeys?api-version=2024-11-01" --query systemKeys.blobs_extension -o tsv)
   az eventgrid event-subscription create \
     --source-resource-id "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ST" \
     --name "sub-$APP-AnalyzeImage" --endpoint-type webhook \
     --endpoint "https://$HOST/runtime/webhooks/blobs?functionName=Host.Functions.AnalyzeImage&code=$BLOBS_KEY" \
     --included-event-types Microsoft.Storage.BlobCreated \
     --subject-begins-with "/blobServices/default/containers/imageanalysis/blobs/"
   ```
5. **Manual container app deploy** (README step 6):
   ```bash
   ACR=<acrName>; SERVER=<acrLoginServer>
   TOKEN=$(az acr login --name "$ACR" --expose-token --query accessToken -o tsv)
   echo "$TOKEN" | docker login "$SERVER" -u 00000000-0000-0000-0000-000000000000 --password-stdin
   docker build --platform linux/amd64 -t "$SERVER/upload-app:latest" -f src/upload-app/Dockerfile src/upload-app
   docker push "$SERVER/upload-app:latest"
   az containerapp registry set --name <containerAppName> --resource-group $RG --server "$SERVER" --identity system
   az containerapp update --name <containerAppName> --resource-group $RG --image "$SERVER/upload-app:latest"
   ```
   (`--platform linux/amd64` is mandatory on Apple Silicon. `registry set` must happen before the first ACR image update — AcrPull chicken-and-egg, validation.md C1.)
6. **Foundry in the Portal** (ai.azure.com): project `clc3-project` → **Playground** → send `test.jpeg`, inspect request/response JSON (inputs/outputs); **Model catalog** → deployed model: name, version `2025-08-07`, SKU, capacity, TPM quota; **Monitoring**: requests, latency, tokens.

## Questions to answer (Phase 2)

1. Why does the CI build the image on the runner (`docker build`) instead of `az acr build`? What error do student subscriptions get, and which SKU would ACR Tasks need?
2. How does the GitHub runner authenticate to Azure without a service principal? What exactly is in the `AZURE_CLI_TOKENS` secret, and why must the fork be private?
3. How does the runner authenticate to ACR for `docker push`? (`az acr login --expose-token`)
4. Why must `az containerapp registry set --identity system` run before the first ACR-image update, and why is the registry entry not in the Bicep template? (C1)
5. Why is the Event Grid subscription created only *after* `func publish`? What endpoint does it use and which system key authenticates it?
6. Why does Flex Consumption need `--build local`? What breaks on macOS without the manylinux pre-build?
7. Which model version is deployed and why not `gpt-4o-mini`? Where do you check deprecations?
8. In the workflows, where do `ACR_NAME`/`FUNCTION_APP_NAME`/etc. come from, and why not repo variables set by CI? (C2 — read from `az deployment sub show` outputs)

---

# Phase 3 — Operate it: e2e test, observability, cost, cleanup (~60 min)

**Concepts:** 6, 3, 5. **Deliverable:** one successful upload → analysis → Cosmos document, all hops traced in logs/metrics; deliberate error found; costs understood; everything deleted.

## Exact steps

1. **E2E upload** (README step 7):
   ```bash
   curl -H "X-Upload-Token: $UPLOAD_TOKEN" -F "file=@test.jpeg" https://<uploadAppFqdn>/upload
   # expect HTTP 200 + JSON {blobName, container, size, message}
   curl -H "X-Upload-Token: wrong-token" -F "file=@test.jpeg" https://<uploadAppFqdn>/upload
   # expect HTTP 401  (deliberate error for step 2)
   ```
2. **Trace every hop with Azure native tooling** (see [observability diagram](diagrams/observability.mermaid)); Portal → LAW `log-*` → Logs (KQL from README step 7 "Explore observability"):
   - ACA: `ContainerAppConsoleLogs_CL | where ContainerAppName_s contains "ca-upload"` → the `/upload` 200 **and** the 401.
   - Function: portal → function app → **Monitor** (App Insights); in LAW: `AppTraces | where Message contains "AnalyzeImage"` → execution Succeeded + duration.
   - Event Grid: `AzureDiagnostics | where ResourceProvider == "MICROSOFT.EVENTGRID"` → BlobCreated delivery to the webhook.
   - Storage: `StorageBlobLogs | where OperationName has "PutBlob"` → `test.jpeg` written.
   - Foundry: `AzureDiagnostics | where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"` (Audit/Trace/AzureOpenAIRequestUsage) → inference call + token counts; compare with Foundry portal Monitoring.
   - Cosmos: Portal → Data Explorer → `ImageAnalysis/results` → document `id=test.jpeg` with `analysis` JSON; in LAW `AzureDiagnostics | where ResourceProvider == "MICROSOFT.DOCUMENTDB" and Category == "DataPlaneRequests"`.
   - Metrics: any resource → **Monitor → Metrics** (function executions, ACA requests/CPU, Cosmos RU/s); same data in LAW as `AzureMetrics`.
3. **Deliberate-error exercise:** with the wrong-token 401 (or by deleting the Event Grid subscription), find the failure in logs/metrics within 5 minutes and explain the service-communication chain (who called whom, in which order, with which result code).
4. **Cost check:** Portal → subscription → **Cost analysis**: group by resource — what costs per day (ACR Basic $0.17) vs. what is free at this scale (LAW 5 GB/month free, Cosmos serverless, Flex, scale-to-zero ACA, model ~$0.001/image). Compare with your budget alert.
5. **Cleanup (mandatory, README step 11):**
   ```bash
   az group delete --name rg-clc3-<your-lastname> --yes --no-wait
   # after it finishes, purge the soft-deleted Cognitive Services account so names can be reused:
   az cognitiveservices account purge --name <ais-...> --location $LOC -g rg-clc3-<your-lastname>
   az group list   # verify empty
   ```

## Questions to answer (Phase 3)

1. Trace one uploaded image through all six services using only logs/metrics — which table/query shows which hop?
2. Where do you see that Event Grid delivered the BlobCreated event successfully?
3. How many tokens did your inference consume, and where is that visible (two places)?
4. What did the wrong-token request look like in the container app logs (status code, path, timestamp)?
5. Which diagnostic-setting categories are enabled for storage vs. Cosmos vs. Foundry, and why is Foundry `RequestResponse` off? (cost: base64 image payloads)
6. Why do platform metrics need no diagnostic setting, and what is the difference between Azure Monitor Metrics and the `AzureMetrics` table in the LAW?
7. What is the only fixed daily cost in this architecture, and how would you verify it in Cost analysis?
8. Why must the Cognitive Services account be purged after `az group delete` before re-deploying with the same names?

---

# Appendix A — Answer key (for the examiner)

- **P1-Q1:** Portal, Cloud Shell, CLI/PowerShell, ARM/Bicep, REST, SDKs, CI (GitHub Actions) — step 8 used CLI+Bicep (ARM engine), which is repeatable/scriptable vs. Portal clicks.
- **P1-Q2:** deterministic per (subscription, rgName) → no collisions between students in different subscriptions; 16 hex chars because storage/ACR/Cosmos names have length limits and need lowercase alphanumerics.
- **P1-Q3:** `storage.outputs.storageAccountName` passed as `storageAccountName` param to the `functionApp` module — outputs of one module become inputs of another (chaining); `dependsOn` is for ordering without data flow (e.g. rbac needs the RG).
- **P1-Q5:** RG → Access control (IAM) → Role assignments; roles: Storage Blob Data Owner/Contributor, AcrPull, Azure AI User, Monitoring Metrics Publisher, Cosmos DB Built-in Data Contributor — all to managed-identity principals, no keys.
- **P1-Q6:** ACR Basic $0.1666/day; everything else is consumption/free-tier at this scale.
- **P1-Q7:** placeholder MCR image revision is unhealthy until the real ACR image is pushed in Phase 2.
- **P2-Q1:** `TasksOperationsNotAllowed` on student subs; ACR Tasks need Standard/Premium. Runner-side build + `az acr login --expose-token` works on Basic.
- **P2-Q2:** base64 tar of `~/.azure` token store (msal_token_cache.json + azureProfile.json); workflows decode it into `$HOME/.azure` and `az account set`. Public fork → anyone with write access can read secrets via a workflow.
- **P2-Q4:** the platform mints an ACR pull token at first revision provisioning; AcrPull is only assigned by rbac.bicep *after* the containerapp module — declaring the registry in Bicep deadlocks ("Operation expired"). CI adds it via `registry set` once AcrPull exists.
- **P2-Q5:** the blob-extension webhook endpoint is validated against the published function; key = `blobs_extension` system key from `listkeys`.
- **P2-Q6:** Flex has no remote/Oryx build; `func publish --build local` runs pip on the host — on macOS that packages macOS wheels → Linux host fails with `invalid ELF header`, 0 functions loaded.
- **P2-Q7:** gpt-5-mini (2025-08-07); gpt-4o-mini (2024-07-18) is deprecating and rejected for new deployments (validation.md).
- **P2-Q8:** `az deployment sub show --name clc3-2026 --query properties.outputs` — GITHUB_TOKEN couldn't be granted write on repo variables reliably on fresh forks (403, validation.md C2).
- **P3-Q1:** upload: ContainerAppConsoleLogs_CL (200/401) → StorageBlobLogs PutBlob → AzureDiagnostics EVENTGRID → AppTraces AnalyzeImage → AzureDiagnostics COGNITIVESERVICES (usage) → DOCUMENTDB DataPlaneRequests + Data Explorer doc.
- **P3-Q3:** `AzureOpenAIRequestUsage` in LAW + Foundry portal Monitoring (tokens/requests/latency).
- **P3-Q5:** storage blob child StorageRead/Write/Delete→StorageBlobLogs; Cosmos DataPlaneRequests et al.; Foundry Audit/Trace/AzureOpenAIRequestUsage — RequestResponse logs full payloads incl. base64 image (~1.4× upload size).
- **P3-Q6:** platform metrics are emitted to Azure Monitor automatically (Metrics explorer, free); `AllMetrics` diagnostic settings copy them into `AzureMetrics` in the LAW.
- **P3-Q7:** ACR Basic only; Cost analysis grouped by resource/resource group.
- **P3-Q8:** soft-delete keeps the name reserved (`FlagMustBeSetForRestore` on recreate); purge removes it.

# Appendix B — Quick reference

- Preflight: `bash scripts/preflight.sh` (manual: `scripts/README.md`)
- Infra deploy: README step 4 · Function: step 5 · Container app: step 6 · E2E: step 7 · Cleanup: step 11
- Workflows: `.github/workflows/{infra-deploy,containerapp-deploy,function-deploy}.yml`
- KQL snippets: README step 7 "Explore observability" · Pitfalls: `docs/validation.md`
