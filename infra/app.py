import aws_cdk as cdk

from birdjournal_infra.config import BirdJournalConfig
from birdjournal_infra.stack import BirdJournalStack

app = cdk.App()
BirdJournalStack(
    app,
    "BirdJournal",
    config=BirdJournalConfig.from_context(app.node),
    # Region only: synth needs no credentials. The account is whichever AWS_PROFILE deploys (lsvr-admin).
    env=cdk.Environment(region="us-west-2"),
    description="BirdJournal: accounts and circles API, invite links, the art CDN (issues #60, #61, #68)",
)
app.synth()
