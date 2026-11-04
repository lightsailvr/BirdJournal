from aws_cdk import RemovalPolicy
from aws_cdk import aws_cloudfront as cloudfront
from aws_cdk import aws_cloudfront_origins as origins
from aws_cdk import aws_iam as iam
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_s3 as s3
from constructs import Construct

# The bucket's prefixes. Keep the names: #62 (finds) builds on them.
PAINTED_PREFIX = "art/"
"""Scene and photo paintings left from before #137: art/<sub>/<unguessable>.jpg. Nothing writes here any more; each goes
when the find showing it moves on or the account is deleted (ADR-0004)."""
PACK_THUMBNAILS_PREFIX = "packs/"
"""Small patch thumbnails (#62, #136), so a friend's phone can show any find's patch without that pack."""


class ArtCdn(Construct):
    """The one art CDN (issue #68, shared with #62): a private bucket behind CloudFront with origin access control, on
    CloudFront's own domain (no certificate, no DNS). Nothing lists the bucket and every key is unguessable, so a URL
    is the only way to a picture; the phone and the circle feed fetch by URL.

    The bucket is Retain like the other user data: shared photos and the paintings left are a birder's, and a destroyed
    stack shouldn't take the pictures a find still shows.
    """

    def __init__(self, scope: Construct, id: str) -> None:
        super().__init__(scope, id)

        self.bucket = s3.Bucket(
            self,
            "Bucket",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            encryption=s3.BucketEncryption.S3_MANAGED,
            enforce_ssl=True,
            removal_policy=RemovalPolicy.RETAIN,
        )
        self.distribution = cloudfront.Distribution(
            self,
            "Distribution",
            comment="BirdJournal card art",
            price_class=cloudfront.PriceClass.PRICE_CLASS_100,
            http_version=cloudfront.HttpVersion.HTTP2_AND_3,
            default_behavior=cloudfront.BehaviorOptions(
                origin=origins.S3BucketOrigin.with_origin_access_control(self.bucket),
                viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                allowed_methods=cloudfront.AllowedMethods.ALLOW_GET_HEAD,
                cache_policy=cloudfront.CachePolicy.CACHING_OPTIMIZED,
            ),
        )
        self.domain = self.distribution.distribution_domain_name
        self.url = f"https://{self.domain}"

    def grant_delete_paintings(self, function: lambda_.IFunction) -> None:
        """The API deletes a painting left from before #137 when its find moves on or the account goes. It never reads
        one: CloudFront serves them."""
        function.add_to_role_policy(
            iam.PolicyStatement(actions=["s3:DeleteObject"], resources=[self.bucket.arn_for_objects(f"{PAINTED_PREFIX}*")])
        )
