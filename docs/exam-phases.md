# Practical Exam — 3-Phase Deployment Plan (uap-clc3-2026)

**Format:** ~3 hours, individual work. Students walk through the deployment of the
reference architecture step by step and practice the lecture concepts hands-on.
They start from an **empty Azure for Students subscription** and their **own private
fork** of this repo.

**Diagrams:** [architecture](diagrams/architecture.mermaid) ·
[infrastructure/Bicep](diagrams/infrastructure.mermaid) ·
[CI/CD](diagrams/cicd.mermaid) · [observability](diagrams/observability.mermaid)

## Concepts covered (exam objectives → where they are practiced)

| # | Concept | Practiced in |
|---|---|---|
| 1 | Deployment methods in Azure (Portal / CLI / Bicep / CI) | Phase 1 (CLI+Bicep, Portal read), Phase 2 (CI), Phase 3 (Portal) |
| 2 | Infrastructure as Code with Bicep — structure, params, modules, dynamic values (`uniqueString`), resource chaining (outputs → params, `dependsOn`) | Phase 1 |
| 3 | Core Azure services configured via the **Azure Portal** (Storage, Event Grid, Foundry, Cosmos, ACA, Functions, ACR, Monitor) | Phase 1 + Phase 3 |
| 4 | CI/CD — getting code into Azure services (GitHub Actions, runner-side docker build, `func publish`, token auth) | Phase 2 |
| 5 | Azure Foundry — deploy models, inspect model version/inputs/outputs, check usage | Phase 2 + Phase 3 |
| 6 | Observability — logs, errors, service communication, metrics (Log Analytics, App Insights, Metrics) | Phase 3 |

## Ground rules (apply to all phases)

1. **Fork stays private.** `scripts/preflight.sh` step 6 stores your az CLI token as the repo
   secret `AZURE_CLI_TOKENS` — anyone with write access to the repo could misuse it.
2. **Run `scripts/preflight.sh` first** (Step 0): it shows which regions your subscription may
   deploy to (Azure Policy) and where the model quota is — you need this for the `location`
   parameter. Set a **budget alert** (README step 3) before deploying anything.
3. Use the region from preflight's `RECOMMENDED LOCATION` for **everything** (single region).
4. Work through the phases **in order** — each phase builds on the previous one.
5. **Cleanup at the end** (Phase 3, last step): `az group delete` + purge the soft-deleted
   Cognitive Services account (README step 11). Leaving resources running costs credit
   (ACR Basic is the only fixed cost, $0.17/day).
6. Stuck? `docs/validation.md` lists the pitfalls we hit live (E1–E12, C1–C3) with fixes.

---

## Phase 1 — "Foundation": Infrastructure as Code with Bicep (~60 min)

**Goal:** deploy the complete infrastructure once via Bicep from the CLI, then *explore and
understand* every resource in the Azure Portal. Concepts 1, 2, 3.

### Steps

1. **Fork + clone + devcontainer** (README steps 1–2). Run `scripts/preflight.sh` and note the
   `RECOMMENDED LOCATION` and your allowed regions (concept 1: policies restrict regions).
2. **Read the IaC before deploying** (concept 2 — 15 min):
   - `infrastructure/main.bicep`: subscription scope, parameters (`rgName`, `location`, model
     params, `uploadToken`), the `nameSuffix = take(uniqueString(subscription().subscriptionId,
     rgName), 16)` dynamic value (why: globally unique storage/ACR/Cosmos names per student),
     one `module` per concern, and how module **outputs chain into other modules' params**
     (e.g. `storage.outputs.storageAccountName` → `functionApp` params) and `dependsOn`.
   - Skim the modules in `infrastructure/modules/` — note which resource types they create.
   - See [infrastructure diagram](diagrams/infrastructure.mermaid).
3. **Deploy via CLI + Bicep** (concept 1 — deployment method: ARM/Bicep via `az deployment sub
   create`, README step 4). Watch the deployment in the Portal: subscription → **Deployments** →
   `clc3-2026` (operations, resources, outputs). Note the outputs — Phase 2 needs them.
4. **Explore the resource group in the Portal** (concept 3 — 25 min). For each resource, open it
   and answer: what is it for in this pipeline, how is it configured, where are its keys/RBAC?
   - **Storage account** → Data storage → Containers → `imageanalysis`; note the Event Grid
     **system topic** `systopic-*` (created for BlobCreated events).
   - **Foundry account `ais-*`** → project `clc3-project` → **Model catalog / Deployments**:
     `gpt-5-mini`, version `2025-08-07`, SKU `GlobalStandard` — this is concept 5's foundation.
   - **Cosmos DB** → Data Explorer → database `ImageAnalysis`, container `results`, partition key.
   - **Container Apps env + app** → note the placeholder image and that the revision is unhealthy
     until Phase 2 pushes the real image (expected).
   - **Function app** → Overview (Flex Consumption plan `asp-*`), Configuration → app settings
     (identity-based connections, no keys).
   - **ACR** → Repositories (empty until Phase 2), Access control (RBAC — AcrPull for the app).
   - **Log Analytics + App Insights** → you will use these in Phase 3.

### Checkpoint (self-check questions)

- Which three ways can you deploy resources in Azure, and which did you use here?
- What does `uniqueString(subscription().subscriptionId, rgName)` guarantee, and why is
  `take(..., 16)` needed for storage/ACR names?
- How does `function.bicep` learn the storage account name? (outputs → params chaining)
- Where in the Portal do you see that a role assignment was created, and for which principal?

---

## Phase 2 — "Ship it": CI/CD + the Foundry model (~60 min)

