"""The Lambda entry point: API Gateway HTTP API (payload 2.0) events into the FastAPI app."""

import os

from mangum import Mangum

from birdjournal_api.app import create_app
from birdjournal_api.settings import Settings

# Built once per Lambda instance, so the JWKS cache and the boto3 client survive between invocations.
handler = Mangum(create_app(Settings.from_env(os.environ)), lifespan="off")
