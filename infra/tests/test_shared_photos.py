"""Shared cards' original photos (issue #66): under photos/ in the art CDN's bucket, unshared uploads expiring after a
day, and the API's access limited to that prefix."""

import json

from aws_cdk.assertions import Template

from tests.test_art import _actions, _api_function, _named, _policy_statements


def test_unshared_photos_expire_after_a_day_and_nothing_else_does(template: Template) -> None:
    _, bucket = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    (rule,) = bucket["Properties"]["LifecycleConfiguration"]["Rules"]
    assert rule["Id"] == "DeleteUnsharedPhotosAfterADay"
    assert rule["Status"] == "Enabled"
    assert rule["ExpirationInDays"] == 1
    assert rule["Prefix"] == "photos/"
    assert rule["TagFilters"] == [{"Key": "pending", "Value": "true"}]
    # Still Retain: a shared photo is the birder's, like the painted art beside it.
    assert bucket["DeletionPolicy"] == "Retain"


def test_the_api_reaches_photos_and_nothing_else_of_the_art_bucket_for_them(template: Template) -> None:
    function = _api_function(template)
    role = function["Properties"]["Role"]["Fn::GetAtt"][0]
    art, _ = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    photo_statements = [
        statement
        for statement in _policy_statements(template, role=role)
        if "s3:PutObjectTagging" in _actions(statement)
    ]
    (statement,) = photo_statements
    resource = json.dumps(statement["Resource"])
    assert art in resource and "/photos/*" in resource
    assert sorted(_actions(statement)) == sorted(
        ["s3:PutObject", "s3:PutObjectTagging", "s3:GetObject", "s3:DeleteObjectTagging", "s3:DeleteObject"]
    )


def test_the_api_knows_the_art_bucket(template: Template) -> None:
    variables = _api_function(template)["Properties"]["Environment"]["Variables"]
    art, _ = _named(template, "AWS::S3::Bucket", "ArtCdnBucket")
    assert variables["ART_BUCKET"] == {"Ref": art}