**Goal:** get the application code into the Container App and the Function via GitHub Actions,
and understand the Foundry model deployment. Concepts 4, 5, 1 (CI as a deployment method).

### Steps

1. **Wire your fork for CI** (concept 4): run `scripts/preflight.sh` again — step 6 pushes
   `AZURE_CLI_TOKENS` (your az token store) + `UPLOAD_TOKEN` as secrets and the subscription
   variables. Read `scripts/README.md` section 6 for the manual equivalent and **why** a service
   principal is not possible in the FH tenant (`az ad app create` → Insufficient privileges).
2. **Trigger the pipeline** (concepts 1+4): push any change under `infrastructure/**` to `main`
   → watch `infra-deploy` in the fork's **Actions** tab. Then run `containerapp-deploy` and
   `function-deploy` via **Run workflow**. Read the workflow files and answer:
   - Why is the image built **on the runner** (`docker build`) and not with `az acr build`?
     (ACR Tasks blocked on student subscriptions.)
   - How does the runner authenticate to Azure without a service principal? (token secret)
   - How does the runner authenticate to ACR? (`az acr login --expose-token`)
   - Why does the container app need `az containerapp registry set --identity system` before the
     first ACR image update? (AcrPull chicken-and-egg — see validation.md C1)
   - Why is the Event Grid subscription created **after** `func publish`? (webhook endpoint
     validation) — see [cicd diagram](diagrams/cicd.mermaid).
3. **Foundry in the Portal** (concept 5 — 20 min): Foundry project → **Playground** (chat/vision):
   send `test.jpeg` and inspect the model's **inputs/outputs** (JSON). **Model catalog** → deployed
   model: version, SKU, capacity, tokens/min quota. **Monitoring** in the AI Foundry portal:
   requests, latency, token usage.

### Checkpoint

- Name the four deployment methods you used so far and where each fits.
- What would break in CI if the fork were public? (secret exfiltration via workflow)
- Where in the workflow do we read resource names from, and why not repo variables? (C2)
- Which model version is deployed and why not `gpt-4o-mini`? (deprecation — validation.md)

---

## Phase 3 — "Operate it": e2e test, logs, metrics, errors, cleanup (~60 min)

**Goal:** run the pipeline end-to-end, then use Azure native observability to see what happened,
find errors, and check service communication and metrics. Concepts 6, 3, 5.

### Steps

1. **E2E test**: read the FQDN + upload token (README step 7), `curl -H "X-Upload-Token: …"
   -F file=@test.jpeg https://<fqdn>/upload` → expect 200. Then repeat with a **wrong token** →
   401 (deliberate error for step 2).
2. **Observe the flow** (concept 6 — 25 min), using the [observability diagram](diagrams/observability.mermaid):
   - **Portal → Container App → Log stream / Logs**: `ContainerAppConsoleLogs_CL` in the LA
     workspace shows the `/upload` handling and the 401.
   - **Portal → Function app → Monitor / App Insights**: the `AnalyzeImage` execution
     (Succeeded, duration), `AppTraces` in the workspace.
   - **Event Grid**: system topic → the BlobCreated event delivery to the webhook
     (`AzureDiagnostics`, provider `MICROSOFT.EVENTGRID`).
   - **Storage**: `StorageBlobLogs` shows `PutBlob` for `test.jpeg`.
   - **Cosmos**: Data Explorer → `ImageAnalysis/results` → document `id=test.jpeg` with the
     model's `analysis` JSON. Also visible as `DataPlaneRequests` in `AzureDiagnostics`.
   - **Foundry usage** (concept 5): `AzureOpenAIRequestUsage` in the workspace = token counts per
     inference call; compare with AI Foundry portal monitoring.
   - **Metrics**: any resource → **Metrics** (Azure Monitor): function executions, ACA requests/CPU,
     Cosmos RU/s (`AzureMetrics` in the workspace has the same via diagnostic settings).
3. **Find an error on purpose**: e.g. upload with wrong token (401) or temporarily break the Event
   Grid subscription — then locate it via logs/metrics and fix it. This is the exam's core
   observability skill: *service communication* (who called whom, in which order, with what result).
4. **Cost check** (concept 3/ops): **Cost Management + billing** → Cost analysis per resource:
   what costs money per day (ACR Basic $0.17) vs. what is free at this scale (LAW 5 GB/month free,
   Cosmos serverless, Flex Consumption, scale-to-zero ACA).
5. **Cleanup** (mandatory): README step 11 — `az group delete -g <rg> --yes`, then purge the
   soft-deleted Cognitive Services account
   (`az cognitiveservices account purge --name <ais-*> --location <region> -g <rg>`), verify the
   subscription is empty.

### Checkpoint

- Trace one uploaded image through all six services using only logs/metrics — which table shows
  which hop?
- Where do you see that Event Grid delivered the event successfully?
- How many tokens did your inference call consume, and where is that visible?
- What did the wrong-token request look like in the container app logs (status code, path)?

---

## Appendix — quick reference

- Preflight (regions/quotas + GitHub wiring): `bash scripts/preflight.sh` — manual steps in `scripts/README.md`
- Manual infra deploy: README step 4 (`az deployment sub create …`)
- Workflows: `.github/workflows/infra-deploy.yml`, `containerapp-deploy.yml`, `function-deploy.yml`
- Upload test: README step 7 (curl + token from `az containerapp secret show`)
- KQL snippets for the LA workspace: README step 7 "Explore observability"
- Known pitfalls with fixes: `docs/validation.md` (E1–E12, C1–C3)
- Cleanup: README step 11 (incl. Cognitive Services purge)
