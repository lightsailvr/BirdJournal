"""The domain wizard (issue #150), run over fake aws, dig and curl: what it saves, when it deploys, and where it stops."""

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path
from typing import Any

import pytest

INFRA = Path(__file__).resolve().parents[1]
NEW = "featherguild.matthewcelia.com"
OLD = "birdquest.matthewcelia.com"
TARGET = "d123.cloudfront.net"
OLD_ARN = "arn:aws:acm:us-east-1:000000000000:certificate/old"
NEW_ARN = "arn:aws:acm:us-east-1:000000000000:certificate/new"
OTHER_ARN = "arn:aws:acm:us-east-1:000000000000:certificate/other-project"
APP_ID = "647FZYVR5Q.com.matthewcelia.mybirdjournal"
AASA = "/.well-known/apple-app-site-association"
ASSOCIATION = {"applinks": {"details": [{"appIDs": [APP_ID], "components": [{"/": "/i/*"}]}]}}

pytestmark = pytest.mark.skipif(shutil.which("jq") is None, reason="the wizard needs jq")

FAKE_AWS = r"""#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_STATE"]
state = json.load(open(state_path))
args = sys.argv[1:]
state["aws_calls"].append(" ".join(args))
def save(): json.dump(state, open(state_path, "w"))
def answer(value):
    save()
    print(value if isinstance(value, str) else json.dumps(value))
    sys.exit(0)
def fail():
    save()
    sys.exit(254)
command = args[:2]
if " ".join(command) in state["failing"]:
    fail()
query = args[args.index("--query") + 1] if "--query" in args else ""
if command == ["sts", "get-caller-identity"]:
    answer("000000000000")
if command == ["acm", "list-certificates"]:
    answer({"CertificateSummaryList": [
        {"DomainName": c["domain"], "SubjectAlternativeNameSummaries": c["sans"], "Status": c["status"], "CertificateArn": c["arn"]}
        for c in state["certificates"]]})
if command == ["acm", "request-certificate"]:
    state["requested"] = args
    state["certificates"].append({"arn": state["new_arn"], "domain": os.environ["NEW_HOST"], "sans": [os.environ["NEW_HOST"], os.environ["OLD_HOST"]],
                                  "status": "PENDING_VALIDATION", "tags": [{"Key": "project", "Value": "birdjournal"}], "checks_until_issued": state["checks_until_issued"]})
    answer(state["new_arn"])
certificates = {c["arn"]: c for c in state["certificates"]}
if command == ["acm", "list-tags-for-certificate"]:
    c = certificates[args[args.index("--certificate-arn") + 1]]
    answer(str(len([t for t in c["tags"] if t == {"Key": "project", "Value": "birdjournal"}])))
if command == ["acm", "describe-certificate"]:
    c = certificates.get(args[args.index("--certificate-arn") + 1])
    if c is None:
        fail()
    if "Status" in query:
        if c["status"] == "PENDING_VALIDATION":
            c["checks_until_issued"] -= 1
            if c["checks_until_issued"] <= 0:
                c["status"] = "ISSUED"
        answer(c["status"])
    answer({"Certificate": {"Status": c["status"], "SubjectAlternativeNames": c["sans"], "DomainValidationOptions": [
        {"DomainName": host, "ResourceRecord": {"Name": f"_v.{host}.", "Value": f"_{host}.acm-validations.aws."}} for host in c["sans"]]}})
if command == ["cloudformation", "describe-stacks"]:
    if state.get("no_stack"):
        save()
        sys.stderr.write("Stack with id BirdJournal does not exist\n")
        sys.exit(254)
    if "StackStatus" in query:
        answer("UPDATE_COMPLETE")
    for key, value in state["outputs"].items():
        if key in query:
            answer(value)
    answer("None")
if command == ["cloudfront", "list-distributions"]:
    if "contains(Aliases.Items" in query:
        answer(state["other_distribution"])
    answer(state["distribution"])
if command == ["cloudformation", "list-stack-resources"]:
    answer(["BirdJournal-ApiFunction"])
if command == ["lambda", "get-function-configuration"]:
    answer(state["outputs"]["InviteBaseUrl"])
if command == ["sesv2", "get-account"]:
    answer("https://lightsailvr.com")
sys.stderr.write("unexpected aws call: " + " ".join(args) + "\n")
fail()
"""

