from aws_cdk import Stack
from aws_cdk import aws_cognito as cognito
from aws_cdk import aws_iam as iam
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_s3 as s3
from aws_cdk import aws_secretsmanager as secretsmanager
from constructs import Construct


class Safety(Construct):
    """What a public launch needs (issue #71): reports mailed through SES, Rekognition moderation behind the
    `moderation` switch, and account deletion (the Cognito user deleted, the Sign in with Apple token revoked).

    - **SES**: no identity in the stack. The report address's domain (lightsailvr.com) is already a verified SES
      identity in the shared account, with production access, and a verified domain covers every address in it;
      `infra/scripts/safety-wizard.sh` checks that, and verifies the address on its own only when neither it nor its
      domain is. The API may send as the domain or the address, nothing else.
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
        stack = Stack.of(self)
        domain = report_email.rpartition("@")[2]
        function.add_to_role_policy(
            iam.PolicyStatement(
                actions=["ses:SendEmail"],
                resources=[
                    stack.format_arn(service="ses", resource="identity", resource_name=name)
                    for name in (domain, report_email)
                ],
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
