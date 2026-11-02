import json
from pathlib import Path

from aws_cdk import Duration, RemovalPolicy
from aws_cdk import aws_certificatemanager as acm
from aws_cdk import aws_cloudfront as cloudfront
from aws_cdk import aws_cloudfront_origins as origins
from aws_cdk import aws_s3 as s3
from aws_cdk import aws_s3_deployment as s3deploy
from constructs import Construct

SITE_DIRECTORY = Path(__file__).resolve().parents[1] / "site"
AASA_KEY = ".well-known/apple-app-site-association"

# Viewer request: an invite link, /i/<token>, gets the fallback page. Apple fetches the association file through its
# own CDN, and in the app the link never reaches CloudFront at all.
REWRITE_INVITES = """
function handler(event) {
  var request = event.request;
  if (request.uri === '/i' || request.uri.indexOf('/i/') === 0) {
    request.uri = '/invite.html';
  }
  return request;
}
"""


def apple_app_site_association(app_ids: list[str]) -> dict[str, object]:
    """Universal links for /i/* only, so the fallback page and the rest of the site stay in the browser."""
    return {
        "applinks": {
            "details": [
                {"appIDs": app_ids, "components": [{"/": "/i/*", "comment": "Circle invitations (issue #61)"}]}
            ]
        }
    }


class InviteSite(Construct):
    """The invite domain (issue #61): CloudFront in front of a private bucket (origin access control) serving the
    apple-app-site-association file and the fallback page every /i/<token> link shows in a browser.

    The certificate is in us-east-1, as CloudFront requires, but outside this stack: the wizard requests it and the
    maintainer adds its validation record at SiteGround, so nothing here waits on a DNS change, and the shared
    account's us-east-1 needs no CDK bootstrap. CloudFront takes it by ARN from this us-west-2 stack.
    """

    def __init__(
        self, scope: Construct, id: str, *, domain: str, certificate_arn: str, app_ids: list[str]
    ) -> None:
        super().__init__(scope, id)

        self.bucket = s3.Bucket(
            self,
            "Bucket",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            encryption=s3.BucketEncryption.S3_MANAGED,
            enforce_ssl=True,
            # The contents come from infra/site/ on every deploy; a destroy leaves the bucket to delete by hand.
            removal_policy=RemovalPolicy.RETAIN,
        )

        rewrite = cloudfront.Function(
            self,
            "RewriteInvites",
            code=cloudfront.FunctionCode.from_inline(REWRITE_INVITES),
            runtime=cloudfront.FunctionRuntime.JS_2_0,
            comment="BirdJournal: /i/<token> serves the invite fallback page",
        )

        self.distribution = cloudfront.Distribution(
            self,
            "Distribution",
            comment="BirdJournal invite links",
            domain_names=[domain],
            certificate=acm.Certificate.from_certificate_arn(self, "Certificate", certificate_arn),
            default_root_object="index.html",
            price_class=cloudfront.PriceClass.PRICE_CLASS_100,
            minimum_protocol_version=cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
            http_version=cloudfront.HttpVersion.HTTP2_AND_3,
            default_behavior=cloudfront.BehaviorOptions(
                origin=origins.S3BucketOrigin.with_origin_access_control(self.bucket),
                viewer_protocol_policy=cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                allowed_methods=cloudfront.AllowedMethods.ALLOW_GET_HEAD,
                cache_policy=cloudfront.CachePolicy.CACHING_OPTIMIZED,
                function_associations=[
                    cloudfront.FunctionAssociation(
                        function=rewrite, event_type=cloudfront.FunctionEventType.VIEWER_REQUEST
                    )
                ],
            ),
            # A missing key comes back from S3 as 403 through origin access control.
            error_responses=[
                cloudfront.ErrorResponse(
                    http_status=status,
                    response_http_status=404,
                    response_page_path="/index.html",
                    ttl=Duration.minutes(5),
                )
                for status in (403, 404)
            ],
        )

        # The pages, pruning what infra/site/ no longer has, but never the association file, deployed beside them
        # with the JSON content type Apple asks for (the file has no extension to infer it from).
        site = s3deploy.BucketDeployment(
            self,
            "Pages",
            sources=[s3deploy.Source.asset(str(SITE_DIRECTORY))],
            destination_bucket=self.bucket,
            exclude=[AASA_KEY],
            distribution=self.distribution,
            distribution_paths=["/*"],
            memory_limit=256,
        )
        association = s3deploy.BucketDeployment(
            self,
            "AppSiteAssociation",
            sources=[s3deploy.Source.data(AASA_KEY, json.dumps(apple_app_site_association(app_ids), indent=2))],
            destination_bucket=self.bucket,
            prune=False,
            content_type="application/json",
            cache_control=[s3deploy.CacheControl.max_age(Duration.hours(1))],
            distribution=self.distribution,
            distribution_paths=[f"/{AASA_KEY}"],
            memory_limit=256,
        )
        association.node.add_dependency(site)

        self.domain = domain
        self.url = f"https://{domain}"
