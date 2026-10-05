# Module 7 — DynamoDB Table with AWS SAM — dev & prod via SAM Pipelines + GitHub Actions

An Amazon DynamoDB **Orders** table defined in an AWS SAM template and deployed to two
isolated environments (**dev** and **prod**) by two separate GitHub Actions pipelines,
each with its own SAM pipeline resources and its own S3 artifact bucket.

## What gets deployed

| Setting | Value |
|---|---|
| Table name | `orders-dev` / `orders-prod` |
| Billing mode | **On-Demand** (`PAY_PER_REQUEST`) |
| Table class | **Standard-Infrequent Access** (`STANDARD_INFREQUENT_ACCESS`), not the default `STANDARD` |
| Partition key | `OrderId` (String) |
| Named non-key attributes | `CustomerId` (S), `OrderStatus` (S), `CreatedAt` (S, ISO-8601) and free-form ones like `Amount` (N) |
| GSI 1 | `CustomerIndex`: `CustomerId` (HASH) + `CreatedAt` (RANGE), projection ALL. Answers "orders for a customer, by date". |
| GSI 2 | `StatusIndex`: `OrderStatus` (HASH) + `CreatedAt` (RANGE), projection ALL. Answers "all PENDING orders, by date". |
| Prod-only safeguards | Deletion protection, Point-in-Time Recovery, `DeletionPolicy: Retain` |

All of it is in [`template.yaml`](template.yaml).

## Architecture

```
            push to develop                               push to main (via PR)
                  │                                              │
   .github/workflows/pipeline-dev.yml              .github/workflows/pipeline-prod.yml
   validate → build → package → deploy → verify    validate → build → package → deploy → verify
                  │  OIDC (no access keys)                       │  OIDC (no access keys)
                  ▼                                              ▼
 ┌────── dev SAM pipeline resources ──────┐      ┌────── prod SAM pipeline resources ─────┐
 │ PipelineExecutionRole (develop only)   │      │ PipelineExecutionRole (main only)      │
 │ S3 artifact bucket (dev)               │      │ S3 artifact bucket (prod)              │
 │ CFN exec role → orders-dev ONLY        │      │ CFN exec role → orders-prod ONLY       │
 └────────────────┬───────────────────────┘      └────────────────┬───────────────────────┘
                  ▼                                               ▼
     stack module7-dynamodb-sam-dev → orders-dev        stack module7-dynamodb-sam-prod → orders-prod
```

* **Separate pipelines.** The auto-generated multi-stage SAM workflow is split into
  `pipeline-dev.yml` and `pipeline-prod.yml`. Each one deploys only its own stack,
  with its own role, bucket and parameters.
* **Separate artifact buckets.** `sam pipeline bootstrap` runs once per stage, so each
  environment gets its own artifact bucket. See [`.aws-sam/pipeline/pipelineconfig.toml`](.aws-sam/pipeline/pipelineconfig.toml).
* **Branch-scoped trust.** The dev role's OIDC trust policy only accepts `refs/heads/develop`,
  and the prod role only accepts `refs/heads/main`. A dev run can't get prod credentials.
* **Least privilege.** SAM's default CloudFormation execution role has
  AdministratorAccess. This project replaces it with
  [`bootstrap/env-iam.yaml`](bootstrap/env-iam.yaml), which only allows actions on
  `orders-<env>`. That template also gives the pipeline role a scoped policy for the
  post-deploy smoke test.
* **Automated verification.** After every deployment, [`scripts/verify-table.sh`](scripts/verify-table.sh)
  checks the billing mode, the table class and that both GSIs are ACTIVE. It then runs a
  CRUD smoke test (put → get → update → query both GSIs → delete).

## Repository layout

```
template.yaml                         SAM template (the DynamoDB table)
samconfig.toml                        per-env deploy config (dev / prod) for local use
.aws-sam/pipeline/pipelineconfig.toml output of `sam pipeline bootstrap` (dev + prod stages)
.github/workflows/pipeline-dev.yml    dev pipeline   (branch: develop)
.github/workflows/pipeline-prod.yml   prod pipeline  (branch: main)
bootstrap/env-iam.yaml                least-privilege CFN exec role + smoke-test policy per env
scripts/verify-table.sh               post-deploy config assertions + CRUD smoke test
```

## One-time bootstrap (already done for this account / eu-north-1)

```bash
# 1. Least-privilege CloudFormation execution role per environment
for e in dev prod; do
  aws cloudformation deploy --stack-name module7-dynamodb-sam-$e-iam \
    --template-file bootstrap/env-iam.yaml --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides Environment=$e
done

# 2. SAM pipeline resources per stage (OIDC role + dedicated artifact bucket)
sam pipeline bootstrap --stage dev  --deployment-branch develop ...   # see pipelineconfig.toml
sam pipeline bootstrap --stage prod --deployment-branch main    ...

# 3. Attach the smoke-test policy to each pipeline execution role
aws cloudformation deploy --stack-name module7-dynamodb-sam-<env>-iam ... \
  --parameter-overrides Environment=<env> PipelineExecutionRoleName=<role-name>
```

## Deploying

| Environment | How |
|---|---|
| dev | Push or merge to `develop`. You can also run **Pipeline - dev** by hand from the Actions tab. |
| prod | Open a PR from `develop` to `main` and merge it. You can also run **Pipeline - prod** by hand on `main`. |

Local deploy (optional, uses `samconfig.toml`): `sam build && sam deploy --config-env dev`

## Manual verification in the AWS Console (CRUD)

Console → **DynamoDB** → Region **Europe (Stockholm) eu-north-1** → **Tables** → `orders-dev`.

1. **Check the config.** On the *Overview* tab, read-write capacity mode should be
   On-demand and table class should be DynamoDB Standard-IA. The *Indexes* tab should
   list `CustomerIndex` and `StatusIndex`.
2. **Create.** Go to *Explore table items* → **Create item** → *JSON view*:
   ```json
   {
     "OrderId":     {"S": "ORD-1001"},
     "CustomerId":  {"S": "CUST-42"},
     "OrderStatus": {"S": "PENDING"},
     "CreatedAt":   {"S": "2026-10-05T10:00:00Z"},
     "Amount":      {"N": "59.99"}
   }
   ```
   Add a second one (`ORD-1002`, `CUST-42`, `SHIPPED`, `2026-10-05T11:00:00Z`).
3. **Read.** Choose *Query* → table `orders-dev` → `OrderId = ORD-1001`.
4. **Query a GSI.** Choose *Query* → index `CustomerIndex` → `CustomerId = CUST-42`, which
   returns both orders. Then choose index `StatusIndex` → `OrderStatus = PENDING`.
5. **Update.** Open `ORD-1001`, change `OrderStatus` to `SHIPPED`, and save.
6. **Delete.** Select `ORD-1002` → *Actions* → **Delete items**.

You can run the same steps from the CLI with `./scripts/verify-table.sh orders-dev eu-north-1`.

## Teardown

```bash
aws cloudformation delete-stack --stack-name module7-dynamodb-sam-dev
# prod: turn off deletion protection on orders-prod first. The table is retained on stack delete.
aws dynamodb update-table --table-name orders-prod --no-deletion-protection-enabled
aws cloudformation delete-stack --stack-name module7-dynamodb-sam-prod
aws dynamodb delete-table --table-name orders-prod
# then empty the artifact buckets and delete aws-sam-cli-managed-{dev,prod}-pipeline-resources
# and module7-dynamodb-sam-{dev,prod}-iam
```
