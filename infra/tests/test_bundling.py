"""The Lambda package as `cdk synth` builds it on this machine: needs uv and PyPI, not Docker or AWS."""

from pathlib import Path

import pytest

from birdjournal_infra.api import UvBundling
from birdjournal_infra.stack import BACKEND_DIRECTORY


@pytest.fixture(scope="module")
def package(tmp_path_factory: pytest.TempPathFactory) -> Path:
    output = tmp_path_factory.mktemp("asset")
    assert UvBundling(BACKEND_DIRECTORY).try_bundle(str(output))
    return output


def test_the_package_has_the_handler_and_the_locked_dependencies(package: Path) -> None:
    assert (package / "birdjournal_api" / "handler.py").is_file()
    for dependency in ("fastapi", "mangum", "jwt", "pydantic_core", "cryptography"):
        assert (package / dependency).is_dir(), dependency
    assert not (package / "tests").exists()
    assert not (package / "requirements.txt").exists()


def test_compiled_dependencies_are_built_for_the_lambda_runtime(package: Path) -> None:
    (extension,) = (package / "pydantic_core").glob("_pydantic_core*.so")
    assert "aarch64-linux-gnu" in extension.name
    assert "cpython-314" in extension.name


def test_the_aws_sdk_is_left_to_the_runtime(package: Path) -> None:
    assert not (package / "boto3").exists()
    assert not (package / "botocore").exists()
