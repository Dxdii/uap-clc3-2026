# Implementation Plan — Modernizing the CLC3 Azure Example (uap-clc3-2026)

**Date:** 2026-11-14
**Source example:** https://github.com/juergenbr/fh-clc2025-breitenbaumer (Java 11 Consumption Function App + Logic App + Computer Vision v2.0/v3.2 + Cosmos DB)
**Working repo:** `repos/uap-clc3-2026` (this repository)

**Diagrams** (rendered by GitHub when opened): [architecture](diagrams/architecture.mermaid) · [infrastructure/Bicep](diagrams/infrastructure.mermaid) · [CI/CD](diagrams/cicd.mermaid) · [observability](diagrams/observability.mermaid)

## Goals

1. Use the **latest Azure AI services** — Microsoft Foundry (resource + project) with a deployed vision-capable model, called through the **Foundry SDK** (`azure-ai-projects`).
2. Replace the **image-upload HTTP function** (Java Function App) with an **Azure Container App**.
3. Replace the **Logic App** with a **Flex Consumption Azure Function** that:
   - takes the uploaded **blob as an input binding** (blob trigger, Event Grid source — the only supported source on Flex Consumption),
   - sends the image to the AI service via the **Foundry SDK**,
   - writes the resulting JSON into **Cosmos DB via an output binding**.

## Locked decisions (2026-11-14)

1. Flex Consumption function in **Python 3.13**, v2 programming model (`function_app.py` + decorators).
2. Model: **gpt-4o-mini** (version `2024-07-18`, deployment type **GlobalStandard**, capacity 1), deployed into the Foundry project.
3. Output: **Cosmos DB output binding only** — no result-blob output binding and no `results` blob container; the Cosmos document is the single source of truth.
4. Custom Vision "extra" section: **out of scope for now** (service deprecated; can be revisited later).
5. Budget constraint: students have **≤ ~USD 80 per subscription** (Azure for Students credit); the design must stay **well below** that — see Part 6 for the cost validation.

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
| Storage account | **StorageV2 (general-purpose v2)** required for Event Grid blob subscriptions; containers: `imageanalysis` (upload target / trigger source), plus host/deployment containers (`azure-webjobs-hosts`, deployment package container). No `results` container needed — Cosmos is the only output (locked decision) | functions-event-grid-blob-trigger |
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

