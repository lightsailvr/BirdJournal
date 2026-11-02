from aws_cdk import Duration, RemovalPolicy
from aws_cdk import aws_iam as iam
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_s3 as s3
from aws_cdk import aws_secretsmanager as secretsmanager
from aws_cdk import aws_sqs as sqs
from constructs import Construct

from birdjournal_infra.art import PAINTED_PREFIX, ArtCdn

UPLOADS_PREFIX = "uploads/"
"""The phone's art-job inputs (a glasses photo, faces blurred, metadata stripped): uploads/<sub>/<job id>.jpg."""
UPLOAD_LIFETIME = Duration.days(1)
# A job still queued after 7 days fails (backend art.py), so its message need not outlive it.
QUEUE_RETENTION = Duration.days(7)
# Longer than a painting with every retry (an isolation is cached on the box; three scene paintings, their cut-outs
# and the filter take about two minutes), so a busy worker never sees its own job come back.
VISIBILITY_TIMEOUT = Duration.minutes(15)
MAX_RECEIVES = 5
WORKER_USER_NAME = "birdjournal-art-worker"
WORKER_TOKEN_SECRET_NAME = "birdjournal/art-worker-token"


class ArtJobs(Construct):
    """Scene art's pipeline (issue #68, ADR-0003): the private upload bucket the phone PUTs to through a presigned URL
    (objects expire after a day), the queue with its dead-letter queue, the worker token the API checks on the worker's
    reports, and the IAM user the art worker on comfybox long-polls with, limited to the queue, reading the uploads and
    writing painted art.

    The worker user has no access key here: a key in the stack would sit in the template's outputs or a secret anyone
    with stack access reads. `infra/scripts/art-wizard.sh` creates one and installs it on the box.
    """

    def __init__(self, scope: Construct, id: str, *, cdn: ArtCdn) -> None:
        super().__init__(scope, id)

        self.uploads = s3.Bucket(
            self,
            "Uploads",
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            encryption=s3.BucketEncryption.S3_MANAGED,
            enforce_ssl=True,
            lifecycle_rules=[
                s3.LifecycleRule(id="DeleteUploadsAfterADay", expiration=UPLOAD_LIFETIME, enabled=True),
                s3.LifecycleRule(id="AbortIncompleteUploads", abort_incomplete_multipart_upload_after=UPLOAD_LIFETIME),
            ],
            # Nothing in it lives longer than a day, so a destroyed stack may take it.
            removal_policy=RemovalPolicy.DESTROY,
            auto_delete_objects=False,
        )

        self.dead_letters = sqs.Queue(
            self,
            "DeadLetters",
            retention_period=Duration.days(14),
            encryption=sqs.QueueEncryption.SQS_MANAGED,
            enforce_ssl=True,
        )
        self.queue = sqs.Queue(
            self,
            "Queue",
            retention_period=QUEUE_RETENTION,
            visibility_timeout=VISIBILITY_TIMEOUT,
            # The worker long-polls for 20 s, the most SQS allows; the queue's default matches.
            receive_message_wait_time=Duration.seconds(20),
            encryption=sqs.QueueEncryption.SQS_MANAGED,
            enforce_ssl=True,
            dead_letter_queue=sqs.DeadLetterQueue(queue=self.dead_letters, max_receive_count=MAX_RECEIVES),
        )

        # What the worker presents on its reports (POST /internal/art/jobs/...). Generated at deploy; the wizard copies
        # it to the box, and the API reads it from Secrets Manager.
        self.worker_token = secretsmanager.Secret(
            self,
            "WorkerToken",
            secret_name=WORKER_TOKEN_SECRET_NAME,
            description="BirdJournal: the art worker's token for its job reports (issue #68)",
            generate_secret_string=secretsmanager.SecretStringGenerator(password_length=48, exclude_punctuation=True),
            removal_policy=RemovalPolicy.DESTROY,
        )

        self.worker = iam.User(self, "Worker", user_name=WORKER_USER_NAME)
        self.queue.grant_consume_messages(self.worker)
        self.worker.add_to_policy(
            iam.PolicyStatement(actions=["s3:GetObject"], resources=[self.uploads.arn_for_objects(f"{UPLOADS_PREFIX}*")])
        )
        self.worker.add_to_policy(
            iam.PolicyStatement(actions=["s3:PutObject"], resources=[cdn.bucket.arn_for_objects(f"{PAINTED_PREFIX}*")])
        )

        self.cdn = cdn

    def grant_api(self, function: lambda_.IFunction) -> None:
        """The API presigns the phone's upload, checks it arrived, queues the job, reads the worker token, and deletes
        painted art once the phone has it (and inputs when a job ends)."""
        function.add_to_role_policy(
            iam.PolicyStatement(
                actions=["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
                resources=[self.uploads.arn_for_objects(f"{UPLOADS_PREFIX}*")],
            )
        )
        function.add_to_role_policy(
            iam.PolicyStatement(
                actions=["s3:DeleteObject"], resources=[self.cdn.bucket.arn_for_objects(f"{PAINTED_PREFIX}*")]
            )
        )
        self.queue.grant_send_messages(function)
        self.worker_token.grant_read(function)