FAKE_DIG = r"""#!/usr/bin/env python3
import json, os, sys
state = json.load(open(os.environ["FAKE_STATE"]))
args = [a for a in sys.argv[1:] if not a.startswith("+") and not a.startswith("@")]
if state.get("dig_times_out"):
    print(";; connection timed out; no servers could be reached")
    sys.exit(9)
if args[0] == "NS":
    print("\n".join(state["name_servers"]))
elif args[0] == "CNAME":
    print(state["records"].get(args[1].rstrip("."), ""))
else:
    print(state["records"].get(args[0].rstrip("."), ""))
"""

FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, sys
state = json.load(open(os.environ["FAKE_STATE"]))
url = sys.argv[-1]
page = state["web"].get(url)
if page is None:
    if url.startswith("https://app-site-association.cdn-apple.com"):
        page = {"status": 404}
    else:
        print("000||" if "-w" in sys.argv else "", end="")
        sys.exit(6)
if "-w" in sys.argv:
    format_ = sys.argv[sys.argv.index("-w") + 1]
    if format_ == "%{http_code}":
        print(page["status"], end="")
    else:
        print(f'{page["status"]}|{page.get("type", "")}|{page.get("location", "")}', end="")
else:
    print(page.get("body", ""), end="")
"""


def _web() -> dict[str, Any]:
    """Both hosts as the deployed site answers."""
    aasa = {"status": 200, "type": "application/json", "body": json.dumps(ASSOCIATION)}
    pages = {"/": "Featherguild", "/privacy": "Privacy policy", "/terms": "Terms of use", "/i/wizard-check": "You're invited to a Guild"}
    web: dict[str, Any] = {f"https://{NEW}{path}": {"status": 200, "type": "text/html", "body": body} for path, body in pages.items()}
    web[f"https://{NEW}{AASA}"] = aasa
    web[f"https://{OLD}{AASA}"] = aasa
    for path in pages:
        web[f"https://{OLD}{path}"] = {"status": 301, "location": f"https://{NEW}{path}"}
    return web


class Wizard:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.home = root / "home"
        self.state_path = root / "state.json"
        self.deploys = root / "deploys.log"
        repo = root / "repo"
        scripts = repo / "infra" / "scripts"
        scripts.mkdir(parents=True)
        for name in ("domain-wizard.sh", "check-invite-certificate.sh", "check-invite-dns.sh", "check-live-backend.sh"):
            shutil.copy(INFRA / "scripts" / name, scripts / name)
        shutil.copy(INFRA / "cdk.json", repo / "infra" / "cdk.json")
        backend = repo / "backend" / "src" / "birdjournal_api"
        backend.mkdir(parents=True)
        (backend / "goals_api.py").write_text("class GoalSpecies:\n    pass\n")
        (backend / "reactions_api.py").write_text("editions: list[str]\n")
        self.script = scripts / "domain-wizard.sh"
        self._executable(
            scripts / "deploy.sh",
            f'#!/usr/bin/env bash\nset -eu\necho "deploy $* arn=$INVITE_CERTIFICATE_ARN" >> "{self.deploys}"\n'
            + 'if [[ "${1:-}" != "--diff" ]]; then "$(dirname "$0")/fake-deployed.py" "$@"; fi\n',
        )
        self._executable(
            scripts / "fake-deployed.py",
            "#!/usr/bin/env python3\nimport json, os\n"
            'import sys\npath = os.environ["FAKE_STATE"]\nstate = json.load(open(path))\n'
            f'state["distribution"] = {{"aliases": ["{NEW}", "{OLD}"], "certificate": os.environ["INVITE_CERTIFICATE_ARN"]}}\n'
            f'if "--new-host-first" not in sys.argv:\n    state["outputs"]["InviteBaseUrl"] = "https://{NEW}"\n'
            'json.dump(state, open(path, "w"))\n',
        )
        bin_ = root / "bin"
        bin_.mkdir()
        self._executable(bin_ / "aws", FAKE_AWS)
        self._executable(bin_ / "dig", FAKE_DIG)
        self._executable(bin_ / "curl", FAKE_CURL)
        self._executable(bin_ / "sleep", "#!/bin/sh\nexit 0\n")
        self._executable(bin_ / "open", "#!/bin/sh\nexit 0\n")
        (self.home / "keys").mkdir(parents=True)
        self.env_file = self.home / "keys" / "birdjournal.env"
        self.env_file.write_text(f"INVITE_CERTIFICATE_ARN='{OLD_ARN}'\n")
        self.state: dict[str, Any] = {
            "aws_calls": [],
            "failing": [],
            "name_servers": ["ns1.siteground.net.", "ns2.siteground.net."],
            "new_arn": NEW_ARN,
            "checks_until_issued": 2,
            "certificates": [
                {"arn": OLD_ARN, "domain": OLD, "sans": [OLD], "status": "ISSUED", "tags": [{"Key": "project", "Value": "birdjournal"}]}
            ],
            "outputs": {"InviteDistributionDomain": TARGET, "InviteBaseUrl": f"https://{OLD}"},
            "other_distribution": [],
            "distribution": {"aliases": [OLD], "certificate": OLD_ARN},
            "records": {
                OLD: f"{TARGET}.",
                NEW: f"{TARGET}.",
                f"_v.{OLD}": f"_{OLD}.acm-validations.aws.",
                f"_v.{NEW}": f"_{NEW}.acm-validations.aws.",
            },
            "web": _web(),
        }

    @staticmethod
    def _executable(path: Path, text: str) -> None:
        path.write_text(text)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def save(self) -> None:
        self.state_path.write_text(json.dumps(self.state))

    def run(self, answers: list[str], **env: str) -> subprocess.CompletedProcess[str]:
        self.save()
        result = subprocess.run(
            ["bash", str(self.script)],
            input="".join(line + "\n" for line in answers),
            capture_output=True,
            text=True,
            timeout=300,
            env={
                # The wizard's deploy.sh runs these tests, with its own certificate exported and maybe a resume stage.
                **{name: value for name, value in os.environ.items() if name not in ("INVITE_CERTIFICATE_ARN", "WIZARD_FROM")},
                "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                "HOME": str(self.home),
                "FAKE_STATE": str(self.state_path),
                "NEW_HOST": NEW,
                "OLD_HOST": OLD,
                **env,
            },
        )
        self.state = json.loads(self.state_path.read_text())
        return result

    def use_the_real_deploy(self) -> Path:
        """deploy.sh as it is, with everything after its checks faked: a log of what reached `npx` says if it got past them."""
        scripts = self.script.parent
        shutil.copy(INFRA / "scripts" / "deploy.sh", scripts / "deploy.sh")
        self._executable(scripts / "check-bootstrap.sh", "#!/bin/sh\nexit 0\n")
        self._executable(scripts / "write-app-config.sh", "#!/bin/sh\nexit 0\n")
        (self.root / "repo" / "infra" / "node_modules").mkdir()
        bin_ = self.root / "bin"
        self._executable(bin_ / "uv", "#!/bin/sh\nexit 0\n")
        self._executable(bin_ / "npx", f'#!/bin/sh\necho "$*" >> "{self.deploys}"\n')
        self.env_file.write_text(f"INVITE_CERTIFICATE_ARN='{NEW_ARN}'\nBUDGET_ALERT_EMAIL='a@example.com'\n")
        self.state["certificates"].append(
            {"arn": NEW_ARN, "domain": NEW, "sans": [NEW, OLD], "status": "ISSUED", "tags": [{"Key": "project", "Value": "birdjournal"}]}
        )
        self.save()
        return scripts / "deploy.sh"

    def deploy(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        script = self.use_the_real_deploy()
        result = subprocess.run(
            [str(script), *arguments],
            capture_output=True,
            text=True,
            timeout=300,
            env={
                **{name: value for name, value in os.environ.items() if name not in ("INVITE_CERTIFICATE_ARN", "BUDGET_ALERT_EMAIL")},
                "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                "HOME": str(self.home),
                "FAKE_STATE": str(self.state_path),
            },
        )
        return result

    def reached_cdk(self) -> str:
        return self.deploys.read_text() if self.deploys.exists() else ""

    def saved_arn(self) -> str:
        return self.env_file.read_text().split("INVITE_CERTIFICATE_ARN='")[1].split("'")[0]


@pytest.fixture
def wizard(tmp_path: Path) -> Wizard:
    return Wizard(tmp_path)


# Every prompt of a first run, in order, past the banner.
FIRST_RUN = [
    "",  # banner
    "",  # 1 where things stand
    "y",  # 2 request the certificate
    "",  # 2
    "",  # 3 records created
    "",  # 4 issued
    "",  # 5 CNAME
    "n",  # 6 no diff
    "y",  # 6 the first deploy
    "",  # 6
    "n",  # 7 no diff
    "y",  # 7 the second deploy
    "",  # 7
    "",  # 8 site checks
    f"https://{NEW}/i/from-the-app",  # 9 a real link
    "",  # 9
    "y",  # 10 App Store Connect
    "",  # 10
    "",  # 11 SES, which it reads itself
    "y",  # 12 Wearables Developer Center
    "",  # 12
    "y",  # 13 Google
    "",  # 13
]


def test_a_first_run_requests_one_certificate_for_both_hosts_and_saves_it_only_once_issued(wizard: Wizard) -> None:
    wizard.state["web"][f"https://{NEW}/i/from-the-app"] = wizard.state["web"][f"https://{NEW}/i/wizard-check"]
    wizard.state["web"][f"https://{OLD}/i/from-the-app"] = {"status": 301, "location": f"https://{NEW}/i/from-the-app"}

    result = wizard.run(FIRST_RUN)

    assert result.returncode == 0, result.stdout + result.stderr
    requested = wizard.state["requested"]
    assert requested[requested.index("--domain-name") + 1] == NEW
    assert requested[requested.index("--subject-alternative-names") + 1] == OLD
    assert requested[requested.index("--region") + 1] == "us-east-1"
    assert "Key=project,Value=birdjournal" in requested
    assert wizard.saved_arn() == NEW_ARN
    assert wizard.deploys.read_text().splitlines() == [f"deploy --new-host-first arn={NEW_ARN}", f"deploy  arn={NEW_ARN}"]
    assert "still to do" not in result.stdout


def test_it_only_writes_to_aws_by_requesting_the_certificate(wizard: Wizard) -> None:
    wizard.state["web"][f"https://{NEW}/i/from-the-app"] = wizard.state["web"][f"https://{NEW}/i/wizard-check"]
    wizard.state["web"][f"https://{OLD}/i/from-the-app"] = {"status": 301, "location": f"https://{NEW}/i/from-the-app"}
    wizard.run(FIRST_RUN)
    reads = ("sts get-caller", "acm list-", "acm describe-", "cloudformation describe-", "cloudformation list-",
             "cloudfront list-", "lambda get-", "sesv2 get-")
    writes = [call for call in wizard.state["aws_calls"] if not call.startswith(reads)]
    assert [call.split()[:2] for call in writes] == [["acm", "request-certificate"]]


def test_saying_no_to_the_certificate_changes_nothing(wizard: Wizard) -> None:
    result = wizard.run(["", "", "n"])
    assert result.returncode == 1
    assert "requested" not in wizard.state
    assert wizard.saved_arn() == OLD_ARN


def test_a_certificate_still_pending_leaves_the_saved_one_alone(wizard: Wizard) -> None:
    """deploy.sh reads the saved ARN, and CloudFront would refuse one that isn't issued."""
    wizard.state["checks_until_issued"] = 10_000
    result = wizard.run(["", "", "y", "", "", ""])
    assert result.returncode == 1
    assert "Still pending" in result.stdout
    assert wizard.saved_arn() == OLD_ARN
    assert not wizard.deploys.exists()


