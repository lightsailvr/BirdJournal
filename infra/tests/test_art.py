"""Scene art's infrastructure (issue #68): the art CDN (shared with #62), the upload bucket, the queue, the worker's
user and token, and what the API may do with them."""

import json
from typing import Any

import pytest
from aws_cdk.assertions import Template

from tests.test_invite_site import _synth


def _named(template: Template, type_: str, prefix: str) -> tuple[str, dict[str, Any]]:
    (entry,) = [(name, resource) for name, resource in template.find_resources(type_).items() if name.startswith(prefix)]
    return entry


def _api_function(template: Template) -> dict[str, Any]:
    (function,) = [
        resource
        for resource in template.find_resources("AWS::Lambda::Function").values()
        if resource["Properties"].get("Handler") == "birdjournal_api.handler.handler"
    ]
    return function


def _policy_statements(template: Template, *, role: str | None = None, user: str | None = None) -> list[dict[str, Any]]:
    statements = []
    for policy in template.find_resources("AWS::IAM::Policy").values():
        properties = policy["Properties"]
        if (role and {"Ref": role} in properties.get("Roles", [])) or (user and {"Ref": user} in properties.get("Users", [])):
            statements += properties["PolicyDocument"]["Statement"]
    return statements


def _actions(statement: dict[str, Any]) -> list[str]:
    actions = statement["Action"]
    return actions if isinstance(actions, list) else [actions]


# The art CDN.


def test_the_art_cdn_is_a_private_bucket_behind_cloudfront_on_its_own_domain(template: Template) -> None:
    bucket_name, bucket = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    assert bucket["DeletionPolicy"] == "Retain"
    assert all(bucket["Properties"]["PublicAccessBlockConfiguration"].values())
    _, distribution = _named(template, "AWS::CloudFront::Distribution", "ArtCdn")
    config = distribution["Properties"]["DistributionConfig"]
    # No custom domain: no certificate and no DNS to wait on.
    assert "Aliases" not in config
    assert config["PriceClass"] == "PriceClass_100"
    behavior = config["DefaultCacheBehavior"]
    assert behavior["ViewerProtocolPolicy"] == "redirect-to-https"
    assert behavior["AllowedMethods"] == ["GET", "HEAD"]
    (origin,) = config["Origins"]
    assert "OriginAccessControlId" in origin
    assert origin["DomainName"] == {"Fn::GetAtt": [bucket_name, "RegionalDomainName"]}


def test_only_cloudfront_reads_the_art_bucket(template: Template) -> None:
    _, policy = _named(template, "AWS::S3::BucketPolicy", "ArtCdnBucket")
    allowed = [s for s in policy["Properties"]["PolicyDocument"]["Statement"] if s["Effect"] == "Allow"]
    assert [s["Principal"] for s in allowed] == [{"Service": "cloudfront.amazonaws.com"}]
    assert all(s["Action"] == "s3:GetObject" for s in allowed)


def test_the_stack_outputs_the_art_cdn_and_the_worker_settings(template: Template) -> None:
    outputs = template.to_json()["Outputs"]
    distribution, _ = _named(template, "AWS::CloudFront::Distribution", "ArtCdn")
    assert outputs["ArtCdnDomain"]["Value"] == {"Fn::GetAtt": [distribution, "DomainName"]}
    assert {"ArtQueueUrl", "ArtUploadBucket", "ArtBucket", "ArtWorkerUser", "ArtWorkerTokenSecret"} <= set(outputs)


# Uploads and the queue.


def test_uploads_are_private_and_deleted_after_a_day(template: Template) -> None:
    _, bucket = _named(template, "AWS::S3::Bucket", "ArtJobsUploads")
    properties = bucket["Properties"]
    assert all(properties["PublicAccessBlockConfiguration"].values())
    rules = {rule["Id"]: rule for rule in properties["LifecycleConfiguration"]["Rules"]}
    assert rules["DeleteUploadsAfterADay"]["ExpirationInDays"] == 1
    assert rules["DeleteUploadsAfterADay"]["Status"] == "Enabled"
    assert rules["AbortIncompleteUploads"]["AbortIncompleteMultipartUpload"] == {"DaysAfterInitiation": 1}


def test_both_buckets_refuse_plain_http(template: Template) -> None:
    for prefix in ("ArtCdnBucket", "ArtJobsUploads"):
        _, policy = _named(template, "AWS::S3::BucketPolicy", prefix)
        denies = [s for s in policy["Properties"]["PolicyDocument"]["Statement"] if s["Effect"] == "Deny"]
        assert any(s["Condition"] == {"Bool": {"aws:SecureTransport": "false"}} for s in denies), prefix


def test_the_queue_holds_a_job_for_seven_days_with_a_dead_letter_queue(template: Template) -> None:
    dead_letters, dlq = _named(template, "AWS::SQS::Queue", "ArtJobsDeadLetters")
    _, queue = _named(template, "AWS::SQS::Queue", "ArtJobsQueue")
    properties = queue["Properties"]
    assert properties["MessageRetentionPeriod"] == 7 * 24 * 3600
    assert properties["VisibilityTimeout"] == 15 * 60
    assert properties["ReceiveMessageWaitTimeSeconds"] == 20
    assert properties["SqsManagedSseEnabled"] is True
    assert properties["RedrivePolicy"] == {
        "deadLetterTargetArn": {"Fn::GetAtt": [dead_letters, "Arn"]},
        "maxReceiveCount": 5,
    }
    assert dlq["Properties"]["MessageRetentionPeriod"] == 14 * 24 * 3600


