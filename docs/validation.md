# Validation log (2026-11-14)

What was executed and verified while implementing this repo. No production resources
were created; the only write was a temporary empty resource group used for server-side
what-if validation (deleted again afterwards).

## Infrastructure (Bicep)

| Check | Command | Result |
|---|---|---|
| Local compile (Bicep CLI 0.49.2) | `bicep build infrastructure/main.bicep` | PASS, 0 errors (only informational linter notes) |
| Server-side validation + change preview (read-only) | `az deployment sub what-if --location westeurope --template-file infrastructure/main.bicep --parameters rgName=... location=westeurope` | PASS — "22 to create", all resource types accepted (incl. FC1 plan, Flex `functionAppConfig`, Event Grid subscription, project-scoped model deployment) |

Two real issues were found and fixed via what-if:

1. Model deployments must be **project-scoped** child resources
   (`Microsoft.CognitiveServices/accounts/projects/deployments@2025-06-01`); account-level
   deployments fail RP preflight when the account is created in the same deployment.
2. The deployment SKU is the **top-level `sku`** (`{ name: 'GlobalStandard', capacity: 1 }`);
   `properties.scaleSettings.scaleType` rejects `GlobalStandard` server-side.

## Pre-flight script

| Check | Result |
|---|---|
| `bash -n scripts/preflight.sh` | PASS |
| jq intersection logic (unit-tested with sample region lists) | PASS |
| Full run against a real non-student subscription (Pay-As-You-Go Dev/Test) | PASS — correctly reported "no allowed-regions policy → all regions allowed", computed 33 candidate regions (allowed ∩ Flex ∩ ContainerApps ∩ AI ∩ core), probed `az cognitiveservices usage list` per region (gpt-4o-mini GlobalStandard quota, e.g. swedencentral 2000 K TPM), printed `RECOMMENDED LOCATION: swedencentral` |
| Defensive behavior | PASS — when run against an inaccessible student subscription it printed the MANUAL fallback steps instead of crashing |

Note: the two "Azure for Students" subscriptions visible in this CLI session were not
API-accessible (SubscriptionNotFound), so the student-policy path could only be tested
via the graceful-fallback branch. The manual instructions in `scripts/README.md` remain
the source of truth for students.

## Python code

| Check | Result |
|---|---|
| Upload app unit tests | `pytest src/upload-app/tests` — **6 passed** (health, index form, upload stores blob w/ mocked BlobServiceClient, 401 missing/wrong token, 413 oversize, empty-file 400) |
| Function unit tests | `pytest src/image-analysis-function/tests` — **4 passed** (Cosmos document structure incl. id + /filename partition key + analysis JSON; Foundry call shape with image as base64 data URL; Cosmos id sanitization for nested blob names) |
| Package versions | all pins in `requirements*.txt` verified against PyPI on 2026-11-14 (azure-ai-projects 2.11.0, azure-functions 2.4.0, azurefunctions-extensions-bindings-blob 1.1.2, fastapi 0.162.7, ...) |
| YAML/JSON configs | workflows, host.json, local.settings.example.json, devcontainer.json all parse |

## GitHub Copilot code reviews (PR #1, 4 rounds, one per implementation phase)

Copilot reviewed the PR after each phase push. Findings were fixed in follow-up commits on the
same branch and the review threads resolved:

| Round | Phase | Findings | Fix commit |
|---|---|---|---|
| 1 | infrastructure + preflight | 11 (missing `dependsOn: [rg]`, Cosmos sqlRoleDefinition id + `/dbs/…` scope, plaintext workspace key, ACR pull identity, Event Grid endpoint, queue-data role, preflight unknown-state/union/quota/retry issues) | `0d2e5ff` |
| 2 | function code | 5 new + 2 previously missed (blob webhook endpoint vs azurefunction, nested-deployment name, jq substring membership, nested blob names as Cosmos ids, local managedidentity) | `d54d627` |
| 3 | upload app + workflows + devcontainer | 7 (docker-cli package, placeholder image port, image reset on infra redeploy, policy response shapes, anonymous uploads, unbounded upload size, deployer RBAC role) | `6dc950d` |
| 4 | docs (this README/validation) | see PR #1 review thread | — |

Notable verified-against-docs decision: an Event-Grid-sourced **blob** trigger is fed by a **webhook**
endpoint (`/runtime/webhooks/blobs?functionName=Host.Functions.<fn>&code=<blobs_extension key>`),
not an `azurefunction` endpoint (that is only for EventGrid-*trigger* functions) — per Microsoft Learn.

## Not validated here (needs Azure / Docker daemon)

* `docker build src/upload-app` — Docker daemon was not running in this environment; the
  image is built in CI via `az acr build` (containerapp-deploy.yml).
* `func azure functionapp publish --build local` — Azure Functions Core Tools not installed
  here; exercised in the devcontainer / function-deploy.yml.
* Real end-to-end deployment to a student subscription (no accessible student subscription
  in this environment) — this is what students do; see README step 3 (pre-flight) and 4–7.
