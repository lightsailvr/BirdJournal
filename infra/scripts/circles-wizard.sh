#!/usr/bin/env bash
# The wizard that first set up the invite domain (issue #61) moved: infra/scripts/domain-wizard.sh does its certificate,
# DNS, deploy and checks for every host the site answers on, and a certificate this one requested wouldn't cover them.
printf 'Use infra/scripts/domain-wizard.sh: it replaces this wizard (issue #150).\n' >&2
exit 1
