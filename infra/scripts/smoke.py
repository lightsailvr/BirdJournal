"""Smoke-test the deployed BirdJournal stack (ported from ivan-parallax's smoke script).

    uv run python scripts/smoke.py                    # anonymous checks, then sign in with Apple
    uv run python scripts/smoke.py --provider Google  # sign in with Google instead
    uv run python scripts/smoke.py --anonymous        # skip the sign-in

Signing in creates (or reads) the real account of whoever signs in, and sets its display name
only with --display-name. Reads the stack outputs with the AWS CLI (profile lsvr-admin unless
AWS_PROFILE is set).
"""

import argparse
import base64
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

STACK = "BirdJournal"
REGION = "us-west-2"
CALLBACK_PORT = 48765  # registered in cdk.json oauthCallbackUrls
CALLBACK_URL = f"http://localhost:{CALLBACK_PORT}/callback"
SIGN_IN_TIMEOUT_SECONDS = 300
PROVIDERS = {"Apple": "SignInWithApple", "Google": "Google"}


class SmokeFailure(Exception):
    pass


def aws(*args: str) -> Any:
    env = {**os.environ, "AWS_PROFILE": os.environ.get("AWS_PROFILE", "lsvr-admin")}
    result = subprocess.run(
        ["aws", *args, "--region", REGION, "--output", "json"], env=env, check=True, capture_output=True, text=True
    )
    return json.loads(result.stdout)


def stack_outputs() -> dict[str, str]:
    stack = aws("cloudformation", "describe-stacks", "--stack-name", STACK)["Stacks"][0]
    return {output["OutputKey"]: output["OutputValue"] for output in stack["Outputs"]}


def request(method: str, url: str, *, headers: dict[str, str] | None = None, body: Any = None) -> tuple[int, Any]:
    headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(url, data=data, method=method, headers=headers), timeout=30
        ) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")
    except (TimeoutError, urllib.error.URLError) as error:
        raise SmokeFailure(f"{method} {url}: {error}") from None


def check(label: str, result: tuple[int, Any], expected: int) -> Any:
    status, body = result
    if status != expected:
        raise SmokeFailure(f"{label}: expected {expected}, got {status} {body}")
    print(f"ok   {label}")
    return body


def sign_in(domain: str, client_id: str, provider: str) -> str:
    """Authorization code flow with PKCE, straight to the provider, as the iOS app does it."""
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    query = urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": CALLBACK_URL,
            "scope": "openid email profile",
            "identity_provider": PROVIDERS[provider],
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
        }
    )
    code = _await_callback(f"https://{domain}/oauth2/authorize?{query}", state, provider)
    form = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "client_id": client_id,
            "code": code,
            "redirect_uri": CALLBACK_URL,
            "code_verifier": verifier,
        }
    ).encode()
    token_request = urllib.request.Request(
        f"https://{domain}/oauth2/token", data=form, headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    try:
        with urllib.request.urlopen(token_request, timeout=30) as response:
            access_token: str = json.loads(response.read())["access_token"]
    except urllib.error.HTTPError as error:
        raise SmokeFailure(f"token exchange: {error.code} {error.read().decode(errors='replace')}") from None
    print(f"ok   signed in with {provider}")
    return access_token


def _await_callback(authorize_url: str, state: str, provider: str) -> str:
    received: dict[str, str] = {}

    class Callback(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            url = urllib.parse.urlsplit(self.path)
            if url.path != "/callback":
                self.send_error(404)
                return
            received.update(urllib.parse.parse_qsl(url.query))
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Signed in. You can close this tab and return to the terminal.")

        def log_message(self, format: str, *args: Any) -> None:
            pass

    with HTTPServer(("127.0.0.1", CALLBACK_PORT), Callback) as server:
        server.timeout = 5
        print(f"Sign in with {provider} in the browser. If it didn't open, visit:\n  {authorize_url}")
        webbrowser.open(authorize_url)
        deadline = time.monotonic() + SIGN_IN_TIMEOUT_SECONDS
        while not received:
            if time.monotonic() > deadline:
                raise SmokeFailure(f"timed out waiting for the {provider} sign-in")
            server.handle_request()
    if "error" in received:
        raise SmokeFailure(f"sign-in failed: {received}")
    if received.get("state") != state:
        raise SmokeFailure("sign-in returned the wrong state")
    return received["code"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--anonymous", action="store_true", help="skip the sign-in")
    parser.add_argument("--provider", choices=sorted(PROVIDERS), default="Apple")
    parser.add_argument("--display-name", help="also set the signed-in account's display name")
    args = parser.parse_args()

    outputs = stack_outputs()
    api = outputs["ApiUrl"].rstrip("/")
    check("GET /health", request("GET", f"{api}/health"), 200)
    check("GET /v1/account without a token is refused", request("GET", f"{api}/v1/account"), 401)
    check(
        "GET /v1/account with a junk token is refused",
        request("GET", f"{api}/v1/account", headers={"Authorization": "Bearer junk"}),
        401,
    )
    if args.anonymous:
        return

    token = sign_in(outputs["CognitoDomain"], outputs["AppClientId"], args.provider)
    auth = {"Authorization": f"Bearer {token}"}
    account = check("GET /v1/account creates or reads the account", request("GET", f"{api}/v1/account", headers=auth), 200)
    print(f"     {account}")
    if args.display_name:
        updated = check(
            "PATCH /v1/account sets the display name",
            request("PATCH", f"{api}/v1/account", headers=auth, body={"display_name": args.display_name}),
            200,
        )
        print(f"     {updated}")


if __name__ == "__main__":
    try:
        main()
    except SmokeFailure as failure:
        print(f"FAIL {failure}", file=sys.stderr)
        sys.exit(1)
