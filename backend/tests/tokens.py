"""Cognito-shaped tokens signed by a key the tests control."""

import json
import time
from typing import Any
from uuid import uuid4

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

ISSUER = "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_TestPool"
CLIENT_ID = "test-ios-client"
KEY_ID = "test-key"


class TestIssuer:
    """Stands in for the user pool: signs access tokens and publishes its JWKS."""

    __test__ = False

    def __init__(self) -> None:
        self._private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        jwk = json.loads(RSAAlgorithm.to_jwk(self._private_key.public_key()))
        self._jwks = jwt.PyJWKSet.from_dict(
            {"keys": [{**jwk, "kid": KEY_ID, "alg": "RS256", "use": "sig"}]}
        )

    def signing_key(self, token: str) -> jwt.PyJWK:
        return self._jwks[jwt.get_unverified_header(token)["kid"]]

    def access_token(self, sub: str = "apple-sub-1", **overrides: Any) -> str:
        claims = {**_claims(sub), **overrides}
        return jwt.encode(claims, self._private_key, algorithm="RS256", headers={"kid": KEY_ID})

    def headers(self, sub: str = "apple-sub-1", **overrides: Any) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.access_token(sub, **overrides)}"}

    @staticmethod
    def forged_token(sub: str = "apple-sub-1") -> str:
        """A well-formed token signed by a key the user pool never published."""
        other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        return jwt.encode(_claims(sub), other_key, algorithm="RS256", headers={"kid": KEY_ID})


def _claims(sub: str) -> dict[str, Any]:
    """The claims of a Cognito access token from the iOS app client."""
    now = int(time.time())
    return {
        "sub": sub,
        "iss": ISSUER,
        "client_id": CLIENT_ID,
        "token_use": "access",
        "scope": "openid email profile",
        "username": f"signinwithapple_{sub}",
        "auth_time": now,
        "iat": now,
        "exp": now + 3600,
        "jti": str(uuid4()),
    }
