"""The synthesized template against issue #60 and ADR-0002."""

import json
from typing import Any

import pytest
from aws_cdk.assertions import Match, Template

from tests.conftest import BUDGET_EMAIL

# CloudFormation types that take no tags. Any other type must carry project=birdjournal, so a resource a
# later ticket adds fails here until it is tagged (or listed, with the reason being CloudFormation's).
UNTAGGABLE_TYPES = {
    "AWS::ApiGatewayV2::Integration",
    "AWS::ApiGatewayV2::Route",
    "AWS::Cognito::UserPoolClient",
    "AWS::Cognito::UserPoolDomain",
    "AWS::Cognito::UserPoolIdentityProvider",
    "AWS::IAM::Policy",
    "AWS::Lambda::Permission",
    # The invite site (issue #61): the bucket's policy, CloudFront's origin access control, and the site upload's
    # AWS CLI layer and custom resource (the upload's Lambda function itself is tagged).
    "AWS::S3::BucketPolicy",
    "AWS::CloudFront::OriginAccessControl",
    "AWS::Lambda::LayerVersion",
    "Custom::CDKBucketDeployment",
}


def _resources(template: Template, type_: str) -> dict[str, Any]:
    return template.find_resources(type_)


def _api_function(template: Template) -> tuple[str, dict[str, Any]]:
    """The API's Lambda function (the invite site's upload has its own)."""
    (entry,) = [
        (name, resource)
        for name, resource in _resources(template, "AWS::Lambda::Function").items()
        if resource["Properties"].get("Handler") == "birdjournal_api.handler.handler"
    ]
    return entry


def _tags(properties: dict[str, Any]) -> dict[str, str]:
    """A resource's tags, in whichever shape its type uses: a list of Key/Value pairs or a map. A DynamoDB
    global table keeps them on its replica."""
    if replicas := properties.get("Replicas"):
        (replica,) = replicas
        return _tags(replica)
    for name in ("Tags", "UserPoolTags", "ResourceTags"):
        tags = properties.get(name)
        if isinstance(tags, list):
            return {tag["Key"]: tag["Value"] for tag in tags}
        if isinstance(tags, dict):
            return tags
    return {}


# Tags and cost.


def test_every_taggable_resource_is_tagged_project_birdjournal(template: Template) -> None:
    resources = template.to_json()["Resources"]
    untagged = [
        f"{name} ({resource['Type']})"
        for name, resource in resources.items()
        if resource["Type"] not in UNTAGGABLE_TYPES
        and _tags(resource.get("Properties", {})).get("project") != "birdjournal"
    ]
    assert untagged == []


def test_the_core_resources_are_among_the_tagged(template: Template) -> None:
    types = {resource["Type"] for resource in template.to_json()["Resources"].values()}
    assert {
        "AWS::Cognito::UserPool",
        "AWS::DynamoDB::GlobalTable",
        "AWS::Lambda::Function",
        "AWS::ApiGatewayV2::Api",
        "AWS::Budgets::Budget",
        "AWS::Logs::LogGroup",
        "AWS::IAM::Role",
    } <= types


def test_the_budget_alarm_watches_what_is_tagged_birdjournal(template: Template) -> None:
    template.has_resource_properties(
        "AWS::Budgets::Budget",
        {
            "Budget": {
                "BudgetType": "COST",
                "TimeUnit": "MONTHLY",
                "BudgetLimit": {"Amount": 10, "Unit": "USD"},
                "CostFilters": {"TagKeyValue": ["user:project$birdjournal"]},
            },
        },
    )


def test_the_budget_emails_at_80_percent_actual_and_100_percent_forecast(template: Template) -> None:
    (budget,) = _resources(template, "AWS::Budgets::Budget").values()
    alarms = {
        (entry["Notification"]["NotificationType"], entry["Notification"]["Threshold"]): entry["Subscribers"]
        for entry in budget["Properties"]["NotificationsWithSubscribers"]
    }
    subscriber = [{"SubscriptionType": "EMAIL", "Address": BUDGET_EMAIL}]
    assert alarms == {("ACTUAL", 80): subscriber, ("FORECASTED", 100): subscriber}


