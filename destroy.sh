#!/usr/bin/env bash
# Removes everything deploy.sh created:   ./destroy.sh <name>
set -euo pipefail
NAME="${1:?usage: ./destroy.sh <name>}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

exists() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1; }
out() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
remove() {
  echo "== deleting stack $1"
  aws cloudformation delete-stack --region "$REGION" --stack-name "$1"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$1"
}

# order matters: the app stack imports exports of the other two
if exists "${NAME}-app"; then
  REPO="$(out "${NAME}-app" RepositoryName)"
  IDS="$(aws ecr list-images --region "$REGION" --repository-name "$REPO" --query 'imageIds[*]' --output json)"
  if [ "$IDS" != "[]" ]; then   # a repository with images cannot be deleted
    aws ecr batch-delete-image --region "$REGION" --repository-name "$REPO" --image-ids "$IDS" >/dev/null
  fi
  remove "${NAME}-app"
fi

if exists "${NAME}-messaging"; then
  TABLE="$(out "${NAME}-messaging" TableName)"
  remove "${NAME}-messaging"
  # the table has DeletionPolicy: Retain, so the stack leaves it behind on purpose
  echo "== deleting retained table $TABLE"
  aws dynamodb delete-table --region "$REGION" --table-name "$TABLE" >/dev/null
fi

if exists "${NAME}-network"; then remove "${NAME}-network"; fi
echo "Done. Check the Cost Explorer tomorrow for anything still running."
