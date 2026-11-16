# CAD SIS 3 — an order system as code

An order is placed over HTTP, published as a domain event, queued, and processed
idempotently. Everything is created from the templates in `infra/`; nothing needs a
console click.

```
 client ──HTTP──> ALB ──> ECS Fargate service (private subnets)
                              │  POST /orders  (task role: sns:Publish on one topic)
                              ▼
                          SNS topic "OrderPlaced"
                              │  raw delivery
                              ▼
                          SQS queue ──(5 failed receives)──> DLQ (14 days)
                              │  batch 10, window 5 s, ReportBatchItemFailures, max concurrency 2
                              ▼
                          Lambda consumer ──conditional write──> DynamoDB (key = orderId)
```

## Deploy (one command)

Prerequisites: AWS CLI, Docker, credentials for the target account.
AWS CloudShell has all of it.

```bash
./deploy.sh cad          # creates cad-network, cad-messaging, cad-app (about 10 minutes)
```

The script lints the templates (if `cfn-lint` is installed), deploys the three stacks
with `aws cloudformation deploy` (a change set per stack), builds the image for
`linux/amd64`, pushes it to ECR with a git-SHA tag and starts the tasks. It prints the
service URL at the end.

## Check that it works

```bash
./smoke-test.sh cad              # health check, one order, a duplicate, a poison message
./smoke-test.sh cad --wait-dlq   # also waits until the poison message reaches the DLQ
```

Expected: `items for smoke-...: 1` (the duplicate was skipped) and, after about
5 minutes, one message in the DLQ.

## Reproducibility test (a second copy under a new name)

```bash
./deploy.sh cad2         # a second, independent copy; all physical names are generated
```

## Remove everything

```bash
./destroy.sh cad         # app, messaging, network stacks; also empties ECR and deletes the retained table
```

While deployed, the NAT gateway and the load balancer cost money (about 0.07 USD/hour per copy).

## Layout

| Path | What it is |
|---|---|
| `infra/network.yaml` | VPC, 2 public + 2 private subnets, one NAT gateway; subnet and VPC IDs are exported |
| `infra/messaging.yaml` | SNS topic, SQS queue + DLQ, queue policy, subscription, DynamoDB table, Lambda consumer (code inline), log group |
| `infra/app.yaml` | ECR repository, ECS cluster, task definition, service, ALB, target group, security groups, two IAM roles, log group |
| `app/` | the container: `app.py`, `Dockerfile`, `requirements.txt` |
| `tests/test_code.py` | local tests for the consumer and the app (`pytest -q tests`) |
| `deploy.sh`, `destroy.sh`, `smoke-test.sh` | deploy, tear down, end-to-end check |

Stacks are split by rate of change and linked by exports: `app` imports the VPC and subnets
from `network` and the topic ARN from `messaging`. Deploy order: network, messaging, app;
delete order is the reverse.

## What the grader's checklist maps to

| Requirement | Where |
|---|---|
| SQS queue with a DLQ and maxReceiveCount | `messaging.yaml`: `OrdersQueue` (RedrivePolicy, maxReceiveCount 5, visibility 60 s), `OrdersDLQ` (14 days) |
| A domain event through SNS | `OrderEventsTopic`; the container publishes it from `POST /orders` |
| Idempotent consumer, deduplication key | `ConsumerFunction`: conditional write on `ORDER#<orderId>`; the key is the business key, not the SQS message id |
| ECR with immutable tags and a lifecycle policy | `app.yaml`: `Repository` |
| Fargate service behind an ALB, two separate roles | `Service`, `LoadBalancer`, `ExecutionRole` (pull image, write logs), `TaskRole` (sns:Publish on one topic) |
| Logs with retention | `LogGroup` (app) and `ConsumerLogGroup` (consumer), 7 days |
| Parameters, no secrets | `Env`, `ImageTag`, stack names; sizes come from a `Mappings` table; there are no secrets anywhere |
| README with one deploy command | this file |

## Parameters

| Parameter | Stack | Meaning |
|---|---|---|
| `Env` (`dev`, `prod`) | all | selects sizes in `app.yaml` (`dev` 0.25 vCPU / 0.5 GB, `prod` 0.5 vCPU / 1 GB) |
| `VpcCidr` | network | VPC range, default `10.20.0.0/16` |
| `NetworkStackName`, `MessagingStackName` | app | names of the stacks whose exports are imported |
| `ImageTag` | app | image to run; `none` creates the stack with zero tasks (first run only) |

## Design decisions and honest limits

- Tasks run in private subnets without public IPs. Outbound traffic (ECR, CloudWatch) goes
  through **one** NAT gateway: cheaper, but a single point of failure for outbound traffic.
- The load balancer listens on HTTP only. HTTPS needs a domain and an ACM certificate.
- The DynamoDB table has `DeletionPolicy: Retain` and point-in-time recovery, so deleting the
  stack never deletes data by accident. `destroy.sh` deletes it explicitly.
- All physical names are generated, so any number of copies can run side by side and
  a rename can never force a replacement.
- ECR image scanning reports findings but does not block a deploy.
- Image tags are immutable: a changed file needs a new commit (new tag). Uncommitted changes
  get a timestamp suffix automatically.
- The templates were checked with `cfn-lint`; the code was tested locally with `pytest`.

## Validate before deploying

```bash
pip install cfn-lint
cfn-lint infra/*.yaml
```

Review the change set before executing it:
`aws cloudformation deploy ... --no-execute-changeset`, then
`aws cloudformation describe-change-set` (look at the `Replacement` column).