def test_another_projects_certificate_is_not_reused(wizard: Wizard) -> None:
    wizard.state["certificates"].append(
        {"arn": OTHER_ARN, "domain": NEW, "sans": [NEW, OLD], "status": "ISSUED", "tags": [{"Key": "project", "Value": "other"}]}
    )
    result = wizard.run(["", "", "n"])
    assert "leaves it alone" in result.stdout + result.stderr
    assert result.returncode == 1  # it offered a new one rather than taking that one


def test_a_rerun_finds_its_certificate_instead_of_requesting_another(wizard: Wizard) -> None:
    wizard.state["certificates"].append(
        {"arn": NEW_ARN, "domain": NEW, "sans": [NEW, OLD], "status": "ISSUED", "tags": [{"Key": "project", "Value": "birdjournal"}]}
    )
    wizard.state["distribution"] = {"aliases": [NEW, OLD], "certificate": NEW_ARN}
    wizard.state["outputs"]["InviteBaseUrl"] = f"https://{NEW}"
    answers = ["", "", "", "", "", "", "", "", "", "", "", "y", "", "", "y", "", "y", ""]
    result = wizard.run(answers)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "requested" not in wizard.state
    assert not wizard.deploys.exists()
    assert result.stdout.count("Already live") == 2


def test_a_certificate_whose_tags_cant_be_read_doesnt_lead_to_a_second_certificate(wizard: Wizard) -> None:
    wizard.state["certificates"].append(
        {"arn": NEW_ARN, "domain": NEW, "sans": [NEW, OLD], "status": "ISSUED", "tags": [{"Key": "project", "Value": "birdjournal"}]}
    )
    wizard.state["failing"] = ["acm list-tags-for-certificate"]
    result = wizard.run(["", "", "y"])
    assert result.returncode == 1
    assert "Can't read the tags" in result.stdout + result.stderr
    assert "requested" not in wizard.state


