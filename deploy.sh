#!/usr/bin/env bash
# One command deploys the whole system:   ./deploy.sh <name> [dev|prod]
#   <name>  prefix for the three stacks: <name>-network, <name>-messaging, <name>-app
# Needs: AWS CLI, Docker, credentials for the target account (AWS CloudShell has all of it).
set -euo pipefail
cd "$(dirname "$0")"

NAME="${1:?usage: ./deploy.sh <name> [dev|prod]}"
ENV="${2:-dev}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
TAGS=(Project=cad-sis3 "Env=${ENV}")

out() {  # out <stack> <OutputKey>
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

deploy() {  # deploy <stack> <template> [Key=Value ...]
  local stack="$1" template="$2"; shift 2
  aws cloudformation deploy --region "$REGION" --stack-name "$stack" \
    --template-file "$template" --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset --tags "${TAGS[@]}" \
    --parameter-overrides "$@"
}

if command -v cfn-lint >/dev/null 2>&1; then
  echo "== lint"; cfn-lint infra/*.yaml
fi

echo "== 1/5 network stack"
deploy "${NAME}-network" infra/network.yaml Env="$ENV"

echo "== 2/5 messaging stack (SNS, SQS + DLQ, Lambda consumer, DynamoDB)"
deploy "${NAME}-messaging" infra/messaging.yaml Env="$ENV"

APP_PARAMS=(Env="$ENV" NetworkStackName="${NAME}-network" MessagingStackName="${NAME}-messaging")

echo "== 3/5 app stack without tasks (creates the ECR repository first)"
if ! aws cloudformation describe-stacks --region "$REGION" --stack-name "${NAME}-app" >/dev/null 2>&1; then
  deploy "${NAME}-app" infra/app.yaml "${APP_PARAMS[@]}" ImageTag=none
fi

echo "== 4/5 build and push the image"
REPO_URI="$(out "${NAME}-app" RepositoryUri)"
REPO_NAME="$(out "${NAME}-app" RepositoryName)"
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then TAG="${TAG}-$(date +%H%M%S)"; fi  # uncommitted changes
if aws ecr describe-images --region "$REGION" --repository-name "$REPO_NAME" \
     --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "image ${TAG} already in ECR (tags are immutable), skipping build"
else
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO_URI%%/*}"
  docker build --platform linux/amd64 -t "${REPO_URI}:${TAG}" app/
  docker push "${REPO_URI}:${TAG}"
fi

echo "== 5/5 app stack with the image (starts the Fargate tasks)"
deploy "${NAME}-app" infra/app.yaml "${APP_PARAMS[@]}" ImageTag="$TAG"

echo
echo "Done. Service URL: $(out "${NAME}-app" ServiceUrl)"
echo "Try it:   ./smoke-test.sh ${NAME}"
echo "Remove:   ./destroy.sh ${NAME}     (NAT gateway and ALB cost money while they exist)"