# The worker.


def test_the_worker_user_may_only_consume_the_queue_read_uploads_and_write_painted_art(template: Template) -> None:
    user, resource = _named(template, "AWS::IAM::User", "ArtJobsWorker")
    assert resource["Properties"]["UserName"] == "birdjournal-art-worker"
    # No access key in the stack: the wizard makes one and installs it on the box.
    assert not template.find_resources("AWS::IAM::AccessKey")
    queue, _ = _named(template, "AWS::SQS::Queue", "ArtJobsQueue")
    uploads, _ = _named(template, "AWS::S3::Bucket", "ArtJobsUploads")
    art, _ = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    statements = _policy_statements(template, user=user)
    granted: dict[str, Any] = {}
    for statement in statements:
        assert statement["Effect"] == "Allow"
        for action in _actions(statement):
            granted.setdefault(action, []).append(json.dumps(statement["Resource"]))
    assert set(granted) == {
        "sqs:ReceiveMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueUrl", "sqs:DeleteMessage",
        "sqs:GetQueueAttributes", "s3:GetObject", "s3:PutObject",
    }
    assert all(queue in resource for action, resources in granted.items() if action.startswith("sqs:") for resource in resources)
    (get_object,) = granted["s3:GetObject"]
    assert uploads in get_object and "/uploads/*" in get_object
    (put_object,) = granted["s3:PutObject"]
    assert art in put_object and "/art/*" in put_object


def test_the_worker_token_is_generated_in_secrets_manager(template: Template) -> None:
    _, secret = _named(template, "AWS::SecretsManager::Secret", "ArtJobsWorkerToken")
    assert secret["Properties"]["Name"] == "birdjournal/art-worker-token"
    assert secret["Properties"]["GenerateSecretString"]["PasswordLength"] == 48


# The API.


def test_the_api_knows_the_buckets_the_queue_the_cdn_the_token_and_the_rule(template: Template) -> None:
    variables = _api_function(template)["Properties"]["Environment"]["Variables"]
    uploads, _ = _named(template, "AWS::S3::Bucket", "ArtJobsUploads")
    art, _ = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    queue, _ = _named(template, "AWS::SQS::Queue", "ArtJobsQueue")
    secret, _ = _named(template, "AWS::SecretsManager::Secret", "ArtJobsWorkerToken")
    distribution, _ = _named(template, "AWS::CloudFront::Distribution", "ArtCdn")
    assert variables["UPLOAD_BUCKET"] == {"Ref": uploads}
    assert variables["ART_BUCKET"] == {"Ref": art}
    assert variables["ART_QUEUE_URL"] == {"Ref": queue}
    assert variables["ART_WORKER_TOKEN_SECRET"] == {"Ref": secret}
    assert variables["ART_CDN_BASE_URL"] == {"Fn::Join": ["", ["https://", {"Fn::GetAtt": [distribution, "DomainName"]}]]}
    # The friends phase: every add with a glasses photo (server configuration, infra/cdk.json).
    assert variables["ART_AUTO_PAINT"] == "every_glasses_add"


def test_the_api_may_presign_uploads_delete_painted_art_queue_jobs_and_read_the_token(template: Template) -> None:
    function = _api_function(template)
    role = function["Properties"]["Role"]["Fn::GetAtt"][0]
    uploads, _ = _named(template, "AWS::S3::Bucket", "ArtJobsUploads")
    art, _ = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    queue, _ = _named(template, "AWS::SQS::Queue", "ArtJobsQueue")
    secret, _ = _named(template, "AWS::SecretsManager::Secret", "ArtJobsWorkerToken")
    by_action: dict[str, list[str]] = {}
    for statement in _policy_statements(template, role=role):
        for action in _actions(statement):
            by_action.setdefault(action, []).append(json.dumps(statement["Resource"]))
    assert any(uploads in r and "/uploads/*" in r for r in by_action["s3:PutObject"])
    # Beside the uploads, only shared cards' photos (#66, tests/test_shared_photos.py).
    assert all(uploads in r or (art in r and "/photos/*" in r) for r in by_action["s3:PutObject"])
    assert any(art in r and "/art/*" in r for r in by_action["s3:DeleteObject"])
    assert all(queue in r for r in by_action["sqs:SendMessage"])
    assert all(secret in r for r in by_action["secretsmanager:GetSecretValue"])
    # Never the art bucket's whole contents, and never a read of painted art (CloudFront serves it).
    assert not any(art in r and "/photos/*" not in r for r in by_action.get("s3:GetObject", []))


def test_an_unknown_auto_paint_rule_is_refused() -> None:
    with pytest.raises(ValueError, match="artAutoPaint"):
        _synth(budgetAlertEmail="b@example.com", inviteCertificateArn="arn:aws:acm:us-east-1:1:certificate/x", artAutoPaint="always")