def test_cloudfront_not_answering_isnt_read_as_no_other_distribution(wizard: Wizard) -> None:
    wizard.state["failing"] = ["cloudfront list-distributions"]
    result = wizard.run([""], WIZARD_FROM="5")
    assert result.returncode == 1
    assert "Can't list CloudFront" in result.stdout


def test_a_dig_timeout_isnt_read_as_a_record(wizard: Wizard) -> None:
    wizard.state["dig_times_out"] = True
    result = wizard.run(["", ""], WIZARD_FROM="5")
    assert result.returncode == 1
    assert "already points at" not in result.stdout


def test_an_unreadable_ses_account_is_listed_rather_than_passed(wizard: Wizard) -> None:
    wizard.state["failing"] = ["sesv2 get-account"]
    result = wizard.run(["", "", "y", "", "y", ""], WIZARD_FROM="11")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "SES's account website: WIZARD_FROM=11" in result.stdout


def test_dns_somewhere_else_stops_before_anything_changes(wizard: Wizard) -> None:
    wizard.state["name_servers"] = ["ns1.example.net."]
    result = wizard.run([""])
    assert result.returncode == 1
    assert "aren't SiteGround's" in result.stdout
    assert "requested" not in wizard.state


def test_a_record_pointing_elsewhere_is_not_overwritten(wizard: Wizard) -> None:
    wizard.state["certificates"].append(
        {"arn": NEW_ARN, "domain": NEW, "sans": [NEW, OLD], "status": "ISSUED", "tags": [{"Key": "project", "Value": "birdjournal"}]}
    )
    wizard.state["records"][NEW] = "someone-else.example.com."
    result = wizard.run([""], WIZARD_FROM="5")
    assert result.returncode == 1
    assert "doesn't overwrite" in result.stdout
    assert not wizard.deploys.exists()


