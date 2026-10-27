#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ssm-run.sh: send a Run Command to every instance tagged Role=iis-lab,
# wait for it to finish, and print its output.
#
#   ./ssm-run.sh setup                  install IIS + deploy the site (also resets the lab)
#   ./ssm-run.sh break <scenario>       inject a fault: 1-stopped-pool, 2-crash-loop,
#                                       3-bad-identity, 4-port-conflict, 5-bad-config
#   ./ssm-run.sh patch-scan             Patch Manager scan (reports, installs nothing)
#
# Targeting by tag instead of instance ID is the point: the same command would
# run on 1 server or 500.
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  sed -n '5,10p' "$0"
  exit 1
}

case "${1:-}" in
  setup)
    DOC="IISLab-Setup"
    PARAMS=()
    ;;
  break)
    [ -n "${2:-}" ] || usage
    DOC="IISLab-Break"
    PARAMS=(--parameters "Scenario=$2")
    ;;
  patch-scan)
    DOC="AWS-RunPatchBaseline"
    PARAMS=(--parameters "Operation=Scan")
    ;;
  *)
    usage
    ;;
esac

IID=$(terraform output -raw instance_id)

CMD_ID=$(aws ssm send-command \
  --document-name "$DOC" \
  --targets "Key=tag:Role,Values=iis-lab" \
  "${PARAMS[@]}" \
  --comment "iis-lab: $*" \
  --query Command.CommandId --output text)

echo "Sent $DOC (command ID $CMD_ID) to tag Role=iis-lab. Waiting for it to finish..."

while true; do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" \
    --query Status --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Success|Failed|Cancelled|TimedOut|Undeliverable|Terminated) break ;;
  esac
  echo "  ... $STATUS"
  sleep 10
done

echo "Status: $STATUS"
echo "------------------------------------------------------------"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" \
  --query StandardOutputContent --output text

if [ "$STATUS" != "Success" ]; then
  echo "------------------------- errors ---------------------------"
  aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" \
    --query StandardErrorContent --output text
  exit 1
fi
