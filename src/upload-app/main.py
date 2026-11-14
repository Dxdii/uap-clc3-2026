"""Image upload service — runs as an Azure Container App.

Accepts an image upload (multipart form or raw body) and stores it in the
'imageanalysis' blob container. A BlobCreated event then triggers the
Flex Consumption function (src/image-analysis-function) which analyzes the
image with the Foundry model and writes the result to Cosmos DB.

Authentication to Storage is via the container app's system-assigned managed
identity (DefaultAzureCredential) — no keys in code or config.

Local run:
    pip install -r requirements.txt
    az login                       # DefaultAzureCredential needs an Azure login locally
    export STORAGE_ACCOUNT_NAME=<storage account name>
    uvicorn main:app --port 8080
"""

import os

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse

STORAGE_ACCOUNT_NAME = os.getenv("STORAGE_ACCOUNT_NAME", "")
CONTAINER_NAME = os.getenv("CONTAINER_NAME", "imageanalysis")

app = FastAPI(title="CLC3 image upload", version="1.0.0")


def get_blob_service_client() -> BlobServiceClient:
    if not STORAGE_ACCOUNT_NAME:
        raise RuntimeError("STORAGE_ACCOUNT_NAME environment variable is not set")
    account_url = f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net"
    return BlobServiceClient(account_url=account_url, credential=DefaultAzureCredential())


@app.get("/health")
def health() -> JSONResponse:
    return JSONResponse({"status": "ok"})


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return """<!doctype html>
<html><head><title>CLC3 image upload</title></head>
<body style="font-family:sans-serif;max-width:32rem;margin:3rem auto">
  <h1>Upload an image for AI analysis</h1>
  <form method="post" action="/upload" enctype="multipart/form-data">
    <input type="file" name="file" accept="image/*" required>
    <button type="submit">Upload &amp; analyze</button>
  </form>
  <p>Or from the command line:
     <code>curl -F "file=@image.jpg" https://&lt;app-fqdn&gt;/upload</code></p>
</body></html>"""


@app.post("/upload")
async def upload(file: UploadFile = File(...)) -> JSONResponse:
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty file")

    blob_name = file.filename or "upload.jpg"
    content_type = file.content_type or "application/octet-stream"

    try:
        container = get_blob_service_client().get_container_client(CONTAINER_NAME)
        container.upload_blob(
            name=blob_name,
            data=data,
            overwrite=True,
            content_settings=ContentSettings(content_type=content_type),
        )
    except Exception as exc:  # surfaced to the caller as a 502
        raise HTTPException(status_code=502, detail=f"blob upload failed: {exc}") from exc

    return JSONResponse(
        {
            "blobName": blob_name,
            "container": CONTAINER_NAME,
            "size": len(data),
            "message": "uploaded — the image will be analyzed automatically and the result stored in Cosmos DB",
        }
    )