def _ready_for_the_first_deploy(wizard: Wizard) -> None:
    wizard.state["certificates"].append(
        {"arn": NEW_ARN, "domain": NEW, "sans": [NEW, OLD], "status": "ISSUED", "tags": [{"Key": "project", "Value": "birdjournal"}]}
    )
    wizard.env_file.write_text(f"INVITE_CERTIFICATE_ARN='{NEW_ARN}'\n")


@pytest.mark.parametrize("stage", ["6", "7"])
@pytest.mark.parametrize("host", [NEW, OLD])
def test_a_missing_record_stops_either_deploy(wizard: Wizard, stage: str, host: str) -> None:
    """The old host would redirect to a name that doesn't resolve, and resolvers can cache that for hours."""
    _ready_for_the_first_deploy(wizard)
    del wizard.state["records"][host]
    result = wizard.run(["", "n", "y", ""], WIZARD_FROM=stage)
    assert result.returncode == 1
    assert f"{host} points at ''" in result.stdout
    assert "WIZARD_FROM=5" in result.stdout
    assert not wizard.deploys.exists()


def test_a_checkout_without_the_live_backend_stops_the_wizard(wizard: Wizard) -> None:
    _ready_for_the_first_deploy(wizard)
    (wizard.root / "repo/backend/src/birdjournal_api/goals_api.py").write_text("# before slice 8\n")
    result = wizard.run(["", "n", "y", ""], WIZARD_FROM="6")
    assert result.returncode == 1
    assert "already live" in result.stdout
    assert not wizard.deploys.exists()


