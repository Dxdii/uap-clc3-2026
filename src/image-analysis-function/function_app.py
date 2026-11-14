"""AnalyzeImage — Azure Function (Flex Consumption, Python v2 programming model).

Flow:
  1. Blob trigger (Event Grid source — the only supported source on Flex
     Consumption) with the blob as an INPUT binding (SDK-type BlobClient).
  2. The image is sent to the Microsoft Foundry project via the Foundry SDK
     (azure-ai-projects 2.x) as a base64 data URL — no SAS token needed.
  3. The model returns strict JSON; merged with blob metadata it is written to
     Cosmos DB via the Cosmos DB OUTPUT binding (managed identity, no keys).

App settings (set by infrastructure/modules/function.bicep):
  AzureWebJobsStorage__*        identity-based host/trigger storage connection
  FOUNDRY_PROJECT_ENDPOINT      https://<ais>.services.ai.azure.com/api/projects/<project>
  FOUNDRY_MODEL_DEPLOYMENT      e.g. gpt-4o-mini
  COSMOS_CONNECTION__*          identity-based Cosmos DB connection

Local development (local.settings.json, see local.settings.example.json):
  omit the "__credential": "managedidentity" selectors — locally there is no
  managed-identity endpoint, so bindings fall back to DefaultAzureCredential
  (your 'az login'). The DEPLOYED app sets __credential=managedidentity.
  AzureWebJobsStorage can be UseDevelopmentStorage=true (Azurite) locally.
"""

import base64
import json
import logging
import os
from datetime import datetime, timezone

import azure.functions as func
import azurefunctions.extensions.bindings.blob as blob_ext
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

IMAGE_CONTAINER = os.getenv("IMAGE_CONTAINER_NAME", "imageanalysis")
COSMOS_DATABASE = os.getenv("COSMOS_DATABASE_NAME", "ImageAnalysis")
COSMOS_CONTAINER = os.getenv("COSMOS_CONTAINER_NAME", "results")

SYSTEM_PROMPT = """You are an image analysis service for a university exercise.
Analyze the image and respond with STRICT JSON only (no markdown, no prose) of this shape:
{
  "caption": "one-sentence description",
  "description": "short paragraph",
  "tags": [{"name": "tag", "confidence": 0.0-1.0}],
  "objects": ["object", ...],
  "colors": ["dominant color", ...]
}"""


def cosmos_safe_id(blob_name: str) -> str:
    """Cosmos DB item ids must not contain / \\ ? # (nor trailing spaces).

    Nested blob names like 'photos/photo.jpg' would otherwise fail at the
    output binding AFTER the (billable) model call already ran."""
    return (
        blob_name.replace("/", "-")
        .replace("\\", "-")
        .replace("?", "-")
        .replace("#", "-")
        .rstrip()
    )


def get_openai_client():
    """Foundry SDK client for chat completions against the project deployment."""
    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    return project.get_openai_client()


def analyze_image_bytes(openai_client, deployment_name: str, content_type: str, data: bytes) -> dict:
    """Send the image to the Foundry model and return the parsed JSON analysis."""
    data_url = f"data:{content_type or 'image/jpeg'};base64,{base64.b64encode(data).decode('ascii')}"
    response = openai_client.chat.completions.create(
        model=deployment_name,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Analyze this image and return the JSON result."},
                    {"type": "image_url", "image_url": {"url": data_url}},
                ],
            },
        ],
        temperature=0.2,
        max_tokens=800,
        response_format={"type": "json_object"},
    )
    content = response.choices[0].message.content
    return json.loads(content)


@app.function_name(name="AnalyzeImage")
@app.blob_trigger(
    arg_name="image",
    path=f"{IMAGE_CONTAINER}/{{name}}",
    connection="AzureWebJobsStorage",
    source=func.BlobSource.EVENT_GRID,
)
@app.cosmos_db_output(
    arg_name="doc",
    database_name=COSMOS_DATABASE,
    container_name=COSMOS_CONTAINER,
    connection="COSMOS_CONNECTION",
    create_if_not_exists=True,
    partition_key="/filename",
)
def analyze_image(image: blob_ext.BlobClient, doc: func.Out[func.Document]) -> None:
    logging.info("AnalyzeImage triggered for blob: %s", image.blob_name)

    props = image.get_blob_properties()
    blob_name = props.name
    content_type = props.content_settings.content_type if props.content_settings else None
    size = props.size
    data = image.download_blob().readall()

    analysis = analyze_image_bytes(
        get_openai_client(), os.environ["FOUNDRY_MODEL_DEPLOYMENT"], content_type, data
    )

    document = {
        "id": cosmos_safe_id(blob_name),  # '/' etc. are illegal in Cosmos ids
        "filename": blob_name,  # partition key (/filename) keeps the full name
        "mediatype": content_type,
        "size": size,
        "container": getattr(image, "container_name", IMAGE_CONTAINER),
        "analyzedAt": datetime.now(timezone.utc).isoformat(),
        "model": os.environ["FOUNDRY_MODEL_DEPLOYMENT"],
        "analysis": analysis,
    }
    doc.set(func.Document.from_dict(document))
    logging.info("Wrote Cosmos document id=%s", blob_name)
