"""The invite domain (issues #61, #150): CloudFront, the us-east-1 certificate, the association file, the fallback page
and the former host's redirects."""

import json
import re
import shutil
import subprocess
from typing import Any

import aws_cdk as cdk
import pytest
from aws_cdk.assertions import Match, Template

from birdjournal_infra.config import BirdJournalConfig
from birdjournal_infra.invite_site import AASA_KEY, SITE_DIRECTORY, apple_app_site_association, viewer_request_code
from birdjournal_infra.stack import BirdJournalStack
from tests.conftest import CDK_JSON, INVITE_CERTIFICATE_ARN

NEW_HOST = "featherguild.matthewcelia.com"
OLD_HOST = "birdquest.matthewcelia.com"


def _only(template: Template, type_: str) -> dict[str, Any]:
    (resource,) = template.find_resources(type_).values()
    return resource


def _invite(template: Template, type_: str) -> dict[str, Any]:
    """The invite site's one resource of a type; the art CDN (#68) has its own bucket and distribution."""
    (resource,) = [resource for name, resource in template.find_resources(type_).items() if name.startswith("InviteSite")]
    return resource


def _distribution(template: Template) -> dict[str, Any]:
    return _invite(template, "AWS::CloudFront::Distribution")["Properties"]["DistributionConfig"]


def test_cloudfront_serves_the_invite_domain_with_the_us_east_1_certificate(template: Template) -> None:
    config = _distribution(template)
    # The former host stays on the distribution for good: old invite links and QR codes still point at it.
    assert config["Aliases"] == [NEW_HOST, OLD_HOST]
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
    bucket = _invite(template, "AWS::S3::Bucket")["Properties"]
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
    statements = _invite(template, "AWS::S3::BucketPolicy")["Properties"]["PolicyDocument"]["Statement"]
    allowed = [statement for statement in statements if statement["Effect"] == "Allow"]
    # Only CloudFront reads; the one statement for everyone is enforce_ssl's Deny.
    assert [statement["Principal"] for statement in allowed] == [{"Service": "cloudfront.amazonaws.com"}]
    assert all(statement["Action"] == "s3:GetObject" for statement in allowed)


def test_the_site_bucket_outlives_a_destroy(template: Template) -> None:
    bucket = _invite(template, "AWS::S3::Bucket")
    assert bucket["DeletionPolicy"] == "Retain"


def test_invite_paths_are_rewritten_to_the_fallback_page_at_the_edge(template: Template) -> None:
    function = _only(template, "AWS::CloudFront::Function")
    assert function["Properties"]["FunctionConfig"]["Runtime"] == "cloudfront-js-2.0"
    (association,) = _distribution(template)["DefaultCacheBehavior"]["FunctionAssociations"]
    assert association["EventType"] == "viewer-request"


def _viewer_request(uri: str, host: str = NEW_HOST, query: dict[str, Any] | None = None) -> dict[str, Any]:
    """What the CloudFront function answers, run in node over the event CloudFront gives it."""
    event = {"request": {"uri": uri, "querystring": query or {}, "headers": {"host": {"value": host}}}}
    script = viewer_request_code(NEW_HOST, [OLD_HOST]) + f"\nconsole.log(JSON.stringify(handler({json.dumps(event)})));"
    result = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


needs_node = pytest.mark.skipif(shutil.which("node") is None, reason="node runs the CloudFront function")


@needs_node
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
        ("/privacy", "/privacy.html"),
        ("/privacy/", "/privacy.html"),
        ("/terms", "/terms.html"),
        ("/privacy.html", "/privacy.html"),
        ("/i/privacy", "/invite.html"),
    ],
)
def test_the_new_host_serves_its_pages(uri: str, served: str) -> None:
    assert _viewer_request(uri)["uri"] == served


