# Implementation Plan — Modernizing the CLC3 Azure Example (uap-clc3-2026)

**Date:** 2026-11-14
**Source example:** https://github.com/juergenbr/fh-clc2025-breitenbaumer (Java 11 Consumption Function App + Logic App + Computer Vision v2.0/v3.2 + Cosmos DB)
**Working repo:** `repos/uap-clc3-2026` (this repository)

## Goals

1. Use the **latest Azure AI services** — Microsoft Foundry (resource + project) with a deployed vision-capable model, called through the **Foundry SDK** (`azure-ai-projects`).
2. Replace the **image-upload HTTP function** (Java Function App) with an **Azure Container App**.
3. Replace the **Logic App** with a **Flex Consumption Azure Function** that:
   - takes the uploaded **blob as an input binding** (blob trigger, Event Grid source — the only supported source on Flex Consumption),
   - sends the image to the AI service via the **Foundry SDK**,
   - writes the resulting JSON into **Cosmos DB via an output binding**.

---

# Part 1 — Research: documentation of the Azure services in scope

All facts below were verified against Microsoft Learn / PyPI / Azure-Samples on **2026-11-14**.

## 1.1 Azure AI Foundry (resource, project, model deployments) + Foundry SDK

| Fact | Detail | Source |
|---|---|---|
| Foundry resource | `Microsoft.CognitiveServices/accounts` with `kind: 'AIServices'`, `sku: S0`, `properties.allowProjectManagement: true`, `properties.disableLocalAuth`, `customSubDomainName`, `publicNetworkAccess` (API `2025-06-01`; GA `2025-11-01`) | learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts; TechCommunity "Automating Microsoft Foundry Deployment with IaC" |
| Foundry project | Native child resource `Microsoft.CognitiveServices/accounts/projects` (e.g. API `2025-07-01-preview` / `2026-07-15-preview`), with `properties.displayName`, `description`, `capabilitySettings` | learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts/projects |
| Model deployment | Child `Microsoft.CognitiveServices/accounts/deployments` with `properties.model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '...' }` and `properties.sku: { name: 'GlobalStandard', capacity: N }` | learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts/deployments; learn.microsoft.com/azure/foundry/foundry-models/how-to/create-model-deployments |
| Project endpoint format | `https://<foundry-resource>.services.ai.azure.com/api/projects/<project-name>` | learn.microsoft.com/azure/foundry/quickstarts/get-started-code |
| Foundry SDK (Python) | Package `azure-ai-projects`, **latest stable 2.11.0** (PyPI, Nov 2026) — the "Foundry projects (new)" 2.x API; the 1.0.0bX line is the legacy "Foundry (classic)" API and must not be mixed | pypi.org/project/azure-ai-projects |
| SDK usage | `AIProjectClient(endpoint=..., credential=DefaultAzureCredential())`, then `project.get_openai_client()` (OpenAI-compatible client) or the inference clients; `responses.create(model=<deployment-name>, ...)` / `chat.completions.create(model=<deployment-name>, messages=[...])` | learn.microsoft.com/azure/foundry/quickstarts/get-started-code |
| Vision input | Vision models: o-series, GPT-5, GPT-4.1, GPT-4.5, GPT-4o series. Image passed as `image_url` content part with a **publicly reachable URL (incl. SAS)** or as **base64 data URL** | learn.microsoft.com/azure/foundry/openai/how-to/gpt-with-vision |
| Auth | Entra ID (managed identity) via `DefaultAzureCredential`; keys possible but `disableLocalAuth: true` is recommended | learn.microsoft.com/azure/foundry/concepts/rbac-foundry |
| RBAC for inference | **`Azure AI User`** role on the project (role definition id `53ca6127-db72-4b80-b1b0-d745d6d5456d`); legacy `Cognitive Services OpenAI User` = `5e0bd9bd-7b93-4f28-af87-19fc36ad61bd` | learn.microsoft.com/azure/role-based-access-control/built-in-roles/ai-machine-learning |
| Responsible AI | Students must still accept the Responsible AI terms once per subscription before creating AI resources (existing step from the 2025 README stays) | 2025 README; Azure portal flow |

