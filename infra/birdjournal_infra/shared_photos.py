from aws_cdk import Duration
from aws_cdk import aws_iam as iam
from aws_cdk import aws_lambda as lambda_
from constructs import Construct

from birdjournal_infra.art import ArtCdn

PHOTOS_PREFIX = "photos/"
"""Original photos on cards shared by hand (#66): photos/<sub>/<unguessable>.jpg, faces blurred and metadata stripped
on the phone, shown in the circles the card went to (ADR-0004: kept only while a shared card shows it)."""
PENDING_LIFETIME = Duration.days(1)


class SharedPhotos(Construct):
    """Shared cards' original photos (issue #66) in the art CDN's bucket, under their own prefix: no bucket of their
    own (#68's ArtCdn serves them by unguessable URL).

    The phone PUTs a photo through a URL the API presigns, tagged `pending=true`; a lifecycle rule expires pending
    photos after a day, so one uploaded for a card never sent doesn't stay. Sharing the card takes the tag off; the API
    deletes the photo when no card shows it any more.
    """

    def __init__(self, scope: Construct, id: str, *, cdn: ArtCdn) -> None:
        super().__init__(scope, id)
        self.cdn = cdn
        cdn.bucket.add_lifecycle_rule(
            id="DeleteUnsharedPhotosAfterADay",
            prefix=PHOTOS_PREFIX,
            tag_filters={"pending": "true"},
            expiration=PENDING_LIFETIME,
            enabled=True,
        )

    def grant_api(self, function: lambda_.IFunction) -> None:
        """The API presigns the phone's upload (with its tag), checks its size, takes the tag off once shared and
        deletes the photo when no card shows it. Only under photos/."""
        function.add_to_role_policy(
            iam.PolicyStatement(
                actions=["s3:PutObject", "s3:PutObjectTagging", "s3:GetObject", "s3:DeleteObjectTagging", "s3:DeleteObject"],
                resources=[self.cdn.bucket.arn_for_objects(f"{PHOTOS_PREFIX}*")],
            )
        )
