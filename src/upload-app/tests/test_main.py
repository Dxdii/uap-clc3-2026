"""Unit tests for the upload app. The BlobServiceClient is replaced by a fake,
so no Azure access is needed."""

import io

import main
from fastapi.testclient import TestClient


class FakeContainerClient:
    def __init__(self):
        self.uploads = []

    def upload_blob(self, name, data, overwrite, content_settings):
        self.uploads.append({"name": name, "data": data, "content_type": content_settings.content_type})


class FakeBlobServiceClient:
    def __init__(self):
        self.container = FakeContainerClient()

    def get_container_client(self, name):
        assert name == main.CONTAINER_NAME
        return self.container


def test_health():
    client = TestClient(main.app)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_index_returns_form():
    client = TestClient(main.app)
    resp = client.get("/")
    assert resp.status_code == 200
    assert "multipart/form-data" in resp.text


def test_upload_stores_blob(monkeypatch):
    fake = FakeBlobServiceClient()
    monkeypatch.setattr(main, "get_blob_service_client", lambda: fake)
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "sttest123")

    client = TestClient(main.app)
    resp = client.post(
        "/upload",
        files={"file": ("photo.jpg", io.BytesIO(b"\xff\xd8\xff\xe0fake-jpeg-bytes"), "image/jpeg")},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["blobName"] == "photo.jpg"
    assert body["container"] == "imageanalysis"
    assert body["size"] == len(b"\xff\xd8\xff\xe0fake-jpeg-bytes")
    assert fake.container.uploads[0]["name"] == "photo.jpg"
    assert fake.container.uploads[0]["content_type"] == "image/jpeg"


def test_upload_rejects_empty_file(monkeypatch):
    monkeypatch.setattr(main, "get_blob_service_client", lambda: FakeBlobServiceClient())
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "sttest123")

    client = TestClient(main.app)
    resp = client.post("/upload", files={"file": ("empty.jpg", io.BytesIO(b""), "image/jpeg")})
    assert resp.status_code == 400
