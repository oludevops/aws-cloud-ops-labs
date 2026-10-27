#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# drift-check.sh - scheduled drift detection
#
# Runs `terraform plan -detailed-exitcode`, which returns:
#   0 = real infrastructure matches the code (no drift, nothing pending)
#   1 = error (credentials, syntax, API failure)
#   2 = differences found (drift, or code changes not yet applied)
#
# A normal plan is used rather than `-refresh-only` because it respects
# lifecycle ignore_changes, so expected runtime changes don't raise false alarms.
#
# Run by hand, from cron, or from CI (see .github/workflows/drift-detection.yml).
# -----------------------------------------------------------------------------
set -uo pipefail

cd "$(dirname "$0")"

REPORT="drift-report-$(date +%Y%m%d-%H%M%S).txt"

terraform plan -detailed-exitcode -input=false -no-color -lock-timeout=60s > "$REPORT" 2>&1
rc=$?

case "$rc" in
  0)
    echo "OK: no drift. Infrastructure matches the Terraform code."
    rm -f "$REPORT"
    ;;
  2)
    echo "DRIFT DETECTED. Full plan saved to $REPORT"
    echo "------------------------------------------------------------"
    # Show the summary lines: which resources changed and what Terraform would do
    grep -E "has changed|will be|must be|Plan:" "$REPORT" || true
    echo "------------------------------------------------------------"
    # In real life: post to Slack/Teams, or open a Jira ticket here.
    ;;
  *)
    echo "ERROR: terraform plan failed (exit code $rc). See $REPORT"
    ;;
esac

exit "$rc"
