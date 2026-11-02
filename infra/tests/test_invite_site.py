"""The invite domain (issue #61): CloudFront, the us-east-1 certificate, the association file and the fallback page."""

import json
import shutil
import subprocess
from typing import Any

import aws_cdk as cdk
import pytest
from aws_cdk.assertions import Match, Template

from birdjournal_infra.config import BirdJournalConfig
from birdjournal_infra.invite_site import AASA_KEY, REWRITE_INVITES, SITE_DIRECTORY, apple_app_site_association
from birdjournal_infra.stack import BirdJournalStack
from tests.conftest import CDK_JSON, INVITE_CERTIFICATE_ARN


def _only(template: Template, type_: str) -> dict[str, Any]:
    (resource,) = template.find_resources(type_).values()
    return resource


def _distribution(template: Template) -> dict[str, Any]:
    return _only(template, "AWS::CloudFront::Distribution")["Properties"]["DistributionConfig"]


def test_cloudfront_serves_the_invite_domain_with_the_us_east_1_certificate(template: Template) -> None:
    config = _distribution(template)
    assert config["Aliases"] == ["birdquest.matthewcelia.com"]
    assert config["ViewerCertificate"] == {
        "AcmCertificateArn": INVITE_CERTIFICATE_ARN,
        "MinimumProtocolVersion": "TLSv1.2_2021",
        "SslSupportMethod": "sni-only",
    }
    assert config["DefaultRootObject"] == "index.html"
    assert config["PriceClass"] == "PriceClass_100"


def test_browsers_are_sent_to_https_and_only_read(template: Template) -> None:
    behavior = _distribution(template)["DefaultCacheBehavior"]
    assert behavior["ViewerProtocolPolicy"] == "redirect-to-https"
    assert behavior["AllowedMethods"] == ["GET", "HEAD"]


def test_the_bucket_is_private_behind_origin_access_control(template: Template) -> None:
    bucket = _only(template, "AWS::S3::Bucket")["Properties"]
    assert bucket["PublicAccessBlockConfiguration"] == {
        "BlockPublicAcls": True,
        "BlockPublicPolicy": True,
        "IgnorePublicAcls": True,
        "RestrictPublicBuckets": True,
    }
    (origin,) = _distribution(template)["Origins"]
    assert "OriginAccessControlId" in origin
    template.has_resource_properties(
        "AWS::CloudFront::OriginAccessControl",
        {"OriginAccessControlConfig": Match.object_like({"OriginAccessControlOriginType": "s3", "SigningBehavior": "always"})},
    )
    statements = _only(template, "AWS::S3::BucketPolicy")["Properties"]["PolicyDocument"]["Statement"]
    allowed = [statement for statement in statements if statement["Effect"] == "Allow"]
    # Only CloudFront reads; the one statement for everyone is enforce_ssl's Deny.
    assert [statement["Principal"] for statement in allowed] == [{"Service": "cloudfront.amazonaws.com"}]
    assert all(statement["Action"] == "s3:GetObject" for statement in allowed)


def test_the_site_bucket_outlives_a_destroy(template: Template) -> None:
    bucket = _only(template, "AWS::S3::Bucket")
    assert bucket["DeletionPolicy"] == "Retain"


def test_invite_paths_are_rewritten_to_the_fallback_page_at_the_edge(template: Template) -> None:
    function = _only(template, "AWS::CloudFront::Function")
    assert function["Properties"]["FunctionConfig"]["Runtime"] == "cloudfront-js-2.0"
    (association,) = _distribution(template)["DefaultCacheBehavior"]["FunctionAssociations"]
    assert association["EventType"] == "viewer-request"


@pytest.mark.skipif(shutil.which("node") is None, reason="node runs the CloudFront function")
@pytest.mark.parametrize(
    ("uri", "served"),
    [
        ("/i/AbCdEf_123-xyz", "/invite.html"),
        ("/i/", "/invite.html"),
        ("/i", "/invite.html"),
        ("/", "/"),
        ("/index.html", "/index.html"),
        ("/style.css", "/style.css"),
        ("/.well-known/apple-app-site-association", "/.well-known/apple-app-site-association"),
        ("/invite.html", "/invite.html"),
        ("/ideas", "/ideas"),
    ],
)
def test_the_rewrite_function(uri: str, served: str) -> None:
    script = REWRITE_INVITES + f"\nconsole.log(handler({{request: {{uri: {json.dumps(uri)}}}}}).uri);"
    result = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True)
    assert result.stdout.strip() == served


