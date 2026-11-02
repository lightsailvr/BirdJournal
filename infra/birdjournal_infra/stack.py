from pathlib import Path
from typing import Any

from aws_cdk import CfnOutput, Stack, Tags
from constructs import Construct

from birdjournal_infra.api import Api
from birdjournal_infra.art import ArtCdn
from birdjournal_infra.art_jobs import ArtJobs
from birdjournal_infra.auth import Auth
from birdjournal_infra.budget import Budget
from birdjournal_infra.config import TAG_KEY, TAG_VALUE, BirdJournalConfig
from birdjournal_infra.data import Data
from birdjournal_infra.invite_site import InviteSite
from birdjournal_infra.pushes import Pushes

BACKEND_DIRECTORY = Path(__file__).resolve().parents[2] / "backend"


class BirdJournalStack(Stack):
    """The whole BirdJournal backend in one stack (ADR-0002, issues #60, #61, #63 and #68)."""

    def __init__(self, scope: Construct, id: str, *, config: BirdJournalConfig, **kwargs: Any) -> None:
        super().__init__(scope, id, **kwargs)
        # On the stack, so every resource in it carries the tag; the template tests check none is missed.
        Tags.of(self).add(TAG_KEY, TAG_VALUE)

        auth = Auth(self, "Auth", config=config)
        data = Data(self, "Data")
        invites = InviteSite(
            self,
            "InviteSite",
            domain=config.invite_domain,
            certificate_arn=config.invite_certificate_arn,
            app_ids=list(config.ios_app_ids),
        )
        # The one art CDN (#68): painted art now, pack-art thumbnails for finds (#62) later.
        self.art = ArtCdn(self, "ArtCdn")
        art_jobs = ArtJobs(self, "ArtJobs", cdn=self.art)
        api = Api(
            self,
            "Api",
            backend=BACKEND_DIRECTORY,
            environment={
                "TABLE_NAME": data.table.table_name,
                "COGNITO_ISSUER": auth.issuer,
                "COGNITO_CLIENT_IDS": auth.app_client.user_pool_client_id,
                "INVITE_BASE_URL": invites.url,
                "UPLOAD_BUCKET": art_jobs.uploads.bucket_name,
                "ART_BUCKET": self.art.bucket.bucket_name,
                "ART_CDN_BASE_URL": self.art.url,
                "ART_QUEUE_URL": art_jobs.queue.queue_url,
                "ART_WORKER_TOKEN_SECRET": art_jobs.worker_token.secret_arn,
                "ART_AUTO_PAINT": config.art_auto_paint,
                "APNS_SECRET_NAME": config.apns_secret_name,
                "APNS_TOPIC": config.apns_topic,
            },
        )
        data.table.grant_read_write_data(api.function)
        art_jobs.grant_api(api.function)
        Pushes(self, "Pushes", function=api.function, apns_secret_name=config.apns_secret_name)
        Budget(self, "Budget", monthly_usd=config.monthly_budget_usd, email=config.budget_alert_email)

        domain = f"{config.cognito_domain_prefix}.auth.{self.region}.amazoncognito.com"
        outputs = {
            "ApiUrl": api.url,
            "UserPoolId": auth.user_pool.user_pool_id,
            "AppClientId": auth.app_client.user_pool_client_id,
            "CognitoDomain": domain,
            # Both Google's authorized redirect URI and Apple's Services ID return URL.
            "IdpResponseUrl": f"https://{domain}/oauth2/idpresponse",
            "TableName": data.table.table_name,
            # The invite domain's CNAME target at SiteGround (the circles wizard).
            "InviteDistributionDomain": invites.distribution.distribution_domain_name,
            "InviteBaseUrl": invites.url,
            # The art CDN's host (#68; finds' thumbnails, #62, use it too).
            "ArtCdnDomain": self.art.domain,
            # What the art wizard installs on comfybox for the worker.
            "ArtQueueUrl": art_jobs.queue.queue_url,
            "ArtUploadBucket": art_jobs.uploads.bucket_name,
            "ArtBucket": self.art.bucket.bucket_name,
            "ArtWorkerUser": art_jobs.worker.user_name,
            "ArtWorkerTokenSecret": art_jobs.worker_token.secret_arn,
        }
        for name, value in outputs.items():
            CfnOutput(self, name, value=value)
