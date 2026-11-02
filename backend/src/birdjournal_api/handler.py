"""The Lambda entry point: API Gateway HTTP API (payload 2.0) events into the FastAPI app, and the scheduled jobs.

The digest flush (issue #63) is an EventBridge schedule invoking this function directly with
`{"birdjournal_job": "flush_digests"}`, not an HTTP route: only EventBridge may invoke the function that way (its
resource policy), so there is no shared secret to keep and nothing internal on the public API.
"""

import json
import logging
import os
from collections.abc import Callable
from dataclasses import asdict
from typing import Any

from fastapi import FastAPI
from mangum import Mangum

from birdjournal_api.app import create_app
from birdjournal_api.settings import Settings

log = logging.getLogger(__name__)

JOB_KEY = "birdjournal_job"


def make_handler(app: FastAPI) -> Callable[[dict[str, Any], Any], Any]:
    http = Mangum(app, lifespan="off")

    def handle(event: dict[str, Any], context: Any) -> Any:
        job = event.get(JOB_KEY) if isinstance(event, dict) else None
        if job == "flush_digests":
            # The same schedule sends the reaction pushes whose 10-minute window has closed (issue #64).
            report = {**asdict(app.state.pushes.flush_digests()), "reactions": asdict(app.state.reactions.flush())}
            log.info("digest flush: %s", json.dumps(report))
            return report
        if job is not None:
            raise ValueError(f"unknown job {job!r}")
        return http(event, context)

    return handle


# Built once per Lambda instance, so the JWKS cache, the APNs connection and the boto3 clients survive between
# invocations. Only when running in Lambda: the tests build their own app.
handler = make_handler(create_app(Settings.from_env(os.environ))) if "TABLE_NAME" in os.environ else None
