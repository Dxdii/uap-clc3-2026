"""Image upload service — runs as an Azure Container App.

Accepts an image upload (multipart form) and stores it in the 'imageanalysis'
blob container. A BlobCreated event then triggers the Flex Consumption function
(src/image-analysis-function) which analyzes the image with the Foundry model
and writes the result to Cosmos DB.

Two protections against accidental cost/abuse:
  - the endpoint requires the X-Upload-Token header (shared token stored as an
    ACA secret, injected as UPLOAD_TOKEN env var) — the app has PUBLIC ingress,
    so anonymous uploads would trigger billable model calls;
  - uploads are size-limited (MAX_UPLOAD_BYTES, default 10 MB) and read in
    bounded chunks — the container only has 0.5 GiB of memory.

Authentication to Storage is via the container app's system-assigned managed
identity (DefaultAzureCredential) — no keys in code or config.

Local run:
    pip install -r requirements.txt
    az login                       # DefaultAzureCredential needs an Azure login locally
    export STORAGE_ACCOUNT_NAME=<storage account name>
    export UPLOAD_TOKEN=local-dev-token
    uvicorn main:app --port 8080
"""

import hmac
import os

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse

STORAGE_ACCOUNT_NAME = os.getenv("STORAGE_ACCOUNT_NAME", "")
CONTAINER_NAME = os.getenv("CONTAINER_NAME", "imageanalysis")
UPLOAD_TOKEN = os.getenv("UPLOAD_TOKEN", "")
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_BYTES", str(10 * 1024 * 1024)))  # 10 MB

app = FastAPI(title="CLC3 image upload", version="1.0.0")


def check_token(x_upload_token: str | None) -> None:
    """Reject unauthenticated uploads (public ingress -> billable AI calls)."""
    if not UPLOAD_TOKEN or not x_upload_token or not hmac.compare_digest(x_upload_token, UPLOAD_TOKEN):
        raise HTTPException(status_code=401, detail="missing or wrong X-Upload-Token header")


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
    <p><label>Upload token (X-Upload-Token):
       <input type="password" name="token" required></label></p>
    <input type="file" name="file" accept="image/*" required>
    <button type="submit">Upload &amp; analyze</button>
  </form>
  <p>Or from the command line:
     <code>curl -H "X-Upload-Token: &lt;token&gt;" -F "file=@image.jpg" https://&lt;app-fqdn&gt;/upload</code></p>
</body></html>"""


async def read_bounded(file: UploadFile) -> bytes:
    """Read the upload with a hard size cap (container has only 0.5 GiB RAM)."""
    if file.size is not None and file.size > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail=f"file too large (max {MAX_UPLOAD_BYTES} bytes)")
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await file.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail=f"file too large (max {MAX_UPLOAD_BYTES} bytes)")
        chunks.append(chunk)
    return b"".join(chunks)


@app.post("/upload")
async def upload(
    file: UploadFile = File(...),
    token: str | None = Form(default=None),  # HTML form posts the token as a field
    x_upload_token: str | None = Header(default=None),  # curl uses the header
) -> JSONResponse:
    check_token(x_upload_token or token)

    data = await read_bounded(file)
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
