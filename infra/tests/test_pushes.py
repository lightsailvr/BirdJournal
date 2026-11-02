"""Pushes in the template (issue #63): the APNs key's secret from the wizard, and the digest flush's schedule."""

import json
from typing import Any

from aws_cdk.assertions import Match, Template

from tests.test_stack import _api_function, _resources


def _statements(template: Template) -> list[dict[str, Any]]:
    return [
        statement
        for policy in _resources(template, "AWS::IAM::Policy").values()
        for statement in policy["Properties"]["PolicyDocument"]["Statement"]
    ]


def test_the_api_knows_the_key_s_secret_and_the_topic(template: Template) -> None:
    _, function = _api_function(template)
    environment = function["Properties"]["Environment"]["Variables"]
    assert environment["APNS_SECRET_NAME"] == "birdjournal/apns"
    assert environment["APNS_TOPIC"] == "com.matthewcelia.mybirdjournal"


def test_the_api_may_read_the_key_s_secret_and_no_other(template: Template) -> None:
    reads = [
        statement for statement in _statements(template)
        if "secretsmanager:GetSecretValue" in json.dumps(statement["Action"])
    ]
    apns = [statement for statement in reads if "birdjournal/apns-??????" in json.dumps(statement["Resource"])]
    assert len(apns) == 1
    # The secret lives outside the stack: no Secret resource is made for it.
    for secret in _resources(template, "AWS::SecretsManager::Secret").values():
        assert secret["Properties"].get("Name") != "birdjournal/apns"


def test_the_digests_flush_every_15_minutes_by_invoking_the_api(template: Template) -> None:
    name, _ = _api_function(template)
    template.has_resource_properties(
        "AWS::Events::Rule",
        {
            "ScheduleExpression": "rate(15 minutes)",
            "State": "ENABLED",
            "Targets": [
                Match.object_like(
                    {
                        "Arn": {"Fn::GetAtt": [name, "Arn"]},
                        "Input": json.dumps({"birdjournal_job": "flush_digests"}, separators=(",", ":")),
                        "RetryPolicy": {"MaximumRetryAttempts": 0},
                    }
                )
            ],
        },
    )
    template.has_resource_properties(
        "AWS::Lambda::Permission",
        {"Action": "lambda:InvokeFunction", "Principal": "events.amazonaws.com", "FunctionName": {"Fn::GetAtt": [name, "Arn"]}},
    )