@needs_node
@pytest.mark.parametrize(
    ("uri", "query", "location"),
    [
        ("/i/AbCdEf_123-xyz", {}, f"https://{NEW_HOST}/i/AbCdEf_123-xyz"),
        ("/privacy", {}, f"https://{NEW_HOST}/privacy"),
        ("/terms", {}, f"https://{NEW_HOST}/terms"),
        ("/", {}, f"https://{NEW_HOST}/"),
        ("/style.css", {}, f"https://{NEW_HOST}/style.css"),
        ("/.well-known/other", {}, f"https://{NEW_HOST}/.well-known/other"),
        ("/i/abc", {"a": {"value": "1%202"}, "flag": {"value": ""}}, f"https://{NEW_HOST}/i/abc?a=1%202&flag"),
        (
            "/i/abc",
            {"a": {"value": "1", "multiValue": [{"value": "1"}, {"value": "2"}]}},
            f"https://{NEW_HOST}/i/abc?a=1&a=2",
        ),
    ],
)
def test_the_old_host_redirects_to_the_same_path_on_the_new_host(uri: str, query: dict[str, Any], location: str) -> None:
    response = _viewer_request(uri, host=OLD_HOST, query=query)
    assert response["statusCode"] == 301
    assert response["headers"]["location"]["value"] == location


@needs_node
def test_the_old_host_serves_the_association_file_without_a_redirect() -> None:
    """Apple doesn't follow redirects for this file, and a phone with an old app still asks the old host for it."""
    answer = _viewer_request("/.well-known/apple-app-site-association", host=OLD_HOST)
    assert "statusCode" not in answer
    assert answer["uri"] == "/.well-known/apple-app-site-association"


@needs_node
def test_a_host_header_in_capitals_is_still_the_old_host() -> None:
    assert _viewer_request("/privacy", host=OLD_HOST.upper())["statusCode"] == 301


@needs_node
def test_cloudfronts_own_name_keeps_serving_the_pages() -> None:
    assert _viewer_request("/i/abc", host="d111111abcdef8.cloudfront.net")["uri"] == "/invite.html"


def test_the_deployed_function_knows_both_hosts(template: Template) -> None:
    code = _only(template, "AWS::CloudFront::Function")["Properties"]["FunctionCode"]
    assert NEW_HOST in code
    assert OLD_HOST in code


def test_the_association_file_opens_invite_links_in_the_app() -> None:
    association = apple_app_site_association(["647FZYVR5Q.com.matthewcelia.mybirdjournal"])
    (detail,) = association["applinks"]["details"]  # type: ignore[index]
    assert detail["appIDs"] == ["647FZYVR5Q.com.matthewcelia.mybirdjournal"]
    assert [component["/"] for component in detail["components"]] == ["/i/*"]


def test_the_association_file_names_the_app_from_cdk_json() -> None:
    context = json.loads(CDK_JSON.read_text())["context"]
    assert context["iosAppIds"] == ["647FZYVR5Q.com.matthewcelia.mybirdjournal"]
    assert context["inviteDomain"] == NEW_HOST
    assert context["inviteFormerDomains"] == [OLD_HOST]


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
    assert "Featherguild" in invite
    assert "seven days" in invite
    # The home page, privacy and terms are on this domain now (#71).
    assert '<a href="/">Find out how to get it</a>' in invite


def test_the_api_makes_links_on_the_invite_domain(template: Template) -> None:
    (function,) = [
        resource
        for resource in template.find_resources("AWS::Lambda::Function").values()
        if resource["Properties"].get("Handler") == "birdjournal_api.handler.handler"
    ]
    assert function["Properties"]["Environment"]["Variables"]["INVITE_BASE_URL"] == f"https://{NEW_HOST}"


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
    (distribution,) = [name for name in template.find_resources("AWS::CloudFront::Distribution") if name.startswith("InviteSite")]
    assert outputs["InviteDistributionDomain"]["Value"] == {"Fn::GetAtt": [distribution, "DomainName"]}
    assert outputs["InviteBaseUrl"]["Value"] == f"https://{NEW_HOST}"


