from aws_cdk import Stack
from aws_cdk import aws_cognito as cognito
from aws_cdk import aws_iam as iam
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_s3 as s3
from aws_cdk import aws_secretsmanager as secretsmanager
from aws_cdk import aws_ses as ses
from constructs import Construct


class Safety(Construct):
    """What a public launch needs (issue #71): reports mailed through SES, Rekognition moderation behind the
    `moderation` switch, and account deletion (the Cognito user deleted, the Sign in with Apple token revoked).

    - **SES**: one email identity, the report address, which is both sender and recipient: a verified identity can
      send to itself from the SES sandbox, so no production-access request is needed. Creating it makes SES email a
      verification link; `infra/scripts/safety-wizard.sh` waits for the click. Until then a report is stored and its
      mail fails with a log line.
    - **Rekognition** reads the pictures in place, with the API's own S3 access: the art-job uploads, painted art
      (`art/*`, the first time the API reads a painting) and shared photos (`photos/*`, already readable, #66).
      `rekognition:DetectModerationLabels` has no resource-level permissions, so it is granted on `*`. Granted even
      with the switch off, so turning it on is a context change and a deploy, nothing else.
    - **Account deletion**: `cognito-idp:AdminDeleteUser` on the user pool, and read access to the accounts wizard's
      Sign in with Apple secret, whose key signs the client secret for Apple's `/auth/token` and `/auth/revoke`.
    """

    def __init__(
        self, scope: Construct, id: str, *, function: lambda_.IFunction, report_email: str,
        user_pool: cognito.IUserPool, apple_sign_in_secret_name: str, upload_bucket: s3.IBucket,
        art_bucket: s3.IBucket,
    ) -> None:
        super().__init__(scope, id)
        self.identity = ses.EmailIdentity(self, "ReportIdentity", identity=ses.Identity.email(report_email))
        stack = Stack.of(self)
        function.add_to_role_policy(
            iam.PolicyStatement(
                actions=["ses:SendEmail"],
                resources=[stack.format_arn(service="ses", resource="identity", resource_name=report_email)],
            )
        )
        function.add_to_role_policy(
            iam.PolicyStatement(actions=["rekognition:DetectModerationLabels"], resources=["*"])
        )
        function.add_to_role_policy(
            iam.PolicyStatement(
                actions=["s3:GetObject"],
                resources=[upload_bucket.arn_for_objects("uploads/*"), art_bucket.arn_for_objects("art/*")],
            )
        )
        function.add_to_role_policy(
            iam.PolicyStatement(actions=["cognito-idp:AdminDeleteUser"], resources=[user_pool.user_pool_arn])
        )
        self.apple_key = secretsmanager.Secret.from_secret_name_v2(self, "AppleSignInKey", apple_sign_in_secret_name)
        self.apple_key.grant_read(function)
