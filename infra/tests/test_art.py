"""The art CDN (issues #68 and #62): what scene art's retirement (#137) left, and that the pipeline itself is gone."""

from typing import Any

from aws_cdk.assertions import Template


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


def test_the_stack_outputs_the_art_cdn_and_its_bucket(template: Template) -> None:
    outputs = template.to_json()["Outputs"]
    distribution, _ = _named(template, "AWS::CloudFront::Distribution", "ArtCdn")
    bucket, _ = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    assert outputs["ArtCdnDomain"]["Value"] == {"Fn::GetAtt": [distribution, "DomainName"]}
    assert outputs["ArtBucket"]["Value"] == {"Ref": bucket}
    assert not {"ArtQueueUrl", "ArtUploadBucket", "ArtWorkerUser", "ArtWorkerTokenSecret"} & set(outputs)


# The pipeline is gone (#137).


def test_no_queue_upload_bucket_worker_or_token_is_left(template: Template) -> None:
    assert template.find_resources("AWS::SQS::Queue") == {}
    assert template.find_resources("AWS::IAM::User") == {}
    assert not [name for name in template.find_resources("AWS::S3::Bucket") if "Uploads" in name]
    assert not [name for name in template.find_resources("AWS::SecretsManager::Secret") if "WorkerToken" in name]


def test_the_api_has_no_setting_for_the_pipeline(template: Template) -> None:
    variables = _api_function(template)["Properties"]["Environment"]["Variables"]
    assert not {"UPLOAD_BUCKET", "ART_QUEUE_URL", "ART_WORKER_TOKEN_SECRET", "ART_AUTO_PAINT", "ART_DAILY_ALLOWANCE"} & set(variables)
    assert {"ART_BUCKET", "ART_CDN_BASE_URL"} <= set(variables)


def test_the_api_has_no_access_to_the_retired_paintings_prefix(template: Template) -> None:
    role = _api_function(template)["Properties"]["Role"]["Fn::GetAtt"][0]
    assert [s for s in _policy_statements(template, role=role) if "/art/*" in str(s["Resource"])] == []