def _synthesized(**context: Any) -> Template:
    full = {
        **json.loads(CDK_JSON.read_text())["context"],
        "budgetAlertEmail": "budget@example.com",
        "inviteCertificateArn": INVITE_CERTIFICATE_ARN,
        "aws:cdk:bundling-stacks": [],
        **context,
    }
    app = cdk.App(context=full)
    return Template.from_stack(
        BirdJournalStack(
            app, "BirdJournal", config=BirdJournalConfig.from_context(app.node), env=cdk.Environment(region="us-west-2")
        )
    )


def test_the_first_deploy_adds_the_new_host_and_moves_nothing() -> None:
    """Redirects and links wait for the second deploy, so nothing points at a host that isn't answering yet."""
    first = _synthesized(inviteNewHostFirst="true")
    assert _distribution(first)["Aliases"] == [NEW_HOST, OLD_HOST]
    assert _distribution(first)["ViewerCertificate"]["AcmCertificateArn"] == INVITE_CERTIFICATE_ARN
    (function,) = [
        resource
        for resource in first.find_resources("AWS::Lambda::Function").values()
        if resource["Properties"].get("Handler") == "birdjournal_api.handler.handler"
    ]
    assert function["Properties"]["Environment"]["Variables"]["INVITE_BASE_URL"] == f"https://{OLD_HOST}"
    assert first.to_json()["Outputs"]["InviteBaseUrl"]["Value"] == f"https://{OLD_HOST}"
    code = _only(first, "AWS::CloudFront::Function")["Properties"]["FunctionCode"]
    assert 'FORMER_HOSTS = []' in code


def test_the_first_and_second_deploys_keep_the_same_distribution_and_function(template: Template) -> None:
    first = _synthesized(inviteNewHostFirst="true")
    for type_ in ("AWS::CloudFront::Distribution", "AWS::CloudFront::Function"):
        assert set(first.find_resources(type_)) == set(template.find_resources(type_))


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


def test_the_site_has_the_privacy_policy_and_terms_and_no_page_points_back_to_github() -> None:
    from birdjournal_infra.invite_site import SITE_DIRECTORY

    pages = {path.name: path.read_text() for path in SITE_DIRECTORY.glob("*.html")}
    assert {"index.html", "invite.html", "privacy.html", "terms.html"} <= set(pages)
    for name, text in pages.items():
        assert "github.io" not in text, name
        assert 'href="/privacy"' in text, name
    privacy = pages["privacy.html"]
    for subject in ("Guilds", "finds", "Notifications", "React", "Goals", "Shared patches",
                    "Moderation", "Reports", "Blocks", "Deleting your account", "secret spot"):
        assert subject.lower() in privacy.lower(), subject


def test_the_pages_say_guild_never_circle() -> None:
    """Issue #118: a Circle is a Guild wherever a person reads it; only the app's internal names keep Circle."""
    from birdjournal_infra.invite_site import SITE_DIRECTORY

    pages = {path.name: path.read_text() for path in SITE_DIRECTORY.glob("*.html")}
    for name, text in pages.items():
        assert "circle" not in text.lower(), name
    invite = pages["invite.html"]
    assert "<title>Join a Guild on Featherguild</title>" in invite
    assert "You're invited to a Guild" in invite


def test_the_pages_keep_to_the_apps_words() -> None:
    """Issue #150: patches rather than cards, field-guide downloads rather than packs, and no middle dots."""
    from birdjournal_infra.invite_site import SITE_DIRECTORY

    for path in SITE_DIRECTORY.glob("*.html"):
        # Tags go first, because the stylesheet's "card" class isn't a word anyone reads. The title stays: it's read.
        words = re.sub(r"<(?!title)[^>]+>", " ", path.read_text()).lower()
        assert "·" not in words, path.name
        assert not re.search(r"\bpacks?\b", words), path.name
        assert not re.search(r"(?<!paper )\bcards?\b", words), path.name


def test_the_pages_link_within_themselves_not_to_the_old_host() -> None:
    for path in SITE_DIRECTORY.glob("*.html"):
        assert OLD_HOST not in path.read_text(), path.name
