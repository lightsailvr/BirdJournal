"""The in-process API test harness (issue #60): FastAPI against DynamoDB Local, with tokens signed by a test key.

Every backend test goes through `client`. DynamoDB Local runs in a container for the session (or point
DYNAMODB_ENDPOINT at one already running, e.g. `docker run -p 8000:8000 amazon/dynamodb-local`); each test gets
its own freshly created table, so tests never see each other's items.
"""

import os
from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

import boto3
import pytest
from fastapi.testclient import TestClient
from testcontainers.core.container import DockerContainer
from testcontainers.core.wait_strategies import LogMessageWaitStrategy

from birdjournal_api.app import create_app
from birdjournal_api.devices import Device
from birdjournal_api.pushes import Push, SendResult
from birdjournal_api.settings import Settings
from birdjournal_api.tables import create_table
from tests.tokens import CLIENT_ID, ISSUER, TestIssuer

DYNAMODB_LOCAL_IMAGE = "amazon/dynamodb-local:latest"
REGION = "us-west-2"

# The Ryuk reaper mounts the Docker socket as seen from inside the Docker VM (Colima, Docker Desktop),
# not the host-side path in DOCKER_HOST.
os.environ.setdefault("TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE", "/var/run/docker.sock")
# DynamoDB Local accepts any credentials, but boto3 refuses to sign without some.
os.environ.setdefault("AWS_ACCESS_KEY_ID", "local")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "local")


@pytest.fixture(scope="session")
def dynamodb_endpoint() -> Iterator[str]:
    if endpoint := os.environ.get("DYNAMODB_ENDPOINT"):
        yield endpoint
        return
    container = (
        DockerContainer(DYNAMODB_LOCAL_IMAGE)
        .with_command("-jar DynamoDBLocal.jar -inMemory -sharedDb")
        .with_exposed_ports(8000)
        .waiting_for(LogMessageWaitStrategy("Initializing DynamoDB Local"))
    )
    with container:
        yield f"http://{container.get_container_host_ip()}:{container.get_exposed_port(8000)}"


@pytest.fixture
def table_name(dynamodb_endpoint: str) -> Iterator[str]:
    name = f"birdjournal-test-{uuid4().hex[:12]}"
    resource = boto3.resource("dynamodb", endpoint_url=dynamodb_endpoint, region_name=REGION)
    create_table(resource, name)
    yield name
    resource.Table(name).delete()


@pytest.fixture
def table(table_name: str, dynamodb_endpoint: str) -> Any:
    """The test's table, for checking what the API wrote."""
    return boto3.resource("dynamodb", endpoint_url=dynamodb_endpoint, region_name=REGION).Table(table_name)


@pytest.fixture
def issuer() -> TestIssuer:
    return TestIssuer()


@pytest.fixture
def settings(table_name: str, dynamodb_endpoint: str) -> Settings:
    return Settings(
        table_name=table_name,
        cognito_issuer=ISSUER,
        cognito_client_ids=frozenset({CLIENT_ID}),
        region=REGION,
        dynamodb_endpoint=dynamodb_endpoint,
    )


class Clock:
    """The time the API stamps on what it writes; tests move it by hand."""

    def __init__(self) -> None:
        self.now = datetime(2026, 11, 1, 9, 30, tzinfo=UTC)

    def __call__(self) -> datetime:
        return self.now


@pytest.fixture
def clock() -> Clock:
    return Clock()


class FakeApns:
    """Records what the API asked APNs to send (issue #63). Tokens in `gone` answer as unregistered."""

    def __init__(self) -> None:
        self.sent: list[tuple[Device, Push]] = []
        self.gone: set[str] = set()

    def send(self, device: Device, push: Push) -> SendResult:
        if device.token in self.gone:
            return SendResult.GONE
        self.sent.append((device, push))
        return SendResult.SENT

    def to(self, token: str) -> list[Push]:
        return [push for device, push in self.sent if device.token == token]

    def clear(self) -> None:
        self.sent.clear()


@pytest.fixture
def apns() -> FakeApns:
    return FakeApns()


@pytest.fixture
def client(settings: Settings, issuer: TestIssuer, clock: Clock, apns: FakeApns) -> Iterator[TestClient]:
    app = create_app(settings, signing_key=issuer.signing_key, clock=clock, push_sender=apns)
    with TestClient(app) as client:
        yield client
