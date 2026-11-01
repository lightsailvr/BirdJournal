import json
from pathlib import Path

import aws_cdk as cdk
import pytest
from aws_cdk.assertions import Template

from birdjournal_infra.config import BirdJournalConfig
from birdjournal_infra.stack import BirdJournalStack

CDK_JSON = Path(__file__).resolve().parents[1] / "cdk.json"
BUDGET_EMAIL = "budget@example.com"


@pytest.fixture(scope="session")
def template() -> Template:
    """The stack as `cdk deploy` synthesizes it (cdk.json's feature flags and settings), with no AWS calls.
    Bundling is skipped (an empty bundling-stacks list) so the template tests need neither network nor
    Docker; test_bundling.py builds the real package."""
    context = {
        **json.loads(CDK_JSON.read_text())["context"],
        "budgetAlertEmail": BUDGET_EMAIL,
        "aws:cdk:bundling-stacks": [],
    }
    app = cdk.App(context=context)
    stack = BirdJournalStack(
        app,
        "BirdJournal",
        config=BirdJournalConfig.from_context(app.node),
        env=cdk.Environment(region="us-west-2"),
    )
    return Template.from_stack(stack)