def test_the_second_deploy_waits_for_the_new_host(wizard: Wizard) -> None:
    _ready_for_the_first_deploy(wizard)
    wizard.state["distribution"] = {"aliases": [NEW, OLD], "certificate": NEW_ARN}
    del wizard.state["web"][f"https://{NEW}/"]
    result = wizard.run(["", "n", "y", ""], WIZARD_FROM="7")
    assert result.returncode == 1
    assert "Nothing has moved" in result.stdout
    assert "cached" in result.stdout
    assert not wizard.deploys.exists()


def test_the_first_deploy_is_skipped_once_live_and_doesnt_ask_to_repeat(wizard: Wizard) -> None:
    _ready_for_the_first_deploy(wizard)
    wizard.state["distribution"] = {"aliases": [NEW, OLD], "certificate": NEW_ARN}
    result = wizard.run(["", "", "n", "n"], WIZARD_FROM="6")
    assert "Already live" in result.stdout
    assert "--new-host-first" not in (wizard.deploys.read_text() if wizard.deploys.exists() else "")


@pytest.mark.parametrize(
    ("url", "broken", "message"),
    [
        (f"https://{OLD}{AASA}", {"status": 301, "location": f"https://{NEW}{AASA}"}, AASA),
        (f"https://{NEW}{AASA}", {"status": 200, "type": "text/html", "body": "{}"}, "application/json"),
        (f"https://{OLD}/i/wizard-check", {"status": 200, "type": "text/html", "body": "x"}, "wanted 301"),
        (f"https://{NEW}/privacy", {"status": 404}, "wanted 200"),
    ],
)
def test_a_failed_site_check_stops_it(wizard: Wizard, url: str, broken: dict[str, Any], message: str) -> None:
    wizard.state["web"][url] = broken
    result = wizard.run([""], WIZARD_FROM="8")
    assert result.returncode == 1
    assert message in result.stdout
    assert "WIZARD_FROM=8" in result.stdout
    assert "cached" in result.stdout


def test_a_pasted_link_on_the_old_host_stops_it(wizard: Wizard) -> None:
    wizard.state["outputs"]["InviteBaseUrl"] = f"https://{NEW}"
    result = wizard.run(["", f"https://{OLD}/i/abc"], WIZARD_FROM="9")
    assert result.returncode == 1
    assert "isn't on" in result.stdout


def test_a_console_step_not_done_is_listed_at_the_end(wizard: Wizard) -> None:
    result = wizard.run(["", "n", "", "", "y", "", "y", ""], WIZARD_FROM="10")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "App Store Connect's privacy, support and marketing URLs" in result.stdout


def test_the_closing_notes_give_the_order(wizard: Wizard) -> None:
    result = wizard.run(["", "y", "", "", "y", "", "y", ""], WIZARD_FROM="10")
    assert "these deploys first, then the app's release" in result.stdout
    assert "deploy only from branches that hold this change" in result.stdout


@pytest.mark.parametrize(
    ("sans", "status", "code", "message"),
    [
        ([NEW, OLD], "ISSUED", 0, "OK"),
        ([OLD], "ISSUED", 1, f"doesn't cover: {NEW}"),
        ([NEW], "ISSUED", 1, f"doesn't cover: {OLD}"),
        ([NEW, OLD], "PENDING_VALIDATION", 1, "not ISSUED"),
    ],
)
def test_the_deploy_refuses_a_certificate_that_wont_do(wizard: Wizard, sans: list[str], status: str, code: int, message: str) -> None:
    wizard.state["certificates"] = [{"arn": NEW_ARN, "domain": sans[0], "sans": sans, "status": status, "tags": [], "checks_until_issued": 99}]
    wizard.save()
    result = subprocess.run(
        [str(wizard.script.parent / "check-invite-certificate.sh")],
        capture_output=True,
        text=True,
        env={**os.environ, "PATH": f"{wizard.root / 'bin'}:{os.environ['PATH']}", "FAKE_STATE": str(wizard.state_path), "INVITE_CERTIFICATE_ARN": NEW_ARN},
    )
    assert result.returncode == code, result.stdout + result.stderr
    assert message in result.stdout