## 1.2 Azure Functions — Flex Consumption plan

| Fact | Detail | Source |
|---|---|---|
| Plan | App Service plan SKU `FC1`, tier `FlexConsumption`, `reserved: true`; site `kind: 'functionapp,linux'` | Azure-Samples/azure-functions-flex-consumption-samples `IaC/bicep/main.bicep` |
| Supported stacks (2026-11) | .NET 8/9/10/11 (isolated only), **Python 3.10–3.15**, Node 22/24/26, Go 1.24+, **Java 8/11/17/21/25**, PowerShell 7.4/7.6, custom handlers | learn.microsoft.com/azure/azure-functions/flex-consumption-plan |
| Scaling | Scale to zero, event-driven fast scale-out, max instance count 1–1000, instance memory 512/2048/4096 MB, per-function concurrency, regional subscription memory quota | ibid. |
| Blob trigger on Flex | **Only the Event Grid source is supported** (`source=func.BlobSource.EVENT_GRID` in Python v2 / `source: "EventGrid"` in function.json). Polling trigger not available. Non-C# apps must use extension bundle **`[4.0.0, 5.0.0)`** in host.json | learn.microsoft.com/azure/azure-functions/flex-consumption-plan; functions-bindings-storage-blob-trigger |
| Event Grid setup | Event Grid **system topic** on the storage account (`topicType: Microsoft.Storage.StorageAccounts`) + **event subscription** with `destination.endpointType: 'AzureFunction'`, endpoint `.../providers/Microsoft.Web/sites/<func>/functions/<functionName>`, `includedEventTypes: Microsoft.Storage.BlobCreated`. Requires **general-purpose v2** storage account | learn.microsoft.com/azure/azure-functions/functions-event-grid-blob-trigger; learn.microsoft.com/azure/templates/microsoft.eventgrid/systemtopics/eventsubscriptions |
| Python v2 programming model | Single `function_app.py`, decorators: `@app.blob_trigger(arg_name=..., path="container/{name}", connection="SETTING", source=func.BlobSource.EVENT_GRID)`; blob content via SDK-type `azurefunctions.extensions.bindings.blob.BlobClient` (package `azurefunctions-extensions-bindings-blob`) or `func.InputStream`; `requirements.txt`, `host.json`, `local.settings.json` | Azure-Samples/functions-quickstart-python-azd-eventgrid-blob `src/function_app.py`; functions-reference-python |
| Cosmos DB output binding (Python v2) | `@app.cosmos_db_output(arg_name="doc", database_name=..., container_name=..., connection="SETTING", create_if_not_exists=True, partition_key=...)` with `func.Out[func.Document]` and `doc.set(...)`. Attributes: `DatabaseName`, `ContainerName` (legacy `CollectionName`), `CreateIfNotExists`, `PartitionKey`, `Connection` (identity-based) or `ConnectionStringSetting` | learn.microsoft.com/azure/azure-functions/functions-bindings-cosmosdb-v2-output |
| Identity-based connections | Instead of connection strings: app settings `<PREFIX>__blobServiceUri`, `<PREFIX>__queueServiceUri`, `<PREFIX>__credential: managedidentity` (e.g. `AzureWebJobsStorage__blobServiceUri=https://<acct>.blob.core.windows.net`) | learn.microsoft.com/azure/azure-functions/manage-connections |
| Required storage roles | For the host (`AzureWebJobsStorage`): **Storage Blob Data Owner** (`b7e6dc6d-f1e8-4753-8033-0f276bb0955b`) — also covers poison-blob queue writes of the blob trigger. For a separate trigger connection: Storage Blob Data Reader + Storage Queue Data Contributor | learn.microsoft.com/azure/azure-functions/manage-connections |
| Deployment | No remote build on Flex: build/zip **locally** (`func azure functionapp publish <app> --build local`, or `az functionapp deployment source config-zip --src app.zip`). Package is stored in a **blob deployment container** (default: the AzureWebJobsStorage account; configurable via site `functionAppConfig.deployment.storage` with `SystemAssignedIdentity`) | learn.microsoft.com/azure/azure-functions/flex-consumption-how-to; flex-consumption-plan |
| Limitations | No deployment slots, no NFS mounts, Flex region availability list applies; `WEBSITE_CONTENTSHARE`/file-share settings deprecated | flex-consumption-plan |