def test_the_association_file_opens_invite_links_in_the_app() -> None:
    association = apple_app_site_association(["647FZYVR5Q.com.matthewcelia.mybirdjournal"])
    (detail,) = association["applinks"]["details"]  # type: ignore[index]
    assert detail["appIDs"] == ["647FZYVR5Q.com.matthewcelia.mybirdjournal"]
    assert [component["/"] for component in detail["components"]] == ["/i/*"]


def test_the_association_file_names_the_app_from_cdk_json() -> None:
    context = json.loads(CDK_JSON.read_text())["context"]
    assert context["iosAppIds"] == ["647FZYVR5Q.com.matthewcelia.mybirdjournal"]
    assert context["inviteDomain"] == "birdquest.matthewcelia.com"


def test_the_association_file_is_uploaded_as_json_and_kept_by_the_page_upload(template: Template) -> None:
    deployments = template.find_resources("Custom::CDKBucketDeployment")
    by_prune = {resource["Properties"].get("Prune", True): resource["Properties"] for resource in deployments.values()}
    association = by_prune[False]
    pages = by_prune[True]
    assert association["SystemMetadata"]["content-type"] == "application/json"
    assert association["DistributionPaths"] == [f"/{AASA_KEY}"]
    # Pruning the pages must never delete the association file.
    assert pages["Exclude"] == [AASA_KEY]
    assert pages["DistributionPaths"] == ["/*"]


def test_the_site_has_the_fallback_and_home_pages() -> None:
    names = {path.name for path in SITE_DIRECTORY.iterdir()}
    assert {"index.html", "invite.html", "style.css"} <= names
    invite = (SITE_DIRECTORY / "invite.html").read_text()
    assert "Bird Journal" in invite
    assert "seven days" in invite
    assert "https://lightsailvr.github.io/BirdJournal/" in invite


def test_the_api_makes_links_on_the_invite_domain(template: Template) -> None:
    (function,) = [
        resource
        for resource in template.find_resources("AWS::Lambda::Function").values()
        if resource["Properties"].get("Handler") == "birdjournal_api.handler.handler"
    ]
    assert function["Properties"]["Environment"]["Variables"]["INVITE_BASE_URL"] == "https://birdquest.matthewcelia.com"


def test_expired_invites_leave_the_table_by_time_to_live(template: Template) -> None:
    table = _only(template, "AWS::DynamoDB::GlobalTable")["Properties"]
    assert table["TimeToLiveSpecification"] == {"AttributeName": "ttl", "Enabled": True}


def test_the_new_resources_are_tagged(template: Template) -> None:
    for type_ in ("AWS::CloudFront::Distribution", "AWS::S3::Bucket", "AWS::CloudFront::Function"):
        for resource in template.find_resources(type_).values():
            properties = resource["Properties"]
            tags = properties.get("Tags") or properties.get("FunctionConfig", {}).get("Tags") or []
            assert {"Key": "project", "Value": "birdjournal"} in tags, type_


def test_the_stack_outputs_the_cname_target(template: Template) -> None:
    outputs = template.to_json()["Outputs"]
    (distribution,) = template.find_resources("AWS::CloudFront::Distribution")
    assert outputs["InviteDistributionDomain"]["Value"] == {"Fn::GetAtt": [distribution, "DomainName"]}
    assert outputs["InviteBaseUrl"]["Value"] == "https://birdquest.matthewcelia.com"


def _synth(**context: Any) -> None:
    app = cdk.App(context={**json.loads(CDK_JSON.read_text())["context"], "aws:cdk:bundling-stacks": [], **context})
    BirdJournalStack(
        app, "BirdJournal", config=BirdJournalConfig.from_context(app.node), env=cdk.Environment(region="us-west-2")
    )
    app.synth()


def test_the_stack_needs_the_certificate(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("INVITE_CERTIFICATE_ARN", raising=False)
    with pytest.raises(ValueError, match="INVITE_CERTIFICATE_ARN"):
        _synth(budgetAlertEmail="budget@example.com")


def test_a_certificate_outside_us_east_1_is_refused() -> None:
    with pytest.raises(Exception, match="us-east-1"):
        _synth(
            budgetAlertEmail="budget@example.com",
            inviteCertificateArn="arn:aws:acm:us-west-2:123456789012:certificate/11111111-1111-1111-1111-111111111111",
        )
