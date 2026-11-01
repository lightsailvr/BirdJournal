from aws_cdk import aws_budgets as budgets
from constructs import Construct

from birdjournal_infra.config import TAG_KEY, TAG_VALUE


class Budget(Construct):
    """A monthly cost budget over what is tagged project=birdjournal, emailing at 80 % actual and 100 % forecast.

    The account is the shared Lightsail VR one, so the budget filters on the tag rather than the whole
    account. The filter counts only once `project` is an active cost allocation tag (the wizard's last stage);
    until then the budget reads $0.
    """

    def __init__(self, scope: Construct, id: str, *, monthly_usd: int, email: str) -> None:
        super().__init__(scope, id)
        subscriber = budgets.CfnBudget.SubscriberProperty(subscription_type="EMAIL", address=email)
        self.budget = budgets.CfnBudget(
            self,
            "Monthly",
            budget=budgets.CfnBudget.BudgetDataProperty(
                budget_name="birdjournal-monthly",
                budget_type="COST",
                time_unit="MONTHLY",
                budget_limit=budgets.CfnBudget.SpendProperty(amount=monthly_usd, unit="USD"),
                cost_filters={"TagKeyValue": [f"user:{TAG_KEY}${TAG_VALUE}"]},
            ),
            notifications_with_subscribers=[
                budgets.CfnBudget.NotificationWithSubscribersProperty(
                    notification=budgets.CfnBudget.NotificationProperty(
                        notification_type=kind,
                        comparison_operator="GREATER_THAN",
                        threshold=threshold,
                        threshold_type="PERCENTAGE",
                    ),
                    subscribers=[subscriber],
                )
                for kind, threshold in (("ACTUAL", 80), ("FORECASTED", 100))
            ],
        )