## 1.3 Azure Container Apps (image upload frontend)

| Fact | Detail | Source |
|---|---|---|
| What it is | Serverless container hosting; revision-based, scale-to-zero, external **ingress** with automatic HTTPS | learn.microsoft.com/azure/container-apps/overview |
| Fastest deploy | `az containerapp up --name <app> --resource-group <rg> --source <local-dir|github-url> --ingress external --target-port 8080` — builds image (buildpacks or Dockerfile), pushes to a created ACR, creates environment + app | learn.microsoft.com/azure/container-apps/get-started; /containerapp-up; /quickstart-code-to-cloud |
| Bicep resources | `Microsoft.App/managedEnvironments` (with `appLogsConfiguration.logAnalyticsConfiguration.{customerId,sharedKey}` for Log Analytics) and `Microsoft.App/containerApps` (`identity: { type: 'SystemAssigned' }`, `properties.configuration.ingress: { external: true, targetPort }`, `properties.template.containers` with image/resources/scale, `environmentId`) — current API versions `2025-07-01` / `2026-01-01` | learn.microsoft.com/azure/templates/microsoft.app/containerapps; /managedenvironments |
| Managed identity | System-assigned identity on the container app; grant **Storage Blob Data Contributor** (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`) on the storage account for uploads; authenticate from code with `DefaultAzureCredential` + `azure-storage-blob` | learn.microsoft.com/azure/container-apps/managed-identity |
| ACR | Either let `az containerapp up` create/manage an ACR, or create `Microsoft.ContainerRegistry/registries` in Bicep and grant the app's kubelet/ACI identity AcrPull, or use `az acr build` | learn.microsoft.com/azure/container-apps/quickstart-code-to-cloud |

## 1.4 Azure Cosmos DB for NoSQL (output binding target)

| Fact | Detail | Source |
|---|---|---|
| Resource | `Microsoft.DocumentDB/databaseAccounts`, `kind: GlobalDocumentDB`, `apiVersion` ~`2025-04-01`+; **serverless** capability (`EnableServerless`) is ideal for the student/lecture cost profile; database `ImageAnalysis`, container `results` with partition key (e.g. `/filename`) | learn.microsoft.com/azure/templates/microsoft.documentdb/databaseaccounts |
| Data-plane RBAC | Built-in data roles via `sqlRoleAssignments` child resource; **Cosmos DB Built-in Data Contributor** = role definition id `00000000-0000-0000-0000-000000000002`, assignable at account/database/container scope | learn.microsoft.com/azure/cosmos-db/how-to-setup-rbac; old repo `cosmosdb_roleassignment_module.bicep` |
| Functions identity connection | App setting `COSMOS_CONNECTION__accountEndpoint=https://<acct>.documents.azure.com:443/` + `COSMOS_CONNECTION__credential=managedidentity`; binding uses `connection="COSMOS_CONNECTION"` | manage-connections; functions-bindings-cosmosdb-v2-output |

## 1.5 Azure Storage + Event Grid (blob pipeline backbone)

| Fact | Detail | Source |
|---|---|---|
| Storage account | **StorageV2 (general-purpose v2)** required for Event Grid blob subscriptions; containers: `imageanalysis` (upload target / trigger source), `results` (optional result JSON), plus host/deployment containers (`azure-webjobs-hosts`, deployment package container) | functions-event-grid-blob-trigger |
| Blob data roles | Upload app: Storage Blob Data Contributor. Function identity: Storage Blob Data Owner (host + poison queue) | manage-connections |
| Event Grid | System topic + subscription as described in 1.2; events `Microsoft.Storage.BlobCreated`; subject filter `/blobServices/default/containers/imageanalysis/blobs/` | learn.microsoft.com/azure/event-grid |

## 1.6 Cross-cutting: identity, monitoring, IaC, CI/CD

- **Managed identity everywhere** (`DefaultAzureCredential` in code; system-assigned identities in Bicep). Key role ids: Storage Blob Data Contributor `ba92f5b4-2d11-453d-a403-e96b0029c9fe`, Storage Blob Data Owner `b7e6dc6d-f1e8-4753-8033-0f276bb0955b`, Cosmos DB Built-in Data Contributor `00000000-0000-0000-0000-000000000002`, Azure AI User `53ca6127-db72-4b80-b1b0-d745d6d5456d`.
- **Monitoring:** Log Analytics workspace + Application Insights (`APPLICATIONINSIGHTS_CONNECTION_STRING` + `APPLICATIONINSIGHTS_AUTHENTICATION_STRING: Authorization=AAD` on the function; ACA env `appLogsConfiguration`).
- **IaC:** Bicep, subscription-scope deployment like the 2025 example (`az deployment sub create --template-file main.bicep --location westeurope`), modules per resource group child.
- **CI/CD:** GitHub Actions — infra deploy via `azure/cli` + `az deployment sub create`; function deploy via Azure Functions Core Tools (`func azure functionapp publish --build local`) or `azure/webapps-deploy` with a local-build zip; container app via `az acr build` + `az containerapp update` (or `az containerapp up --source <repo>` which generates a workflow).
- **Retired/legacy:** Azure AI Custom Vision is deprecated (no new projects) — the "Extra: Custom Vision" section of the 2025 README should be dropped or marked legacy. Computer Vision v2.0/v3.2 REST calls are replaced by Foundry vision models.

---

# Part 2 — Target architecture (to-be)

```
Student (curl/Postman/browser)
        │  POST image (multipart or octet-stream)
        ▼
┌────────────────────────────┐   DefaultAzureCredential    ┌──────────────────────────┐
│ Azure Container App        │ ───────────────────────────▶│ Storage Account (GPv2)   │
│ (FastAPI upload service,   │  blob upload                │  container "imageanalysis"│
│  system-assigned identity) │                             └────────────┬─────────────┘
└────────────────────────────┘                                          │ BlobCreated event
                                                                        ▼
                                              ┌──────────────────────────────────────────┐
                                              │ Event Grid system topic + subscription   │
                                              │ (endpointType AzureFunction)             │
                                              └────────────┬─────────────────────────────┘
                                                           ▼
┌──────────────────────────┐    blob input binding   ┌──────────────────────────────────────┐
│ Cosmos DB for NoSQL      │◀── cosmos_db_output ────│ Azure Function — Flex Consumption    │
│ db "ImageAnalysis"       │    (JSON document)      │  Python v2 model, function_app.py    │
│ container "results"      │                         │  1. @app.blob_trigger (Event Grid)   │
└──────────────────────────┘                         │  2. Foundry SDK: AIProjectClient →   │
                                                     │     vision model (gpt-4o-mini) →     │
                                                     │     structured JSON analysis         │
                                                     │  3. @app.cosmos_db_output → Cosmos   │
                                                     └──────────────┬───────────────────────┘
                                                                    │ Entra ID
                                                                    ▼
                                                     ┌──────────────────────────────────────┐
                                                     │ Microsoft Foundry resource           │
                                                     │  (AIServices, allowProjectManagement)│
                                                     │   └── project "clc3-project"         │
                                                     │        └── deployment "gpt-4o-mini"  │
                                                     └──────────────────────────────────────┘
```

Data flow: upload → blob in `imageanalysis` → BlobCreated event → Flex function → reads blob (input binding) → Foundry SDK sends image (base64 data URL; avoids SAS handling) to the deployed vision model with a prompt that returns strict JSON → function merges blob metadata (name, size, content type, URL) with the model JSON → writes one document via the Cosmos output binding (id = blob name, partition key `/filename`). Optional parity with 2025 behavior: also write the JSON to the `results` blob container via a blob output binding.

## Proposed repo layout

```
uap-clc3-2026/
├── README.md                         (rewritten student instructions)
├── docs/
│   ├── implementation-plan.md        (this document)
│   └── images/
├── .devcontainer/                    (updated: Python 3.13, Azure CLI, func Core Tools, Bicep, Docker)
├── .github/workflows/
│   ├── infra-deploy.yml              (az deployment sub create)
│   ├── function-deploy.yml           (func azure functionapp publish --build local)
│   └── containerapp-deploy.yml       (az acr build + az containerapp update / up)
├── infrastructure/
│   ├── main.bicep                    (subscription scope, orchestrates modules)
│   └── modules/
│       ├── resourcegroup.bicep
│       ├── monitoring.bicep          (LAW + App Insights)
│       ├── storage.bicep             (GPv2, containers, Event Grid topic + subscription)
│       ├── foundry.bicep             (AIServices account + project + gpt-4o-mini deployment)
│       ├── cosmosdb.bicep            (account [serverless], db ImageAnalysis, container results, sqlRoleAssignments)
│       ├── function.bicep            (FC1 plan, flex function app, app settings, RBAC)
│       └── containerapp.bicep        (ACA env, ACR, container app, ingress, RBAC)
├── src/
│   ├── upload-app/                   (Container App)
│   │   ├── main.py                   (FastAPI: GET / health + simple upload page, POST /upload)
│   │   ├── requirements.txt          (fastapi, uvicorn, azure-storage-blob, azure-identity, python-multipart)
│   │   └── Dockerfile
│   └── image-analysis-function/      (Flex Consumption, Python v2)
│       ├── function_app.py           (blob trigger [Event Grid] + Foundry SDK + cosmos output)
│       ├── host.json                 (extensionBundle [4.0.0, 5.0.0))
│       ├── requirements.txt          (azure-functions, azure-ai-projects, azure-identity, azurefunctions-extensions-bindings-blob)
│       ├── local.settings.json       (local dev)
│       └── tests/test_function_app.py
└── extra/                            (training_images.zip kept for optional exercises)
```

---

# Part 3 — Work packages

## WP0 — Repo scaffold (day 0)
- Create the structure above in `uap-clc3-2026`; commit the 2025 repo's `extra/training_images.zip` and docs images if still wanted.
- Update `.devcontainer` (base image with Python 3.13 + Azure CLI + Azure Functions Core Tools 4.x + Bicep CLI + Docker; VS Code extensions: Azure Functions, Azure Container Apps, Bicep).
- Delete/replace: `pom.xml`, `host.json` (v2 bundle), `infrastructure/logicapp_module.bicep`, `infrastructure/function_module.bicep` (Y1 consumption), `src/main/java/**`, `templates/`.

## WP1 — Infrastructure (Bicep), `infrastructure/`
1. `main.bicep` (subscription scope, params `deploymentName`, `rgName`, `location`, plus model params `modelName`/`modelVersion`/`modelCapacity`) → modules; outputs: function app name, container app FQDN, foundry project endpoint, cosmos endpoint, storage name.
2. `monitoring.bicep`: Log Analytics + App Insights (disableLocalAuth).
3. `storage.bicep`: StorageV2 account (`allowSharedKeyAccess: false` preferred; if false, all access via identity), containers `imageanalysis`, `results`, deployment package container, `azure-webjobs-hosts`; **Event Grid system topic** on the account + **event subscription** (`endpointType: AzureFunction` → function app function `AnalyzeImage`, `Microsoft.Storage.BlobCreated`, subject filter on `/imageanalysis/`).
4. `foundry.bicep`: `Microsoft.CognitiveServices/accounts` `kind: AIServices`, `allowProjectManagement: true`, `disableLocalAuth: true`, `publicNetworkAccess: Enabled`; child `accounts/projects` (`displayName`); child `accounts/deployments` for the vision model (`gpt-4o-mini`, `GlobalStandard`, capacity 1 — cheapest sufficient for a lecture; make it a param). Output **project endpoint** `https://<account>.services.ai.azure.com/api/projects/<project>`.
5. `cosmosdb.bicep`: serverless account, database `ImageAnalysis`, container `results` (partition key `/filename`, autoscale/serverless throughput), `sqlRoleAssignments` granting the function identity **Cosmos DB Built-in Data Contributor** at the container/database scope.
6. `function.bicep`: plan `FC1`/`FlexConsumption`; site `functionapp,linux`, system-assigned identity, `functionAppConfig`: runtime `python` / `3.13`, `scaleAndConcurrency` (maxInstanceCount 100, instanceMemoryMB 2048), `deployment.storage` blob container + SystemAssignedIdentity; app settings:
   - `AzureWebJobsStorage__blobServiceUri/__queueServiceUri/__tableServiceUri` + `__credential: managedidentity` (host + blob trigger connection)
   - `FOUNDRY_PROJECT_ENDPOINT` = project endpoint, `FOUNDRY_MODEL_DEPLOYMENT` = deployment name
   - `COSMOS_CONNECTION__accountEndpoint` + `__credential: managedidentity`
   - `APPLICATIONINSIGHTS_CONNECTION_STRING`, `APPLICATIONINSIGHTS_AUTHENTICATION_STRING: Authorization=AAD`, `FUNCTIONS_WORKER_RUNTIME` not needed for Flex (set via site config) — verify.
   - RBAC: function identity → Storage Blob Data Owner (storage account), Cosmos DB Built-in Data Contributor (cosmos scope), **Azure AI User** (foundry project).
7. `containerapp.bicep`: Log Analytics-backed `managedEnvironments`, `Microsoft.ContainerRegistry/registries` (Basic), `containerApps` with system identity, ingress external targetPort 8080, image placeholder (`<acr>.azurecr.io/upload-app:latest`), env vars `STORAGE_ACCOUNT_NAME`, `CONTAINER_NAME=imageanalysis`; RBAC: app identity → Storage Blob Data Contributor.
- Deploy: `az deployment sub create --template-file infrastructure/main.bicep --location westeurope` (same UX as 2025 README; keep the "re-run if role assignment fails" note — AAD propagation delay).

## WP2 — Upload Container App, `src/upload-app/`
- FastAPI app: `GET /` → minimal HTML upload form; `GET /health`; `POST /upload` (multipart file) → `BlobServiceClient` with `DefaultAzureCredential` → upload to `imageanalysis` container (content type from upload) → return JSON `{ blobName, url }`.
- `Dockerfile` (python:3.13-slim, uvicorn on 8080), `requirements.txt`.
- Deploy: `az acr build` + `az containerapp update --image ...` (workflow `containerapp-deploy.yml`); alternative teaching path: `az containerapp up --source src/upload-app`.
- Test: `curl -F "file=@test.jpeg" https://<app-fqdn>/upload`.

## WP3 — Flex Consumption function, `src/image-analysis-function/`
- `function_app.py` (Python v2 model):
  ```python
  @app.function_name("AnalyzeImage")
  @app.blob_trigger(arg_name="image", path="imageanalysis/{name}",
                    connection="AzureWebJobsStorage", source=func.BlobSource.EVENT_GRID)
  @app.cosmos_db_output(arg_name="doc", database_name="ImageAnalysis",
                        container_name="results", connection="COSMOS_CONNECTION",
                        create_if_not_exists=True, partition_key="/filename")
  def analyze_image(image: blob.BlobClient, doc: func.Out[func.Document]) -> None:
      # 1. read blob bytes/metadata
      # 2. base64 data URL → Foundry SDK:
      #    AIProjectClient(endpoint=FOUNDRY_PROJECT_ENDPOINT, credential=DefaultAzureCredential())
      #    client = project.get_openai_client()
      #    resp = client.chat.completions.create(model=FOUNDRY_MODEL_DEPLOYMENT, messages=[...image_url...])
      #    prompt demands strict JSON: description, tags[{name,confidence}], objects, colors, caption
      # 3. build document { id, filename, mediatype, path, size, analyzedAt, ai: {...} }
      # 4. doc.set(func.Document.from_dict(document))
  ```
- `host.json`: `{ "version": "2.0", "extensionBundle": { "id": "Microsoft.Azure.Functions.ExtensionBundle", "version": "[4.0.0, 5.0.0)" } }` (required for non-C# blob trigger on Flex).
- `requirements.txt`: `azure-functions`, `azure-ai-projects` (2.x), `azure-identity`, `azurefunctions-extensions-bindings-blob`.
- `local.settings.json` for local dev (Values: AzureWebJobsStorage connection string for local, COSMOS_CONNECTION__accountEndpoint, FOUNDRY_PROJECT_ENDPOINT).
- Unit test with mocked BlobClient + mocked chat client.
- Deploy: `func azure functionapp publish <app-name> --build local` (Flex has no remote build); sync triggers; workflow `function-deploy.yml`.
- Validate: upload via container app → check function logs (App Insights) → query Cosmos (`SELECT * FROM c` in Data Explorer).

## WP4 — CI/CD (`.github/workflows/`)
- `infra-deploy.yml`: `az login` (OIDC or secrets), `az deployment sub create` on push to main.
- `function-deploy.yml`: setup Python + Core Tools, `pip install -r requirements.txt`, `func azure functionapp publish --build local`.
- `containerapp-deploy.yml`: `az acr build` (or build-push-action) + `az containerapp update --image`.

## WP5 — Docs & devcontainer
- Rewrite `README.md` for students: prerequisites (VS Code, Docker, Azure for Students subscription, Responsible AI acknowledgement — unchanged from 2025), infra deploy, function deploy, container app deploy, end-to-end test (upload → Cosmos), troubleshooting (Event Grid subscription health, AAD propagation on role assignments, purging Cognitive Services accounts, model quota), cleanup (`az group delete`).
- Keep the step-by-step portal screenshots where still valid; replace Logic App screenshots with Foundry portal + function binding view.
- Update `.devcontainer`.

## WP6 — Validation, cost & cleanup
- Acceptance checklist: infra deploys green; function listed in portal with blob trigger (Event Grid) enabled; upload via curl/Postman → document appears in Cosmos within seconds; App Insights shows the execution; ACA returns 200 and blob exists.
- Cost notes for students: serverless Cosmos, FC1 pay-per-execution, `gpt-4o-mini` GlobalStandard capacity 1 (tokens are the cost driver), ACA scale-to-zero; estimate < a few € for the exercise.
- Cleanup script/instructions; purge note for Cognitive Services (soft-deleted names block re-deployment).

---

# Part 4 — Migration mapping (2025 → 2026)

| 2025 component | 2026 replacement |
|---|---|
| Java 11 Function App (Consumption Y1) `blobStorageUpload` HTTP trigger | **Azure Container App** (`src/upload-app`, FastAPI) — upload only; no AI call in the upload path anymore |
| Logic App `fh-clc3-logicapp` (blob polling trigger → CV v2.0 tag → Cosmos → results blob) | **Flex Consumption Python function** `AnalyzeImage`: blob trigger (Event Grid source, input binding) → Foundry SDK vision call → Cosmos DB output binding |
| Computer Vision multi-service account + REST v3.2/v2.0 with API key | **Foundry resource (AIServices) + project + gpt-4o-mini deployment**, Foundry SDK 2.x, Entra ID (Azure AI User), `disableLocalAuth` |
| `CognitiveService.java` raw REST + SAS token | Deleted; image sent as base64 data URL through the SDK (no SAS needed) |
| Cosmos DB via Logic App managed-identity connection | Cosmos DB via **function output binding** + identity-based connection + `sqlRoleAssignments` in Bicep |
| Storage account + containers | Same, but **StorageV2** + Event Grid system topic/subscription added; identity-based `AzureWebJobsStorage__*` settings |
| Function App Y1 plan + GitHub Actions (Deployment Center) | FC1 Flex Consumption plan + `func azure functionapp publish --build local` in GitHub Actions |
| Custom Vision extra (training/prediction accounts, customvision.ai) | Drop or mark legacy — Custom Vision is deprecated |
| `pom.xml`, Java sources, `templates/` | Removed |

# Part 5 — Decisions & open questions

1. **Language for the Flex function:** recommended **Python 3.13 (v2 model)** — best docs, concise decorators, first-class Foundry SDK; Java 17/21 *is* supported on Flex Consumption now, so a Java variant is possible if you prefer staying on the original stack. → needs your call.
2. **Model:** `gpt-4o-mini` (cheapest, vision-capable, good availability in westeurope on student subscriptions) vs `gpt-4o`. Recommend gpt-4o-mini as default, param in Bicep.
3. **Result blob parity:** keep writing the JSON to the `results` blob container via an additional blob output binding (2025 behavior), or Cosmos only? Recommend keeping both bindings — it demonstrates multi-binding nicely and costs nothing.
4. **Region:** keep `westeurope` (as in 2025) — confirm availability of chosen model + Flex Consumption there during implementation.
5. **Custom Vision extra:** drop (deprecated) — confirm.

# Part 6 — Risks & notes

- **Event Grid is mandatory on Flex** for blob triggers; without the system topic/subscription the function never fires — the #1 troubleshooting item; add a portal check step in the README.
- Flex has **no remote build** → CI must build the Python package locally (`--build local`) or in a container.
- AAD propagation delay on role assignments → keep the "re-run deployment" note from 2025.
- Soft-deleted Cognitive Services accounts block re-creation with the same name → keep purge instructions.
- Responsible AI terms must be accepted per subscription before the Foundry resource can be created (student step, unchanged).
- Azure for Students: verify model quota for the chosen deployment in westeurope; fall back to another region/model if quota is 0.

# Appendix — Research sources (accessed 2026-11-14)

- Foundry SDK quickstart & SDK overview: https://learn.microsoft.com/azure/foundry/quickstarts/get-started-code · https://learn.microsoft.com/azure/foundry/how-to/develop/sdk-overview
- azure-ai-projects on PyPI (2.11.0): https://pypi.org/project/azure-ai-projects/
- Vision models: https://learn.microsoft.com/azure/foundry/openai/how-to/gpt-with-vision
- Foundry RBAC: https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry
- Model deployments (Bicep/CLI): https://learn.microsoft.com/azure/foundry/foundry-models/how-to/create-model-deployments
- Foundry IaC (accounts/projects/deployments): https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts/projects · https://techcommunity.microsoft.com/blog/azureinfrastructureblog/automating-microsoft-foundry-deployment-with-iac-leveraging-bicep-and-github-work/4412155
- Flex Consumption plan & how-to: https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan · https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to
- Supported languages: https://learn.microsoft.com/azure/azure-functions/supported-languages
- Flex IaC sample: https://github.com/Azure-Samples/azure-functions-flex-consumption-samples/tree/main/IaC/bicep
- Blob trigger (Event Grid source, Python v2): https://learn.microsoft.com/azure/azure-functions/functions-bindings-storage-blob-trigger · https://learn.microsoft.com/azure/azure-functions/functions-event-grid-blob-trigger · https://github.com/Azure-Samples/functions-quickstart-python-azd-eventgrid-blob
- Cosmos output binding: https://learn.microsoft.com/azure/azure-functions/functions-bindings-cosmosdb-v2-output
- Identity-based connections: https://learn.microsoft.com/azure/azure-functions/manage-connections
- Python v2 reference: https://learn.microsoft.com/azure/azure-functions/functions-reference-python
- Container Apps: https://learn.microsoft.com/azure/container-apps/get-started · https://learn.microsoft.com/azure/container-apps/containerapp-up · https://learn.microsoft.com/azure/container-apps/managed-identity · templates: https://learn.microsoft.com/azure/templates/microsoft.app/containerapps
- Built-in roles: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/ai-machine-learning
