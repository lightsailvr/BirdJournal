"""Reports, moderation and account deletion's infrastructure (issue #71): the SES identity and the API's grants, the
moderation switch, and nothing else the API gains."""

import json

import pytest
from aws_cdk.assertions import Template

from tests.conftest import BUDGET_EMAIL
from tests.test_art import _actions, _api_function, _named, _policy_statements
from tests.test_invite_site import _synth


def _template(**context: str) -> Template:
    import aws_cdk as cdk

    from birdjournal_infra.config import BirdJournalConfig
    from birdjournal_infra.stack import BirdJournalStack
    from tests.test_invite_site import CDK_JSON

    app = cdk.App(context={**json.loads(CDK_JSON.read_text())["context"], "aws:cdk:bundling-stacks": [], **context})
    stack = BirdJournalStack(
        app, "BirdJournal", config=BirdJournalConfig.from_context(app.node), env=cdk.Environment(region="us-west-2")
    )
    return Template.from_stack(stack)


def _grants(template: Template) -> dict[str, list[str]]:
    role = _api_function(template)["Properties"]["Role"]["Fn::GetAtt"][0]
    by_action: dict[str, list[str]] = {}
    for statement in _policy_statements(template, role=role):
        for action in _actions(statement):
            by_action.setdefault(action, []).append(json.dumps(statement["Resource"]))
    return by_action


def test_no_ses_identity_in_the_stack(template: Template) -> None:
    # The address's domain is a verified identity outside the stack; the wizard checks it.
    assert template.find_resources("AWS::SES::EmailIdentity") == {}


def test_the_api_sends_only_as_the_report_address_or_its_domain(template: Template) -> None:
    (resource,) = _grants(template)["ses:SendEmail"]
    domain = BUDGET_EMAIL.rpartition("@")[2]
    assert f"identity/{domain}" in resource and f"identity/{BUDGET_EMAIL}" in resource
    assert resource.count("identity/") == 2


def test_the_api_reads_pictures_for_moderation_and_nothing_wider(template: Template) -> None:
    grants = _grants(template)
    assert grants["rekognition:DetectModerationLabels"] == ['"*"']
    uploads, _ = _named(template, "AWS::S3::Bucket", "ArtJobsUploads")
    art, _ = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    reads = grants["s3:GetObject"]
    assert any(uploads in r and "/uploads/*" in r for r in reads)
    assert any(art in r and "/art/*" in r for r in reads)
    assert all("/uploads/*" in r or "/art/*" in r or "/photos/*" in r for r in reads)


def test_the_api_deletes_cognito_users_of_its_own_pool_and_reads_the_apple_key(template: Template) -> None:
    grants = _grants(template)
    pool, _ = _named(template, "AWS::Cognito::UserPool", "AuthUserPool")
    (resource,) = grants["cognito-idp:AdminDeleteUser"]
    assert pool in resource
    assert any("birdjournal/apple-sign-in" in r for r in grants["secretsmanager:GetSecretValue"])
    assert not [action for action in grants if action.startswith("cognito-idp:") and action != "cognito-idp:AdminDeleteUser"]


def test_the_api_environment(template: Template) -> None:
    variables = _api_function(template)["Properties"]["Environment"]["Variables"]
    assert variables["REPORT_EMAIL"] == BUDGET_EMAIL
    assert variables["MODERATION"] == "off"
    assert variables["APPLE_SIGN_IN_SECRET_NAME"] == "birdjournal/apple-sign-in"
    assert variables["APPLE_CLIENT_ID"] == "com.matthewcelia.mybirdjournal"


def test_moderation_and_the_report_address_are_context_switches() -> None:
    template = _template(
        budgetAlertEmail="b@example.com", inviteCertificateArn="arn:aws:acm:us-east-1:1:certificate/x",
        moderation="on", reportEmail="reports@example.com",
    )
    variables = _api_function(template)["Properties"]["Environment"]["Variables"]
    assert (variables["MODERATION"], variables["REPORT_EMAIL"]) == ("on", "reports@example.com")


def test_an_unknown_moderation_switch_is_refused() -> None:
    with pytest.raises(ValueError, match="moderation"):
        _synth(budgetAlertEmail="b@example.com", inviteCertificateArn="arn:aws:acm:us-east-1:1:certificate/x", moderation="yes")