Data flow: upload → blob in `imageanalysis` → BlobCreated event → Flex function → reads blob (input binding) → Foundry SDK sends image (base64 data URL; avoids SAS handling) to the deployed vision model with a prompt that returns strict JSON → function merges blob metadata (name, size, content type, URL) with the model JSON → writes one document via the **Cosmos DB output binding** (id = blob name, partition key `/filename`). Cosmos is the only output (locked decision 3).

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
├── scripts/
│   ├── preflight.sh                  (Step 0: allowed regions + quotas, see 6.5)
│   └── README.md                     (manual equivalents for every scripted check)
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
- Update `.devcontainer` (base image with Python 3.13 + Azure CLI + jq + Azure Functions Core Tools 4.x + Bicep CLI + Docker; VS Code extensions: Azure Functions, Azure Container Apps, Bicep).
- **WP0.1 — `scripts/preflight.sh` per Part 6.5**: scripted allowed-regions (Azure Policy), service-region availability (`az provider show`, `az functionapp list-flexconsumption-locations`), model quota (`az cognitiveservices usage list`, quotaTiers REST), compute quota (`az vm list-usage`); defensive (never hard-fails; prints the manual step from `scripts/README.md` when a check can't run); outputs recommended `location`. Test it on a regular (non-student) subscription — no region policy there, so the "no restriction" path must work.
- Delete/replace: `pom.xml`, `host.json` (v2 bundle), `infrastructure/logicapp_module.bicep`, `infrastructure/function_module.bicep` (Y1 consumption), `src/main/java/**`, `templates/`.

## WP1 — Infrastructure (Bicep), `infrastructure/` — see [infrastructure diagram](diagrams/infrastructure.mermaid)
1. `main.bicep` (subscription scope, params `deploymentName`, `rgName`, **`location` (single region for ALL resources — taken from the pre-flight check output in Part 6.5, NOT hard-coded; common student-viable values: `swedencentral`, `francecentral`, `eastus2`, `westeurope` if the policy allows)**, plus model params `modelName` = `gpt-4o-mini`, `modelVersion` = `2024-07-18`, `modelCapacity` = 1) → modules; outputs: function app name, container app FQDN, foundry project endpoint, cosmos endpoint, storage name.
2. `monitoring.bicep`: Log Analytics (retention 30 days) + App Insights (disableLocalAuth).
3. `storage.bicep`: StorageV2 account (`allowSharedKeyAccess: false`; all access via identity), container `imageanalysis`, deployment package container, `azure-webjobs-hosts`; **lifecycle rule** deleting blobs older than 7 days; **Event Grid system topic** on the account + **event subscription** (`endpointType: AzureFunction` → function app function `AnalyzeImage`, `includedEventTypes: Microsoft.Storage.BlobCreated`, subject filter `beginsWith /blobServices/default/containers/imageanalysis/blobs/`).
4. `foundry.bicep`: `Microsoft.CognitiveServices/accounts` `kind: AIServices`, `allowProjectManagement: true`, `disableLocalAuth: true`, `publicNetworkAccess: Enabled`; child `accounts/projects` (`displayName`); child `accounts/deployments` for the vision model (`gpt-4o-mini` 2024-07-18, `GlobalStandard`, capacity 1). Output **project endpoint** `https://<account>.services.ai.azure.com/api/projects/<project>`. Note: deployment fails fast if the student's gpt-4o-mini quota in that region is 0 TPM — README pre-flight step (Part 6.4) mitigates.
5. `cosmosdb.bicep`: **serverless** account (no RU/s baseline — Part 6), database `ImageAnalysis`, container `results` (partition key `/filename`), `sqlRoleAssignments` granting the function identity **Cosmos DB Built-in Data Contributor** at the container/database scope.
6. `function.bicep`: plan `FC1`/`FlexConsumption`; site `functionapp,linux`, system-assigned identity, `functionAppConfig`: runtime `python` / `3.13`, `scaleAndConcurrency` (**maxInstanceCount 40**, instanceMemoryMB **2048**, no always-ready), `deployment.storage` blob container + SystemAssignedIdentity; app settings:
   - `AzureWebJobsStorage__blobServiceUri/__queueServiceUri/__tableServiceUri` + `__credential: managedidentity` (host + blob trigger connection)
   - `FOUNDRY_PROJECT_ENDPOINT` = project endpoint, `FOUNDRY_MODEL_DEPLOYMENT` = deployment name
   - `COSMOS_CONNECTION__accountEndpoint` + `__credential: managedidentity`
   - `APPLICATIONINSIGHTS_CONNECTION_STRING`, `APPLICATIONINSIGHTS_AUTHENTICATION_STRING: Authorization=AAD`
   - RBAC: function identity → Storage Blob Data Owner (storage account), Cosmos DB Built-in Data Contributor (cosmos scope), **Azure AI User** (foundry project).
7. `containerapp.bicep`: Log Analytics-backed `managedEnvironments`, `Microsoft.ContainerRegistry/registries` (**Basic** — $0.1666/day, the only fixed cost), `containerApps` with system identity, ingress external targetPort 8080, `minReplicas: 0`, `maxReplicas: 3`, 0.25 vCPU/0.5 GiB, image placeholder (`<acr>.azurecr.io/upload-app:latest`), env vars `STORAGE_ACCOUNT_NAME`, `CONTAINER_NAME=imageanalysis`; RBAC: app identity → Storage Blob Data Contributor.
- Deploy: `az deployment sub create --template-file infrastructure/main.bicep --location <location>` (same UX as 2025 README; keep the "re-run if role assignment fails" note — AAD propagation delay).

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

## WP4 — CI/CD (`.github/workflows/`) — see [cicd diagram](diagrams/cicd.mermaid)
- **Auth = student's own az token, no service principal.** Students cannot create app registrations in the
  FH OOe tenant (verified 2026-11-14: `az ad app create` as p61219@fhooe.at → "Directory permission is needed
  … Insufficient privileges"). So `scripts/preflight.sh` step 6 stores the student's az CLI token store
  (base64 tar of `~/.azure/msal_token_cache.json` + `azureProfile.json`) as repo secret `AZURE_CLI_TOKENS`
  plus variables (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `RESOURCE_GROUP`, `LOCATION`, `DEPLOYMENT_NAME`)
  and secret `UPLOAD_TOKEN` in the student's fork via `gh`. Each workflow decodes the secret into
  `$HOME/.azure` on the runner (mechanism validated locally with a fresh `AZURE_CONFIG_DIR`) and runs
  `az account set`. Fork must stay private (secret = Owner creds on the student's own subscription).
- `infra-deploy.yml`: token login, `az deployment sub create` on push to main. The deployment outputs
  (`functionAppName`, `storageAccountName`, `imageContainerName`, `acrName`, `containerAppName`) are
  read back by the other workflows directly via `az deployment sub show` — CI never calls the GitHub
  variables API (GITHUB_TOKEN could not be granted `actions: write` reliably on a fresh repo —
  HTTP 403 on `actions/variables`, observed live; reading outputs from Azure avoids that entirely).
- `function-deploy.yml`: resolves `FUNCTION_APP_NAME`/`STORAGE_ACCOUNT_NAME`/`IMAGE_CONTAINER_NAME`
  from the deployment outputs, setup Python 3.13 + Core Tools, `pip install -r requirements.txt`,
  `func azure functionapp publish --build local` (runner-side build — no macOS-wheel issue), then
  create/update the Event Grid blob webhook subscription.
- `containerapp-deploy.yml`: resolves `ACR_NAME`/`CONTAINER_APP_NAME` from the deployment outputs,
  runner-side `docker build` + `docker push` to ACR with `az acr login --expose-token` (works on Basic
  SKU with the user token) + `az containerapp update --image ... --registry-server ... --registry-identity system`.
  `az acr build` (ACR Tasks) is deliberately NOT used: blocked on Azure for Students
  (`TasksOperationsNotAllowed`) and needs Standard/Premium SKU.

## WP5 — Docs & devcontainer
- Rewrite `README.md` for students:
  - prerequisites: VS Code, Docker, Azure for Students subscription, Responsible AI acknowledgement (unchanged from 2025);
  - **Step 0 — pre-flight checks (Part 6.5, mandatory)**: run `scripts/preflight.sh`; if a check can't run automatically, follow the manual instructions in `scripts/README.md` (portal Policies blade for allowed regions, portal Quotas blade, Foundry portal ai.azure.com → Management center → Quota for gpt-4o-mini TPM; request quota increase or switch region if 0). Pick the single `location` from the script output (one region for all resources); if ACA env creation fails with `AKSCapacityHeavyUsage`, redeploy in the next recommended region;
  - **set a free budget alert** (`az consumption budget create --amount 40 ...`) before deploying anything;
  - infra deploy, function deploy, container app deploy, end-to-end test (upload → Cosmos);
  - troubleshooting: Event Grid subscription health, AAD propagation on role assignments, purging soft-deleted Cognitive Services accounts, model quota errors, ACA region capacity errors;
  - **cleanup** (`az group delete --name $RG --yes --no-wait` — deletes the daily-rated ACR too).
- Keep the step-by-step portal screenshots where still valid; replace Logic App screenshots with Foundry portal + function binding view.
- Update `.devcontainer`.

## WP6 — Validation, cost & cleanup — observability: [diagram](diagrams/observability.mermaid)
- Acceptance checklist: infra deploys green; function listed in portal with blob trigger (Event Grid) enabled; upload via curl/Postman → document appears in Cosmos within seconds; App Insights shows the execution; ACA returns 200 and blob exists.
- Observability: `modules/diagnostics.bicep` routes resource logs + `AllMetrics` of storage, Event Grid system topic, Cosmos DB, ACR, Foundry account and the function app (`Microsoft.Web/sites`) into the LA workspace via `Microsoft.Insights/diagnosticSettings` (workspace local auth enabled → no extra RBAC). ACA env logs (`appLogsConfiguration` → log-analytics) and App Insights (workspace-based) already land there. Platform metrics are automatic in Azure Monitor. Foundry `RequestResponse` deliberately off (logs base64 image payloads). Cost: first 5 GB/month free + 30-day retention → $0 at exercise scale. README section "Explore observability" lists ready-to-run KQL.
- Cost validation: per Part 6 — expected spend ≈ **$3 per student with cleanup after ~14 days; ≈ $20–25 worst case if resources are left running all semester** (dominated by ACR Basic at $0.17/day; everything else is scale-to-zero/serverless/inside free grants; model ≈ $0.001/image). Well below the ~$80 student cap; >10× cheaper per day than the 2025 example (~$2/day).
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

# Part 5 — Decisions

All open questions from the first draft are now **locked** — see "Locked decisions" at the top of this document (Python 3.13 / gpt-4o-mini / Cosmos-only output / Custom Vision ignored). Remaining implementation-level choices (region, exact API versions) are parameterized in Bicep and validated in Part 6.

# Part 6 — Cost & availability validation for student subscriptions (≤ ~USD 80 cap)

Validated 2026-11-14 against Azure pricing pages, Microsoft Learn and current Microsoft Q&A reports. All prices USD list prices; westeurope ≈ East US list for the services below. Assumption for projections: **one resource group per student, exercise active ~14 days, each student uploads ~20–50 images** (a "class day" ≈ 30 students × 50 images = 1,500 images).

## 6.1 Per-component cost model

| Component | Pricing model (2026) | Free grant | Lecture-scale cost |
|---|---|---|---|
| **ACR (Basic)** — required to host the upload-app image | **$0.1666/day ≈ $5.00/month**, 10 GB incl., extra $0.10/GB-month | none | **Only fixed cost**: $0.17/day while it exists |
| **Container App (Consumption)** | per vCPU-s + GiB-s + request | **180,000 vCPU-s, 360,000 GiB-s, 2M requests/month/subscription** | scale-to-zero, minReplicas=0 → **≈ $0** (free grant far exceeds lecture traffic) |
| **Function — Flex Consumption (FC1)** | per execution + vCPU-s/GB-s during execution (~$0.000016/GB-s, min 100 ms/128 MB) | **250,000 executions + 100,000 GB-s/month/subscription** | thousands of executions → **≈ $0** (inside grant); 2 GiB × 30 s per image = 60 GB-s |
| **Foundry / gpt-4o-mini (GlobalStandard)** | input **$0.15 / 1M tokens**, output **$0.60 / 1M tokens**; image billed as input tokens (4o-family tiling: 85 base + 170 per 512px tile → ~765–1,105 tokens for a 1–2 MP photo) | none (pay per token) | ≈ **$0.0005–0.001 per image** → 1,500 images/class-day ≈ **$0.75–1.50**; even 10,000 images ≈ $5–10. Verify the exact image-input meter for gpt-4o-mini on the Azure OpenAI pricing page during implementation |
| **Cosmos DB serverless (NoSQL)** | **$0.25 per million RUs** + ~$0.25/GB-month storage | (alternative: Cosmos **free tier** 1,000 RU/s + 25 GB, one per subscription) | one doc write ≈ 10–20 RUs → **≈ $0.00**; use **serverless** (no RU/s baseline) |
| **Storage GPv2 (Hot, LRS)** | ~$0.018–0.02/GB-month; writes $0.05/10k, reads $0.004/10k | 5 GB/12 months (free account) | a few hundred MB + few thousand ops → **< $0.01/month** |
| **Event Grid** | $0.60 per million operations | **first 100,000 ops/month free** | blob events only → **≈ $0** |
| **Log Analytics / App Insights** | Analytics Logs ~$2.30/GB (regional) | **first 5 GB/month free** | function+ACA telemetry for a lecture ≈ few hundred MB → **≈ $0**; set retention 30 days |
| **Budgets/alerts (Cost Management)** | free | — | free |

## 6.2 Projection vs. the USD 80 cap

| Scenario | Cost per student |
|---|---|
| Exercise done properly (resources deleted after ~14 days) | ACR $2.50 + model ~$0.05 + rest ≈ **$0** → **≈ $3** |
| Worst case: student forgets cleanup, resources live the whole semester (~16 weeks = 112 days) | ACR $18.70 + model usage (≤ a few $ at sane usage) + storage/logs ≈ **$0.01** → **≈ $20–25** |
| 2025 example for comparison | ~$2/day → **$60+/month** if left running — dangerously close to the credit cap |

**Conclusion: the modernized design lands at ~$3 (with cleanup) to ~$25 (worst case, no cleanup) per student — comfortably below the ~$80 cap, and >10× cheaper per day than the 2025 version ($0.17/day fixed vs ~$2/day).** The single fixed cost is ACR Basic; everything else is scale-to-zero / serverless / inside monthly free grants.

## 6.3 Cost guardrails to build into the exercise

1. **One region for everything** (storage, Cosmos, Foundry, function, ACA, ACR in the same `location`) — cross-region egress is the classic hidden cost; make `location` a single Bicep param, default `westeurope`.
2. **Budget + alert (free)** at subscription level: README step with `az consumption budget create --amount 40 ...` (alerts at 50%/80%/100%, actual + forecasted) so students get an email before burning credit.
3. **Cleanup is part of the exercise**: README section + one-liner `az group delete --name $RG --yes --no-wait`; emphasize deleting the **ACR** (the only daily-rated resource).
4. ACA: `minReplicas: 0`, `maxReplicas: 3` (small), 0.25 vCPU / 0.5 GiB — idle cost $0.
5. Flex: `maximumInstanceCount: 40`, `instanceMemoryMB: 2048` (azure-ai-projects needs the memory; 512 MB would OOM), no always-ready instances.
6. Cosmos: **serverless** capability (no provisioned baseline); partition key `/filename`; optionally apply the Cosmos free tier instead (1,000 RU/s + 25 GB free, one per subscription).
7. gpt-4o-mini deployment: `sku: GlobalStandard, capacity: 1` (minimum); prompt asks for compact JSON to keep output tokens low; cap guidance in README (~a few thousand images per student is still < $10).
8. Storage: Hot LRS; **lifecycle rule** deleting blobs in `imageanalysis` older than 7 days; Event Grid subscription filtered to `Microsoft.Storage.BlobCreated` with subject `beginsWith /blobServices/default/containers/imageanalysis/blobs/`.
9. Log Analytics retention 30 days; no availability tests; sampling off (volume is tiny).
10. `disableLocalAuth: true` / `allowSharedKeyAccess: false` where possible (security, not cost) — all access via managed identity.

## 6.4 Availability validation for Azure for Students (westeurope, Nov 2026)

| Component | Status in westeurope | Student-subscription caveat | Fallback |
|---|---|---|---|
| Storage GPv2, Event Grid, ACR, Log Analytics/App Insights, Cosmos DB | available | none | — |
| Flex Consumption (FC1) | supported (verify per-subscription with `az functionapp list-flexconsumption-locations`) | none | `northeurope` |
| Container Apps | **currently capacity-constrained for NEW environments in westeurope** (`AKSCapacityHeavyUsage` / `ManagedEnvironmentCapacityHeavyUsageError`, ongoing since Feb 2026, still reported Oct–Nov 2026; centralus also affected since 30 Sep 2026) | none, but region must be chosen where env creation works | `northeurope`, `swedencentral`, `germanywestcentral` — README must include a "pick a working region" step and retry guidance |
| Foundry resource (`AIServices`) + project | available | student subscriptions have an **"Allowed resource deployment regions" Azure Policy** whose region set **varies per student subscription** (documented examples: `westeurope` for some; `eastus, eastus2, australiaeast, westus, westus3, swedencentral, francecentral, uksouth` for others) — students must discover their own set via the pre-flight check (6.5) and use an allowed region | pre-flight script/policy blade; if no Foundry-capable region is allowed, open a region-access support request |
| gpt-4o-mini GlobalStandard | model available in westeurope (region availability table, version 2024-07-18) | **default TPM quota on student subscriptions is frequently 0** in many regions and quota-increase requests are often denied on student subs; some models have default quota mainly in `swedencentral` / `eastus2` | **before** deploying infra: open Foundry portal → Models + endpoints → check quota for gpt-4o-mini in the chosen region; if 0, submit quota increase request early, or switch region/model to one with default quota |
| Responsible AI terms | required once per subscription before creating AI resources | unchanged from 2025 README | — |

**Availability conclusion:** all components are available to students in EU regions; the two real risks are (a) ACA environment creation capacity in westeurope right now, and (b) gpt-4o-mini quota = 0 on student subscriptions. Both are mitigated by making `location` a parameter with documented fallbacks and by the **pre-flight checks in 6.5** (section added 2026-11-14). If a student's allowed-regions policy excludes all Foundry-capable regions, the fallback is a region-access support request (documented in Microsoft Q&A) — not a different subscription type.

## 6.5 Pre-flight checks: allowed regions + quotas (scripted, with manual fallback)

**Why:** Azure for Students subscriptions carry an "Allowed resource deployment regions" Azure Policy whose region set **varies per student subscription** (documented examples include `westeurope` for some students, and `eastus, eastus2, australiaeast, westus, westus3, swedencentral, francecentral, uksouth` for others), and model TPM quota per region is 0 for many students. So the region must be **discovered per student before deploying**, not hard-coded.

**Testing limitation (important):** the author has no access to a student subscription, so these checks cannot be end-to-end tested by us. Consequences built into the design: (1) the script must be defensive — never abort the whole run, print a clear MANUAL step whenever a check cannot run; (2) the manual portal instructions below are the **source of truth**, the script is a convenience; (3) the script must behave sanely on a regular subscription with no region policy (report "no restriction found → all regions allowed"); (4) students validate in their own subscription as "Step 0" of the exercise.

### 6.5.1 What is automated — `scripts/preflight.sh` (bash + Azure CLI + jq, runs in the devcontainer)

1. `az login` / `az account set` sanity check.
2. **Allowed regions (policy):** find the built-in assignment at subscription scope:
   ```bash
   SUB=$(az account show --query id -o tsv)
   az policy assignment list --scope "/subscriptions/$SUB" \
     --query "[?policyDefinitionId=='/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'].{name:name,params:properties.parameters}" -o json
   # then per assignment (parameter name varies: listOfAllowedLocations or allowedLocations):
   az policy assignment show --name <name> --scope "/subscriptions/$SUB" \
     --query "parameters.listOfAllowedLocations.value // parameters.allowedLocations.value" -o tsv
   ```
   If no assignment exists → print "no region restriction policy found → all regions allowed".
3. **Service availability per region:**
   - Flex Consumption regions: `az functionapp list-flexconsumption-locations --query "[].name" -o tsv`
   - Provider region lists: `az provider show --namespace <NS> --query "resourceTypes[?resourceType=='<RT>'].locations" -o tsv` for `Microsoft.App/containerApps`, `Microsoft.Web/sites`, `Microsoft.CognitiveServices/accounts`, `Microsoft.DocumentDB/databaseAccounts`, `Microsoft.Storage/storageAccounts`, `Microsoft.EventGrid/systemTopics`, `Microsoft.ContainerRegistry/registries`, `Microsoft.OperationalInsights/workspaces`.
4. **Model quota (gpt-4o-mini TPM) per candidate region:**
   ```bash
   az cognitiveservices usage list --location <region> -o json | jq '[.[] | select(.name.value | test("gpt-4o-mini"; "i")) | {name: .name.value, used: .currentValue, limit: .limit}]'
   ```
   (requires `Cognitive Services Usages Reader` or `Reader` at subscription scope — students are Owner on their own subscription, so this works). Subscription quota tier: `az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview"`.
5. **Compute quota (informational):** `az vm list-usage --location <region> -o table`.
6. **Output:** the intersection (allowed ∩ Flex ∩ ACA ∩ CognitiveServices ∩ …) as a table, with per-region gpt-4o-mini TPM limit next to each candidate, and a final `RECOMMENDED LOCATION: <region>` line (prefer a region where gpt-4o-mini limit > 0; common working student regions: `swedencentral`, `francecentral`, `eastus2`; `westeurope` only if the policy allows it). If gpt-4o-mini limit is 0 everywhere → print the quota-increase instructions (6.5.2) and exit with a warning, not an error.

### 6.5.2 What is manual — exact student instructions (README "Step 0", source of truth)

1. **Allowed regions:** Azure portal → search `Subscriptions` → select your Azure for Students subscription → left menu **Policies** → **Assignments** → find the assignment whose display name is **"Allowed resource deployment regions"** (or "Allowed locations") → open it → under **Parameters** the `listOfAllowedLocations` value lists the allowed region names. If there is no such assignment, all regions are allowed. (CLI equivalent: the commands in 6.5.1 step 2.)
2. **Compute quotas:** portal → search `Quotas` → **Quotas** blade → pick region in the filter → review "Total regional vCPUs" etc. (CLI: `az vm list-usage --location <region>`).
3. **Model quota (gpt-4o-mini TPM per region):** sign in to **https://ai.azure.com** (Foundry portal) → **Management center** → **Quota** → the page lists per-region quota for each model; find `gpt-4o-mini` in your candidate region. Alternative: **Models + endpoints** → **Deploy model** → select gpt-4o-mini → in the region dropdown each region shows available quota. If quota is **0 TPM**: click **Request quota increase** (fill the form; on student subscriptions approval is not guaranteed — this is a known limitation) **or** switch to a region where the Quota page shows > 0 (commonly `swedencentral` / `eastus2`). (CLI equivalent: `az cognitiveservices usage list --location <region>`.)
4. **Pick the location:** choose one region that appears in **all** of: your allowed-regions policy, the Flex Consumption locations list, the Container Apps provider locations, and has gpt-4o-mini quota > 0. Use it for the single `location` parameter of the whole deployment (one region for everything — avoids egress costs). If ACA environment creation later fails with `AKSCapacityHeavyUsage`, retry the whole deployment in the next recommended region from the script output.
5. **Verify ACA capacity indirectly:** there is no API to pre-check ACA environment capacity; the failure only appears at environment creation → treat the region fallback loop in (4) as the mechanism.

### 6.5.3 Where this lives in the repo

- `scripts/preflight.sh` (+ `scripts/README.md` explaining each check and its manual equivalent), referenced as **Step 0** in the top-level `README.md`; the devcontainer ships Azure CLI + jq so it runs out of the box.

# Part 7 — Risks & notes

- **Event Grid is mandatory on Flex** for blob triggers; without the system topic/subscription the function never fires — the #1 troubleshooting item; add a portal check step in the README.
- **ACA westeurope capacity** (`AKSCapacityHeavyUsage`, ongoing since Feb 2026): README must instruct students to try `westeurope` first and fall back to `northeurope`/`swedencentral` if environment creation fails; keep everything in one region to avoid egress costs.
- **gpt-4o-mini quota on student subscriptions is often 0 TPM**: add a pre-flight step (Foundry portal → check quota; request increase early; else switch region to one with default quota, e.g. `swedencentral`/`eastus2`, or pick another model). Deployment in Bicep will fail fast with a clear quota error if quota is 0 — surface it in the README troubleshooting.
- **Student allowed-regions policy**: each Azure for Students subscription has an "Allowed resource deployment regions" policy; the README must tell students to verify their allowed regions and choose a `location` that satisfies all services.
- Flex has **no remote build** → CI must build the Python package locally (`--build local`) or in a container.
- AAD propagation delay on role assignments → keep the "re-run deployment" note from 2025.
- Soft-deleted Cognitive Services accounts block re-creation with the same name → keep purge instructions.
- Responsible AI terms must be accepted per subscription before the Foundry resource can be created (student step, unchanged).
- **Cost**: only ACR Basic is daily-rated ($0.17/day); add the free budget alert at $40 and the cleanup step — see Part 6. If a student leaves resources running all semester, worst case ≈ $20–25, still well below the ~$80 credit.
- **Pre-flight checks cannot be tested by the instructor** (no student-subscription access): `scripts/preflight.sh` is therefore defensive and the manual portal instructions in `scripts/README.md` are the source of truth; students run Step 0 in their own subscription. Test the script on a regular subscription, where the "no allowed-regions policy" path must report all regions allowed.
- **Model retirement**: gpt-4o-mini (2024-07-18) has been reported as scheduled for retirement on **2027-01-14** (verify on the official Azure OpenAI deprecations/retirements page during implementation). The model name/version are Bicep parameters (`modelName`/`modelVersion`), so switching to a successor (e.g. a gpt-5.x/gpt-6 model) later requires no code change — only a param change. If the course runs past Jan 2027, update the default param proactively.

# Appendix — Research sources (accessed 2026-11-14)

## Functional / SDK / binding docs
- (as listed in Part 1): Foundry quickstart & SDK overview, azure-ai-projects PyPI (2.11.0), gpt-with-vision, Foundry RBAC, model deployments, accounts/projects Bicep reference, TechCommunity Foundry IaC blog, Flex Consumption plan & how-to, supported languages, flex-consumption-samples Bicep, blob trigger / event-grid blob trigger + azd Python sample, Cosmos output binding, manage-connections (identity-based), Python v2 reference, Container Apps get-started / containerapp-up / managed-identity / Bicep template references, built-in roles (ai-machine-learning).

## Pricing & availability docs (Part 6)
- Container Apps billing (free grant 180k vCPU-s / 360k GiB-s / 2M requests per month): https://learn.microsoft.com/azure/container-apps/billing · product page https://azure.microsoft.com/products/container-apps
- ACR pricing (Basic $0.1666/day ≈ $5/month, 10 GB incl.): https://azure.microsoft.com/pricing/details/container-registry/
- Azure Functions pricing — Flex Consumption free grant 250,000 executions + 100,000 GB-s/month: https://azure.microsoft.com/pricing/details/functions/ · https://learn.microsoft.com/azure/azure-functions/functions-consumption-costs
- Cosmos DB serverless ($0.25/million RU, ~$0.25/GB-month) + free tier (1,000 RU/s + 25 GB per subscription): https://azure.microsoft.com/pricing/details/cosmos-db/serverless/ · https://azure.microsoft.com/pricing/free-services
- Azure OpenAI / Foundry model pricing (gpt-4o-mini $0.15/$0.60 per 1M in/out tokens; image billed as input tokens): https://azure.microsoft.com/pricing/details/azure-openai/ · image token tiling: https://developers.openai.com/api/docs/guides/images-vision
- Blob Storage pricing (Hot LRS ≈ $0.0184/GB-month first 50 TB; writes $0.05/10k, reads $0.004/10k): https://azure.microsoft.com/pricing/details/storage/blobs/
- Event Grid pricing (first 100k ops/month free, then $0.60/million): https://azure.microsoft.com/pricing/details/event-grid/
- Azure Monitor / Log Analytics (Analytics Logs ≈ $2.30/GB, first 5 GB/month free): https://azure.microsoft.com/pricing/details/monitor/ · https://learn.microsoft.com/azure/azure-monitor/logs/cost-logs
- Azure for Students ($100 credit / 12 months; allowed-regions policy): https://azure.microsoft.com/pricing/offers/ms-azr-0170p · https://learn.microsoft.com/answers/questions/5925396 (which regions work) · https://learn.microsoft.com/answers/questions/5916405 (region access / Foundry)
- Model region availability (gpt-4o-mini 2024-07-18): https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability
- Student quota reports (0 TPM for gpt-4o-mini in some regions; increases often denied on student subs; default quota in swedencentral/eastus2): https://learn.microsoft.com/answers/questions/5780281 · https://learn.microsoft.com/answers/questions/5816495 · https://learn.microsoft.com/answers/questions/5550619 · quotas doc: https://learn.microsoft.com/azure/foundry/openai/quotas-limits
- ACA westeurope capacity restriction (AKSCapacityHeavyUsage since Feb 2026, still reported Sep–Nov 2026; centralus since 30 Sep 2026): https://learn.microsoft.com/answers/questions/5816808 · https://learn.microsoft.com/answers/questions/5922755 · https://learn.microsoft.com/answers/questions/6025361
- Flex Consumption supported regions (dynamic list): `az functionapp list-flexconsumption-locations` · https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to
- Cost Management budgets (free): `az consumption budget create` · https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets

## Pre-flight check docs (Part 6.5)
- Allowed-regions policy (built-in def `e56962a6-4747-49cd-b67b-bf8b01975c4c`, param `listOfAllowedLocations`): `az policy assignment list/show --query parameters...` · https://www.azadvertizer.net/azpolicyadvertizer/e56962a6-4747-49cd-b67b-bf8b01975c4c.html · student examples of varying allowed sets: https://learn.microsoft.com/answers/questions/5917559 · https://learn.microsoft.com/answers/questions/5925396 · https://learn.microsoft.com/answers/questions/5916405
- Model quota per region: `az cognitiveservices usage list --location <region>` (needs Cognitive Services Usages Reader / Reader) · https://learn.microsoft.com/cli/azure/cognitiveservices/usage · subscription quota tier: `az rest --url ".../providers/Microsoft.CognitiveServices/quotaTiers?api-version=2025-10-01-preview"` · quota docs: https://learn.microsoft.com/azure/foundry/openai/quotas-limits · https://learn.microsoft.com/azure/foundry/how-to/quota (portal: ai.azure.com → Management center → Quota)
- Provider region lists: `az provider show --namespace <NS> --query "resourceTypes[?resourceType=='<RT>'].locations"`
- Compute quota: `az vm list-usage --location <region>` · portal Quotas blade: https://learn.microsoft.com/azure/quotas/regional-quota-requests
- Model retirement report (gpt-4o family incl. gpt-4o-mini 2024-07-18, reported shutdown 2027-01-14 — verify on official deprecations page): scriptbyai.com OpenAI rate-limits/deprecation table, Jan 2026 entry

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