# Auth: Cognito with Apple and Google.


def test_google_federates_with_the_secret_from_the_wizard(template: Template) -> None:
    template.has_resource_properties(
        "AWS::Cognito::UserPoolIdentityProvider",
        {
            "ProviderName": "Google",
            "ProviderType": "Google",
            "ProviderDetails": {
                "client_id": Match.string_like_regexp("resolve:secretsmanager:birdjournal/google-oauth"),
                "client_secret": Match.string_like_regexp("resolve:secretsmanager:birdjournal/google-oauth"),
                "authorize_scopes": "openid email profile",
            },
        },
    )


def test_sign_in_with_apple_federates_with_the_services_id_and_key(template: Template) -> None:
    (apple,) = [
        resource
        for resource in _resources(template, "AWS::Cognito::UserPoolIdentityProvider").values()
        if resource["Properties"]["ProviderType"] == "SignInWithApple"
    ]
    details = json.dumps(apple["Properties"]["ProviderDetails"])
    for field in ("services_id", "team_id", "key_id", "private_key"):
        assert f"resolve:secretsmanager:birdjournal/apple-sign-in:SecretString:{field}" in details
    assert apple["Properties"]["ProviderDetails"]["authorize_scopes"] == "name email"


def test_the_app_client_is_public_and_signs_in_by_authorization_code(template: Template) -> None:
    template.has_resource_properties(
        "AWS::Cognito::UserPoolClient",
        {
            "GenerateSecret": False,
            "AllowedOAuthFlows": ["code"],
            "AllowedOAuthFlowsUserPoolClient": True,
            "AllowedOAuthScopes": Match.array_with(["openid", "email", "profile"]),
            "SupportedIdentityProviders": Match.array_equals(["SignInWithApple", "Google"]),
            "CallbackURLs": ["birdjournal://auth/callback", "http://localhost:48765/callback"],
            "LogoutURLs": ["birdjournal://auth/signout", "http://localhost:48765/signout"],
            "EnableTokenRevocation": True,
        },
    )


def test_tokens_last_an_hour_and_the_refresh_token_a_year(template: Template) -> None:
    template.has_resource_properties(
        "AWS::Cognito::UserPoolClient",
        {
            "AccessTokenValidity": 60,
            "IdTokenValidity": 60,
            "RefreshTokenValidity": 365 * 24 * 60,
            "TokenValidityUnits": {"AccessToken": "minutes", "IdToken": "minutes", "RefreshToken": "minutes"},
        },
    )


def test_the_user_pool_has_a_hosted_domain(template: Template) -> None:
    template.has_resource_properties("AWS::Cognito::UserPoolDomain", {"Domain": "birdjournal-lightsailvr"})


def test_nobody_signs_up_with_a_password(template: Template) -> None:
    template.has_resource_properties(
        "AWS::Cognito::UserPool", {"AdminCreateUserConfig": {"AllowAdminCreateUserOnly": True}}
    )


# Accounts survive the stack.


@pytest.mark.parametrize("type_", ["AWS::Cognito::UserPool", "AWS::DynamoDB::GlobalTable"])
def test_accounts_are_retained_if_the_stack_goes(template: Template, type_: str) -> None:
    (resource,) = _resources(template, type_).values()
    assert resource["DeletionPolicy"] == "Retain"
    assert resource["UpdateReplacePolicy"] == "Retain"


def test_the_user_pool_has_deletion_protection(template: Template) -> None:
    template.has_resource_properties("AWS::Cognito::UserPool", {"DeletionProtection": "ACTIVE"})


# DynamoDB on demand.


