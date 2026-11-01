"""The one DynamoDB table and its key scheme.

Single-table design: every item has a string partition key `pk` and sort key `sk`. An account is
`pk = ACCOUNT#<cognito sub>`, `sk = PROFILE`. Later tickets add their items (memberships, finds, devices) beside
it under their own prefixes and add indexes as their access patterns need. The stack (infra/) creates the same
key schema; `create_table` is for DynamoDB Local.
"""

from typing import Any

PARTITION_KEY = "pk"
SORT_KEY = "sk"


def create_table(dynamodb: Any, name: str) -> None:
    dynamodb.create_table(
        TableName=name,
        KeySchema=[
            {"AttributeName": PARTITION_KEY, "KeyType": "HASH"},
            {"AttributeName": SORT_KEY, "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": PARTITION_KEY, "AttributeType": "S"},
            {"AttributeName": SORT_KEY, "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    ).wait_until_exists()
