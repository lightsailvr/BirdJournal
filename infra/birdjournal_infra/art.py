from aws_cdk import RemovalPolicy
from aws_cdk import aws_cloudfront as cloudfront
from aws_cdk import aws_cloudfront_origins as origins
from aws_cdk import aws_s3 as s3
from constructs import Construct

# The bucket's prefix for what the pack publish step uploads. Keep the name: #62 (finds) builds on it.
PACK_THUMBNAILS_PREFIX = "packs/"
"""Small patch thumbnails (#62, #136), so a friend's phone can show any find's patch without that pack."""


class ArtCdn(Construct):
    """The one art CDN (issue #68, shared with #62): a private bucket behind CloudFront with origin access control, on
    CloudFront's own domain (no certificate, no DNS). Nothing lists the bucket and every key is unguessable, so a URL
    is the only way to a picture; the phone and the circle feed fetch by URL.

    The bucket is Retain like the other user data: shared photos are a birder's, and a destroyed stack shouldn't take
    the pictures a find still shows.
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
