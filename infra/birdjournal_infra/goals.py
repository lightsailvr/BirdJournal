from aws_cdk import aws_events as events
from aws_cdk import aws_events_targets as targets
from aws_cdk import aws_lambda as lambda_
from constructs import Construct

# What the API's handler (backend handler.py) reads to run the goals' rollover instead of an HTTP request.
GOAL_ROLLOVER_EVENT = {"birdjournal_job": "roll_over_goals"}


class GoalRollover(Construct):
    """Goals (issue #65): an EventBridge rule invokes the API's function at :00, :15, :30 and :45 past every hour to
    make each circle's monthly goal once its month has begun in its time zone. Every zone's midnight falls on one of
    those quarter hours (UTC offsets are whole hours, halves or, for Nepal and the Chatham Islands, :45), so a goal
    starts on time. Beside the digest flush (#63), the same way: no shared secret, nothing on the public API.
    """

    def __init__(self, scope: Construct, id: str, *, function: lambda_.IFunction) -> None:
        super().__init__(scope, id)
        self.rule = events.Rule(
            self,
            "Rule",
            description="BirdJournal: start each circle's monthly goal (issue #65)",
            schedule=events.Schedule.cron(minute="0/15"),
            targets=[
                targets.LambdaFunction(
                    function,
                    event=events.RuleTargetInput.from_object(GOAL_ROLLOVER_EVENT),
                    # A missed run is made up by the next, and reading the goals makes a missing one anyway.
                    retry_attempts=0,
                )
            ],
        )
