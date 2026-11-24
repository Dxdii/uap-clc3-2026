"""Unit tests for the AnalyzeImage function. The Foundry SDK client and the
blob binding are faked, so no Azure access is needed."""

import json

import function_app


class FakeContentSettings:
    def __init__(self, content_type):
        self.content_type = content_type


class FakeBlobProperties:
    def __init__(self, name, size, content_type):
        self.name = name
        self.size = size
        self.content_settings = FakeContentSettings(content_type)


class FakeDownloader:
    def __init__(self, data):
        self._data = data

    def readall(self):
        return self._data


class FakeBlobClient:
    """Mimics azurefunctions.extensions.bindings.blob.BlobClient."""

    def __init__(self, name="photo.jpg", data=b"\xff\xd8\xff\xe0fake", content_type="image/jpeg"):
        self.blob_name = name
        self.container_name = "imageanalysis"
        self._props = FakeBlobProperties(name, len(data), content_type)
        self._data = data

    def get_blob_properties(self):
        return self._props

    def download_blob(self):
        return FakeDownloader(self._data)


class FakeMessage:
    def __init__(self, content):
        self.content = content


class FakeChoice:
    def __init__(self, content):
        self.message = FakeMessage(content)


class FakeChatResponse:
    def __init__(self, payload):
        self.choices = [FakeChoice(json.dumps(payload))]


class FakeCompletions:
    def __init__(self, payload):
        self._payload = payload
        self.calls = []

    def create(self, model, messages, **kwargs):
        self.calls.append({"model": model, "messages": messages, "kwargs": kwargs})
        return FakeChatResponse(self._payload)


class FakeChatClient:
    def __init__(self, payload):
        self.chat = type("Chat", (), {"completions": FakeCompletions(payload)})()


class FakeDocOut:
    """Mimics func.Out[func.Document]."""

    def __init__(self):
        self.value = None

    def set(self, document):
        self.value = document


FAKE_ANALYSIS = {
    "caption": "a red soda can on a table",
    "description": "The image shows a red aluminium can.",
    "tags": [{"name": "can", "confidence": 0.98}, {"name": "red", "confidence": 0.95}],
    "objects": ["can"],
    "colors": ["red"],
}


def test_analyze_image_writes_cosmos_document(monkeypatch):
    fake_client = FakeChatClient(FAKE_ANALYSIS)
    monkeypatch.setattr(function_app, "get_openai_client", lambda: fake_client)
    monkeypatch.setenv("FOUNDRY_MODEL_DEPLOYMENT", "gpt-4o-mini")

    doc_out = FakeDocOut()
    function_app.analyze_image(FakeBlobClient(), doc_out)

    assert doc_out.value is not None
    document = json.loads(doc_out.value.to_json() if hasattr(doc_out.value, "to_json") else json.dumps(dict(doc_out.value)))

    # Cosmos output binding requirements: id + partition key field /filename
    assert document["id"] == "photo.jpg"
    assert document["filename"] == "photo.jpg"
    assert document["mediatype"] == "image/jpeg"
    assert document["size"] == len(b"\xff\xd8\xff\xe0fake")
    assert document["model"] == "gpt-4o-mini"
    assert document["analysis"] == FAKE_ANALYSIS
    assert "analyzedAt" in document

    # the model was called with the deployment name and the image as base64 data URL
    call = fake_client.chat.completions.calls[0]
    assert call["model"] == "gpt-4o-mini"
    user_content = call["messages"][1]["content"]
    image_part = next(c for c in user_content if c["type"] == "image_url")
    assert image_part["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_analyze_image_bytes_parses_json(monkeypatch):
    fake_client = FakeChatClient(FAKE_ANALYSIS)
    result = function_app.analyze_image_bytes(fake_client, "gpt-4o-mini", "image/png", b"123")
    assert result == FAKE_ANALYSIS


def test_nested_blob_name_gets_safe_cosmos_id(monkeypatch):
    """Blob names with '/' are illegal as Cosmos item ids; filename must stay intact."""
    fake_client = FakeChatClient(FAKE_ANALYSIS)
    monkeypatch.setattr(function_app, "get_openai_client", lambda: fake_client)
    monkeypatch.setenv("FOUNDRY_MODEL_DEPLOYMENT", "gpt-4o-mini")

    doc_out = FakeDocOut()
    function_app.analyze_image(FakeBlobClient(name="photos/2026/lecture photo.jpg"), doc_out)

    document = json.loads(doc_out.value.to_json() if hasattr(doc_out.value, "to_json") else json.dumps(dict(doc_out.value)))
    assert document["id"] == "photos-2026-lecture photo.jpg"
    assert "/" not in document["id"] and "#" not in document["id"]
    assert document["filename"] == "photos/2026/lecture photo.jpg"  # partition key unchanged


def test_cosmos_safe_id_replaces_reserved_chars():
    assert function_app.cosmos_safe_id("a/b\\c?d#e ") == "a-b-c-d-e"
