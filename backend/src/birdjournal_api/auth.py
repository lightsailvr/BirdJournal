"""Cognito access-token verification (ported from ivan-parallax's verifier)."""

import logging
from collections.abc import Callable
from dataclasses import dataclass
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, Request, status

log = logging.getLogger(__name__)

SigningKeyResolver = Callable[[str], jwt.PyJWK]


def cognito_signing_keys(issuer: str) -> SigningKeyResolver:
    """Resolves a token's key from the user pool's published JWKS, cached for the life of the Lambda instance."""
    # A short timeout: a stuck fetch holds the invocation for its whole length.
    client = jwt.PyJWKClient(f"{issuer}/.well-known/jwks.json", cache_keys=True, timeout=5)
    return client.get_signing_key_from_jwt


@dataclass(frozen=True)
class TokenVerifier:
    issuer: str
    client_ids: frozenset[str]
    signing_key: SigningKeyResolver

    def subject(self, token: str) -> str:
        """The Cognito subject of a valid access token; raises jwt.InvalidTokenError otherwise."""
        return self.identity(token).subject

    def identity(self, token: str) -> "Identity":
        """The subject and the user pool's username of a valid access token; raises jwt.InvalidTokenError otherwise."""
        try:
            key = self.signing_key(token)
        except (jwt.PyJWKClientError, KeyError) as error:
            raise jwt.InvalidTokenError(str(error)) from error
        claims = jwt.decode(
            token,
            key=key,
            algorithms=["RS256"],
            issuer=self.issuer,
            options={"require": ["exp", "iss", "sub", "token_use", "client_id"]},
        )
        # Cognito access tokens carry the app client in client_id, not aud.
        if claims["token_use"] != "access":
            raise jwt.InvalidTokenError("not an access token")
        if claims["client_id"] not in self.client_ids:
            raise jwt.InvalidTokenError("token issued to another app client")
        return Identity(subject=str(claims["sub"]), username=str(claims.get("username") or claims["sub"]))


@dataclass(frozen=True)
class Identity:
    """Who is calling: the Cognito subject (every item's key) and the user pool's username (`signinwithapple_<id>`
    or `google_<id>` for a federated birder), which account deletion (#71) needs to delete the Cognito user."""

    subject: str
    username: str

    @property
    def provider(self) -> str | None:
        """`apple` or `google` for a federated user, from the username's prefix; None otherwise."""
        prefix = self.username.partition("_")[0].lower()
        return {"signinwithapple": "apple", "google": "google"}.get(prefix)


def _unauthorized() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="A valid bearer token is required",
        headers={"WWW-Authenticate": "Bearer"},
    )


def current_identity(request: Request) -> Identity:
    """FastAPI dependency: who is making this request."""
    scheme, _, token = request.headers.get("Authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise _unauthorized()
    verifier: TokenVerifier = request.app.state.verifier
    try:
        identity = verifier.identity(token)
    except jwt.InvalidTokenError as error:
        log.info("token rejected: %s", error)
        raise _unauthorized() from None
    # A deleted account's last tokens (#71) reach nothing but a retried deletion, which must be able to finish.
    deleter = getattr(request.app.state, "deleter", None)
    retrying_deletion = request.method == "DELETE" and request.url.path == "/v1/account"
    if deleter is not None and not retrying_deletion and deleter.is_deleted(identity.subject):
        raise _unauthorized()
    return identity


def current_subject(request: Request) -> str:
    """FastAPI dependency: the Cognito subject making this request."""
    return current_identity(request).subject


Subject = Annotated[str, Depends(current_subject)]
CurrentIdentity = Annotated[Identity, Depends(current_identity)]