def test_the_table_is_on_demand_with_the_backends_key_scheme(template: Template) -> None:
    template.has_resource_properties(
        "AWS::DynamoDB::GlobalTable",
        {
            "BillingMode": "PAY_PER_REQUEST",
            "KeySchema": [
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            "Replicas": [
                Match.object_like(
                    {
                        "DeletionProtectionEnabled": True,
                        "PointInTimeRecoverySpecification": {"PointInTimeRecoveryEnabled": True},
                    }
                )
            ],
        },
    )


# The API: FastAPI on Lambda behind an HTTP API.


def test_the_api_is_an_http_api_proxying_every_route_to_the_lambda(template: Template) -> None:
    template.has_resource_properties("AWS::ApiGatewayV2::Api", {"ProtocolType": "HTTP"})
    template.has_resource_properties("AWS::ApiGatewayV2::Route", {"RouteKey": "$default"})
    template.has_resource_properties(
        "AWS::ApiGatewayV2::Integration", {"IntegrationType": "AWS_PROXY", "PayloadFormatVersion": "2.0"}
    )


def test_the_stage_throttles_requests(template: Template) -> None:
    template.has_resource_properties(
        "AWS::ApiGatewayV2::Stage",
        {"StageName": "$default", "DefaultRouteSettings": {"ThrottlingRateLimit": 25, "ThrottlingBurstLimit": 50}},
    )


def test_the_function_runs_the_mangum_handler_on_arm(template: Template) -> None:
    template.has_resource_properties(
        "AWS::Lambda::Function",
        {
            "Handler": "birdjournal_api.handler.handler",
            "Runtime": "python3.14",
            "Architectures": ["arm64"],
            "MemorySize": 512,
            "Timeout": 10,
        },
    )


def test_the_function_trusts_the_user_pool_and_its_app_client(template: Template) -> None:
    (pool,) = _resources(template, "AWS::Cognito::UserPool")
    (client,) = _resources(template, "AWS::Cognito::UserPoolClient")
    (table,) = _resources(template, "AWS::DynamoDB::GlobalTable")
    _, function = _api_function(template)
    variables = function["Properties"]["Environment"]["Variables"]
    # ProviderURL already starts with https://, the same string as a token's iss claim.
    assert variables["COGNITO_ISSUER"] == {"Fn::GetAtt": [pool, "ProviderURL"]}
    assert variables["COGNITO_CLIENT_IDS"] == {"Ref": client}
    assert variables["TABLE_NAME"] == {"Ref": table}


def test_the_functions_dynamodb_access_is_the_table_only(template: Template) -> None:
    """Its other grants are scene art's (tests/test_art.py)."""
    (table,) = _resources(template, "AWS::DynamoDB::GlobalTable")
    _, function = _api_function(template)
    role = function["Properties"]["Role"]["Fn::GetAtt"][0]
    (policy,) = [
        resource
        for resource in _resources(template, "AWS::IAM::Policy").values()
        if {"Ref": role} in resource["Properties"].get("Roles", [])
    ]
    statements = policy["Properties"]["PolicyDocument"]["Statement"]
    dynamodb = [statement for statement in statements if "dynamodb:" in json.dumps(statement["Action"])]
    assert dynamodb
    assert all(table in json.dumps(statement["Resource"]) for statement in dynamodb)


def test_the_logs_are_kept_a_month(template: Template) -> None:
    template.has_resource_properties("AWS::Logs::LogGroup", {"RetentionInDays": 30})


def test_the_stack_outputs_what_the_app_and_the_wizard_need(template: Template) -> None:
    outputs = template.to_json()["Outputs"]
    assert {"ApiUrl", "UserPoolId", "AppClientId", "CognitoDomain", "IdpResponseUrl", "TableName"} <= set(outputs)
    assert outputs["IdpResponseUrl"]["Value"] == (
        "https://birdjournal-lightsailvr.auth.us-west-2.amazoncognito.com/oauth2/idpresponse"
    )
