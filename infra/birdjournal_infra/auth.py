from aws_cdk import Duration, RemovalPolicy, SecretValue
from aws_cdk import aws_cognito as cognito
from constructs import Construct

from birdjournal_infra.config import BirdJournalConfig


class Auth(Construct):
    """Cognito user pool where a birder signs in with Apple or Google (ported from ivan-parallax's Auth).

    App Review guideline 4.8 asks for Sign in with Apple beside Google. The app opens the hosted UI's
    /oauth2/authorize in ASWebAuthenticationSession with identity_provider=SignInWithApple or Google, so
    the provider's own page shows at once, and exchanges the code (PKCE) at the token endpoint.
    """

    def __init__(self, scope: Construct, id: str, *, config: BirdJournalConfig) -> None:
        super().__init__(scope, id)

        self.user_pool = cognito.UserPool(
            self,
            "UserPool",
            # Federated sign-in still creates users; this only shuts the password sign-up API.
            self_sign_up_enabled=False,
            account_recovery=cognito.AccountRecovery.NONE,
            # Accounts outlive a mistaken destroy or a replacement: the pool is retained and protected.
            deletion_protection=True,
            removal_policy=RemovalPolicy.RETAIN,
        )

        google_secret = config.google_oauth_secret_name
        google = cognito.UserPoolIdentityProviderGoogle(
            self,
            "Google",
            user_pool=self.user_pool,
            client_id=SecretValue.secrets_manager(google_secret, json_field="client_id").unsafe_unwrap(),
            client_secret_value=SecretValue.secrets_manager(google_secret, json_field="client_secret"),
            scopes=["openid", "email", "profile"],
            attribute_mapping=cognito.AttributeMapping(
                email=cognito.ProviderAttribute.GOOGLE_EMAIL,
                email_verified=cognito.ProviderAttribute.GOOGLE_EMAIL_VERIFIED,
                fullname=cognito.ProviderAttribute.GOOGLE_NAME,
                given_name=cognito.ProviderAttribute.GOOGLE_GIVEN_NAME,
            ),
        )

        apple_secret = config.apple_sign_in_secret_name
        apple = cognito.UserPoolIdentityProviderApple(
            self,
            "Apple",
            user_pool=self.user_pool,
            client_id=SecretValue.secrets_manager(apple_secret, json_field="services_id").unsafe_unwrap(),
            team_id=SecretValue.secrets_manager(apple_secret, json_field="team_id").unsafe_unwrap(),
            key_id=SecretValue.secrets_manager(apple_secret, json_field="key_id").unsafe_unwrap(),
            private_key_value=SecretValue.secrets_manager(apple_secret, json_field="private_key"),
            scopes=["name", "email"],
            attribute_mapping=cognito.AttributeMapping(
                email=cognito.ProviderAttribute.APPLE_EMAIL,
                email_verified=cognito.ProviderAttribute.APPLE_EMAIL_VERIFIED,
                fullname=cognito.ProviderAttribute.APPLE_NAME,
                given_name=cognito.ProviderAttribute.APPLE_FIRST_NAME,
            ),
        )

        self.domain = self.user_pool.add_domain(
            "Domain",
            cognito_domain=cognito.CognitoDomainOptions(domain_prefix=config.cognito_domain_prefix),
        )

        # Public client for the iOS app and the smoke script: authorization code with PKCE, no secret.
        self.app_client = self.user_pool.add_client(
            "IosClient",
            generate_secret=False,
            o_auth=cognito.OAuthSettings(
                flows=cognito.OAuthFlows(authorization_code_grant=True),
                scopes=[cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
                callback_urls=list(config.oauth_callback_urls),
                logout_urls=list(config.oauth_logout_urls),
            ),
            supported_identity_providers=[
                cognito.UserPoolClientIdentityProvider.APPLE,
                cognito.UserPoolClientIdentityProvider.GOOGLE,
            ],
            prevent_user_existence_errors=True,
            enable_token_revocation=True,
            access_token_validity=Duration.hours(1),
            id_token_validity=Duration.hours(1),
            # A birder stays signed in across launches (spec v2 story 68); the app refreshes the hour-long
            # access token with this.
            refresh_token_validity=Duration.days(365),
        )
        self.app_client.node.add_dependency(google, apple)

        # ProviderURL includes the scheme: it is the iss claim of the pool's tokens.
        self.issuer = self.user_pool.user_pool_provider_url