@pytest.mark.parametrize("host", [NEW, OLD])
@pytest.mark.parametrize("arguments", [(), ("--new-host-first",)])
def test_a_bare_deploy_refuses_a_missing_record(wizard: Wizard, host: str, arguments: tuple[str, ...]) -> None:
    del wizard.state["records"][host]
    result = wizard.deploy(*arguments)
    assert result.returncode == 1
    assert f"{host} points at ''" in result.stdout
    assert wizard.reached_cdk() == ""


def test_a_bare_deploy_refuses_a_record_pointing_elsewhere(wizard: Wizard) -> None:
    wizard.state["records"][NEW] = "someone-else.example.com."
    result = wizard.deploy()
    assert result.returncode == 1
    assert "someone-else.example.com" in result.stdout
    assert wizard.reached_cdk() == ""


def test_a_bare_deploy_refuses_when_the_stack_cant_be_read(wizard: Wizard) -> None:
    wizard.state["failing"] = ["cloudformation describe-stacks"]
    result = wizard.deploy()
    assert result.returncode == 1
    assert "Can't read the stack" in result.stdout
    assert wizard.reached_cdk() == ""


def test_a_deploy_on_a_new_account_has_no_records_to_check(wizard: Wizard) -> None:
    wizard.state["no_stack"] = True
    wizard.state["records"] = {}
    result = wizard.deploy("--new-host-first")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "cdk deploy" in wizard.reached_cdk()


def test_a_bare_deploy_refuses_until_the_new_host_answers(wizard: Wizard) -> None:
    del wizard.state["web"][f"https://{NEW}/"]
    result = wizard.deploy()
    assert result.returncode == 1
    assert "first deploy of the new host" in result.stdout.lower()
    assert wizard.reached_cdk() == ""


def test_the_first_deploy_doesnt_need_the_new_host_yet_and_says_so_to_cdk(wizard: Wizard) -> None:
    del wizard.state["web"][f"https://{NEW}/"]
    result = wizard.deploy("--new-host-first")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "cdk deploy BirdJournal --require-approval broadening -c inviteNewHostFirst=true" in wizard.reached_cdk()


def test_a_bare_deploy_with_everything_ready_reaches_cdk(wizard: Wizard) -> None:
    result = wizard.deploy()
    assert result.returncode == 0, result.stdout + result.stderr
    assert "cdk deploy BirdJournal --require-approval broadening" in wizard.reached_cdk()
    assert "inviteNewHostFirst" not in wizard.reached_cdk()


@pytest.mark.parametrize("backend", ["goals_api.py", "reactions_api.py"])
def test_a_bare_deploy_refuses_a_checkout_without_the_live_backend(wizard: Wizard, backend: str) -> None:
    (wizard.root / "repo/backend/src/birdjournal_api" / backend).write_text("# before slice 8\n")
    result = wizard.deploy()
    assert result.returncode == 1
    assert "--without-live-backend" in result.stdout
    assert wizard.reached_cdk() == ""


def test_the_override_deploys_without_the_live_backend(wizard: Wizard) -> None:
    (wizard.root / "repo/backend/src/birdjournal_api/goals_api.py").write_text("# before slice 8\n")
    result = wizard.deploy("--without-live-backend")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "cdk deploy" in wizard.reached_cdk()


def test_a_diff_compares_templates_and_never_deploys(wizard: Wizard) -> None:
    """Otherwise cdk makes a temporary change set with the deploy role and uploads the assets."""
    result = wizard.deploy("--diff")
    assert result.returncode == 0, result.stdout + result.stderr
    assert wizard.reached_cdk().splitlines() == ["cdk diff BirdJournal --method=template"]


def test_an_unknown_argument_stops_a_deploy(wizard: Wizard) -> None:
    result = wizard.deploy("--without-live-backends")
    assert result.returncode == 2
    assert wizard.reached_cdk() == ""
