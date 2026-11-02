from aws_cdk import RemovalPolicy
from aws_cdk import aws_dynamodb as dynamodb
from constructs import Construct


class Data(Construct):
    """The one DynamoDB table, on demand (ADR-0002). The key scheme is backend/src/birdjournal_api/tables.py's."""

    def __init__(self, scope: Construct, id: str) -> None:
        super().__init__(scope, id)
        self.table = dynamodb.TableV2(
            self,
            "Table",
            partition_key=dynamodb.Attribute(name="pk", type=dynamodb.AttributeType.STRING),
            sort_key=dynamodb.Attribute(name="sk", type=dynamodb.AttributeType.STRING),
            billing=dynamodb.Billing.on_demand(),
            # Expired circle invites (issue #61) carry `ttl`, epoch seconds a month after they lapse.
            time_to_live_attribute="ttl",
            point_in_time_recovery_specification=dynamodb.PointInTimeRecoverySpecification(
                point_in_time_recovery_enabled=True
            ),
            # Accounts outlive a mistaken destroy or a replacement.
            deletion_protection=True,
            removal_policy=RemovalPolicy.RETAIN,
        )
