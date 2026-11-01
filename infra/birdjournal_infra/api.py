import shutil
import subprocess
from pathlib import Path
from typing import Any

import jsii
from aws_cdk import BundlingOptions, Duration, ILocalBundling, RemovalPolicy
from aws_cdk import aws_apigatewayv2 as apigateway
from aws_cdk import aws_apigatewayv2_integrations as integrations
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_logs as logs
from constructs import Construct

RUNTIME = lambda_.Runtime.PYTHON_3_14
ARCHITECTURE = lambda_.Architecture.ARM_64
# A ceiling on what a runaway client can cost: requests above it get 429 from API Gateway, not a Lambda bill.
THROTTLE_RATE_PER_SECOND = 25
THROTTLE_BURST = 50
RUNTIME_PROVIDED = ("boto3", "botocore", "s3transfer", "jmespath", "python-dateutil", "six", "urllib3")


@jsii.implements(ILocalBundling)
class UvBundling:
    """Builds the Lambda package on this machine with uv, no Docker: the locked dependencies as manylinux
    ARM64 wheels for the Lambda runtime's Python, then the birdjournal_api package beside them."""

    def __init__(self, backend: Path) -> None:
        self._backend = backend

    def try_bundle(self, output_dir: str, *, image: Any = None, **_: Any) -> bool:
        if shutil.which("uv") is None:
            return False
        requirements = Path(output_dir) / "requirements.txt"
        subprocess.run(
            ["uv", "export", "--project", str(self._backend), "--frozen", "--no-dev", "--no-emit-project",
             "--no-hashes", "--quiet", "--output-file", str(requirements),
             # The Lambda runtime has the AWS SDK already; leaving it out halves the package.
             *[flag for package in RUNTIME_PROVIDED for flag in ("--no-emit-package", package)]],
            check=True,
        )
        python_version = RUNTIME.name.removeprefix("python")
        subprocess.run(
            ["uv", "pip", "install", "--quiet", "--requirement", str(requirements), "--target", output_dir,
             "--python-platform", "aarch64-manylinux2014", "--python-version", python_version,
             "--only-binary", ":all:"],
            check=True,
        )
        requirements.unlink()
        shutil.copytree(
            self._backend / "src" / "birdjournal_api",
            Path(output_dir) / "birdjournal_api",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        return True


class Api(Construct):
    """FastAPI on Lambda behind an API Gateway HTTP API (ADR-0002). The app verifies the Cognito access token
    itself (birdjournal_api.auth), so every route but /health needs one and the harness tests that path."""

    def __init__(
        self, scope: Construct, id: str, *, backend: Path, environment: dict[str, str]
    ) -> None:
        super().__init__(scope, id)

        log_group = logs.LogGroup(
            self, "Logs", retention=logs.RetentionDays.ONE_MONTH, removal_policy=RemovalPolicy.DESTROY
        )
        self.function = lambda_.Function(
            self,
            "Function",
            runtime=RUNTIME,
            architecture=ARCHITECTURE,
            handler="birdjournal_api.handler.handler",
            code=lambda_.Code.from_asset(
                str(backend),
                exclude=[".venv", ".pytest_cache", "**/__pycache__", "tests"],
                bundling=BundlingOptions(
                    image=RUNTIME.bundling_image,
                    platform="linux/arm64",
                    local=UvBundling(backend),
                    # Without uv on the host: the same install inside the runtime's build image.
                    command=["bash", "-c", "pip install --quiet . --target /asset-output"],
                ),
            ),
            memory_size=512,
            timeout=Duration.seconds(10),
            environment=environment,
            log_group=log_group,
        )

        self.http_api = apigateway.HttpApi(
            self,
            "HttpApi",
            description="BirdJournal API",
            default_integration=integrations.HttpLambdaIntegration("Lambda", self.function),
        )
        stage = self.http_api.default_stage
        assert stage is not None
        cfn_stage: apigateway.CfnStage = stage.node.default_child  # type: ignore[assignment]
        cfn_stage.default_route_settings = apigateway.CfnStage.RouteSettingsProperty(
            throttling_rate_limit=THROTTLE_RATE_PER_SECOND, throttling_burst_limit=THROTTLE_BURST
        )
        self.url = self.http_api.api_endpoint
