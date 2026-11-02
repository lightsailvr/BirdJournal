from aws_cdk import Duration
from aws_cdk import aws_events as events
from aws_cdk import aws_events_targets as targets
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_secretsmanager as secretsmanager
from constructs import Construct

DIGEST_FLUSH_EVERY = Duration.minutes(15)
# What the API's handler (backend handler.py) reads to run the flush instead of an HTTP request.
DIGEST_FLUSH_EVENT = {"birdjournal_job": "flush_digests"}


class Pushes(Construct):
    """Pushes (issue #63): the API reads the APNs token key from Secrets Manager, and an EventBridge rule invokes the
    API's function every 15 minutes to flush the digests.

    The key's secret is created by `infra/scripts/push-wizard.sh` outside the stack, like the sign-in providers'
    secrets (#60): the .p8 comes from the Apple Developer portal and never passes through CloudFormation. Deployed
    before the wizard has run, the API finds no secret and sends no pushes; nothing else changes.
    """

    def __init__(self, scope: Construct, id: str, *, function: lambda_.IFunction, apns_secret_name: str) -> None:
        super().__init__(scope, id)
        self.apns_key = secretsmanager.Secret.from_secret_name_v2(self, "ApnsKey", apns_secret_name)
        self.apns_key.grant_read(function)
        self.digest_flush = events.Rule(
            self,
            "DigestFlush",
            description="BirdJournal: flush the push digests (issue #63)",
            schedule=events.Schedule.rate(DIGEST_FLUSH_EVERY),
            targets=[
                targets.LambdaFunction(
                    function,
                    event=events.RuleTargetInput.from_object(DIGEST_FLUSH_EVENT),
                    # A missed flush is made up by the next one 15 minutes later.
                    retry_attempts=0,
                )
            ],
        )
