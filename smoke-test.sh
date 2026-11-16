#!/usr/bin/env bash
# End-to-end check:   ./smoke-test.sh <name> [--wait-dlq]
set -euo pipefail
NAME="${1:?usage: ./smoke-test.sh <name> [--wait-dlq]}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
out() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
URL="$(out "${NAME}-app" ServiceUrl)"
TOPIC="$(out "${NAME}-messaging" TopicArn)"
TABLE="$(out "${NAME}-messaging" TableName)"
DLQ="$(out "${NAME}-messaging" DlqUrl)"
ID="smoke-$(date +%s)"

echo "1) health check through the load balancer"
curl -fsS "${URL}health"; echo

echo "2) place order ${ID} through the container (POST /orders -> SNS)"
curl -fsS -X POST "${URL}orders" -d "{\"orderId\":\"${ID}\",\"total\":10}"; echo

echo "3) publish the SAME order again straight to SNS (duplicate delivery)"
aws sns publish --region "$REGION" --topic-arn "$TOPIC" --message "{\"orderId\":\"${ID}\",\"total\":10}" >/dev/null

echo "4) publish a poison message"
aws sns publish --region "$REGION" --topic-arn "$TOPIC" --message '{"poison": true}' >/dev/null

echo "waiting 20 s for the consumer ..."; sleep 20
COUNT="$(aws dynamodb query --region "$REGION" --table-name "$TABLE" \
  --key-condition-expression 'pk = :p' \
  --expression-attribute-values "{\":p\":{\"S\":\"ORDER#${ID}\"}}" \
  --select COUNT --query Count --output text)"
echo "items for ${ID}: ${COUNT}   (expected 1 - the duplicate was skipped)"

dlq_count() {
  aws sqs get-queue-attributes --region "$REGION" --queue-url "$DLQ" \
    --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text
}
echo "messages in the DLQ now: $(dlq_count)   (the poison message arrives after 5 failed receives, about 5-6 minutes)"
if [ "${2:-}" = "--wait-dlq" ]; then
  for _ in $(seq 1 16); do
    [ "$(dlq_count)" -ge 1 ] && { echo "poison message is in the DLQ"; exit 0; }
    sleep 30
  done
  echo "DLQ is still empty after 8 minutes" >&2; exit 1
fi
