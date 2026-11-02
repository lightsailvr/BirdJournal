"""The goals' rollover schedule in the template (issue #65)."""

import json

from aws_cdk.assertions import Template

from tests.test_stack import _api_function, _resources


def _rollover_rules(template: Template) -> list[dict]:
    return [
        rule for rule in _resources(template, "AWS::Events::Rule").values()
        if "roll_over_goals" in json.dumps(rule["Properties"]["Targets"])
    ]


def test_the_goals_roll_over_every_quarter_hour_by_invoking_the_api(template: Template) -> None:
    name, _ = _api_function(template)
    (rule,) = _rollover_rules(template)
    properties = rule["Properties"]
    # On the quarter hours, so a :45 zone's midnight (Nepal) is caught at once.
    assert properties["ScheduleExpression"] == "cron(0/15 * * * ? *)"
    assert properties["State"] == "ENABLED"
    (target,) = properties["Targets"]
    assert target["Arn"] == {"Fn::GetAtt": [name, "Arn"]}
    assert json.loads(target["Input"]) == {"birdjournal_job": "roll_over_goals"}
    assert target["RetryPolicy"] == {"MaximumRetryAttempts": 0}


def test_eventbridge_may_invoke_the_api_for_the_rollover(template: Template) -> None:
    name, _ = _api_function(template)
    permissions = [
        permission for permission in _resources(template, "AWS::Lambda::Permission").values()
        if permission["Properties"].get("Principal") == "events.amazonaws.com"
    ]
    # One for the digest flush (#63), one for the rollover.
    assert len(permissions) == 2
    for permission in permissions:
        assert permission["Properties"]["FunctionName"] == {"Fn::GetAtt": [name, "Arn"]}
