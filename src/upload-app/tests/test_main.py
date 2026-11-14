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
    monkeypatch.setattr(main, "UPLOAD_TOKEN", "test-token")

    client = TestClient(main.app)
    resp = client.post(
        "/upload",
        files={"file": ("photo.jpg", io.BytesIO(b"\xff\xd8\xff\xe0fake-jpeg-bytes"), "image/jpeg")},
        headers={"X-Upload-Token": "test-token"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["blobName"] == "photo.jpg"
    assert body["container"] == "imageanalysis"
    assert body["size"] == len(b"\xff\xd8\xff\xe0fake-jpeg-bytes")
    assert fake.container.uploads[0]["name"] == "photo.jpg"
    assert fake.container.uploads[0]["content_type"] == "image/jpeg"


def test_upload_rejects_missing_or_wrong_token(monkeypatch):
    monkeypatch.setattr(main, "get_blob_service_client", lambda: FakeBlobServiceClient())
    monkeypatch.setattr(main, "UPLOAD_TOKEN", "test-token")

    client = TestClient(main.app)
    files = {"file": ("photo.jpg", io.BytesIO(b"data"), "image/jpeg")}
    assert client.post("/upload", files=files).status_code == 401
    assert client.post("/upload", files=files, headers={"X-Upload-Token": "wrong"}).status_code == 401
    # form-field token (used by the HTML form) also accepted
    resp = client.post("/upload", files=files, data={"token": "test-token"})
    assert resp.status_code == 200


def test_upload_rejects_oversized_file(monkeypatch):
    monkeypatch.setattr(main, "get_blob_service_client", lambda: FakeBlobServiceClient())
    monkeypatch.setattr(main, "UPLOAD_TOKEN", "test-token")
    monkeypatch.setattr(main, "MAX_UPLOAD_BYTES", 4)  # tiny cap for the test

    client = TestClient(main.app)
    resp = client.post(
        "/upload",
        files={"file": ("big.jpg", io.BytesIO(b"way-more-than-4-bytes"), "image/jpeg")},
        headers={"X-Upload-Token": "test-token"},
    )
    assert resp.status_code == 413


def test_upload_rejects_empty_file(monkeypatch):
    monkeypatch.setattr(main, "get_blob_service_client", lambda: FakeBlobServiceClient())
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "sttest123")
    monkeypatch.setattr(main, "UPLOAD_TOKEN", "test-token")

    client = TestClient(main.app)
    resp = client.post(
        "/upload",
        files={"file": ("empty.jpg", io.BytesIO(b""), "image/jpeg")},
        headers={"X-Upload-Token": "test-token"},
    )
    assert resp.status_code == 400
