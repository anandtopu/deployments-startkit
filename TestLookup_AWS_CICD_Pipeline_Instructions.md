# Deployment Pipeline Instructions for `anandtopu/testlookup`

Target repository: https://github.com/anandtopu/testlookup  
Starter kit source: `starter-kit/` in this folder  
Recommended first AWS target: temporary ECS/Fargate UAT environment for the TestLookup backend API

## 1. What Is Different About TestLookup

`testlookup` is not a single-container app. On the `main` branch, it contains:

- FastAPI backend in `backend/`, production container port `8000`
- React/Vite frontend in `frontend/`, production container port `80`
- MCP server in `mcp/`, container port `8002`
- Runtime dependencies: PostgreSQL, MongoDB, Redis, MinIO
- Existing CI workflow at `.github/workflows/ci.yml`
- Existing cloud/Kubernetes workflows for EKS, GKE, AKS, staging, and production

Because of this, do not overwrite the existing `infra/` or `.github/workflows/ci.yml`. Add the low-cost AWS ECS pipeline as a new UAT pipeline.

## 2. Recommended Rollout Plan

Start with this order:

1. Keep the existing `ci.yml` for normal PR validation.
2. Add a new GitHub Actions workflow named `.github/workflows/aws-ecs-uat.yml`.
3. Add a new Terraform folder named `infra/aws-ecs-uat/`.
4. Build and push only the backend image first.
5. Deploy a temporary ECS/Fargate UAT stack.
6. Run smoke/UAT checks against `http://<alb-dns>/health/live`.
7. Always destroy the temporary UAT stack.

Later, after the backend deploy works, add:

- Frontend container or S3/CloudFront static hosting
- Worker and beat containers
- MCP container
- Persistent AWS services such as RDS, ElastiCache, S3, and DocumentDB or MongoDB Atlas

For the lowest-cost learning setup, use ephemeral sidecar containers for PostgreSQL, MongoDB, Redis, and MinIO inside the same Fargate task. This is only for UAT/testing, not production persistence.

## 3. Local Preparation

Clone the target repo:

```bash
git clone https://github.com/anandtopu/testlookup.git
cd testlookup
git checkout main
git pull
git checkout -b chore/aws-ecs-uat-pipeline
```

From this deployment architecture folder, copy the starter kit into the repo without overwriting existing folders:

```bash
# Run from C:/Users/anand/Downloads/Deployment_architecture
cp -r starter-kit/infra C:/path/to/testlookup/infra/aws-ecs-uat
cp -r starter-kit/scripts C:/path/to/testlookup/scripts/aws-ecs-uat
cp starter-kit/.github/workflows/reusable-aws-ecs-cicd.yml C:/path/to/testlookup/.github/workflows/reusable-aws-ecs-cicd.yml
cp starter-kit/architecture.mmd C:/path/to/testlookup/infra/aws-ecs-uat/architecture.mmd
```

On PowerShell, use:

```powershell
Copy-Item -Recurse .\starter-kit\infra C:\path\to\testlookup\infra\aws-ecs-uat
Copy-Item -Recurse .\starter-kit\scripts C:\path\to\testlookup\scripts\aws-ecs-uat
Copy-Item .\starter-kit\.github\workflows\reusable-aws-ecs-cicd.yml C:\path\to\testlookup\.github\workflows\reusable-aws-ecs-cicd.yml
Copy-Item .\starter-kit\architecture.mmd C:\path\to\testlookup\infra\aws-ecs-uat\architecture.mmd
```

## 4. Bootstrap AWS Foundation

Run this one time from the copied script folder in the `testlookup` checkout.

```bash
cd testlookup

export AWS_REGION="us-east-1"
export PROJECT_NAME="testlookup"
export GITHUB_OWNER="anandtopu"
export GITHUB_REPO="testlookup"

bash scripts/aws-ecs-uat/bootstrap-foundation.sh
```

The script prints the values you need in GitHub:

- `AWS_ROLE_ARN`
- `AWS_REGION`
- `ECR_REPOSITORY`
- `TF_STATE_BUCKET`
- `TF_LOCK_TABLE`
- `CONTAINER_PORT`

The default ECR repository will be named `testlookup`. For the first pipeline, this repository will store the backend image.

## 5. Configure GitHub Secrets and Variables

Go to:

`testlookup -> Settings -> Secrets and variables -> Actions`

Create this repository secret:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | Output from bootstrap script |

Create these repository variables:

| Type | Name | Value |
|---|---|---|
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `ECR_REPOSITORY` | `testlookup` |
| Variable | `TF_STATE_BUCKET` | Output from bootstrap script |
| Variable | `TF_LOCK_TABLE` | Output from bootstrap script |
| Variable | `CONTAINER_PORT` | `8000` |

Create a GitHub Environment:

1. Go to `Settings -> Environments`.
2. Create environment `uat`.
3. Do not add approval rules at first.
4. After the pipeline works, add required reviewers if desired.

## 6. Add the TestLookup AWS UAT Workflow

Create this file in the `testlookup` repository:

`.github/workflows/aws-ecs-uat.yml`

```yaml
name: TestLookup AWS ECS UAT

on:
  workflow_dispatch:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write

jobs:
  pipeline:
    uses: ./.github/workflows/reusable-aws-ecs-cicd.yml
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}
    with:
      project_name: testlookup
      run_deployment: true
      aws_region: ${{ vars.AWS_REGION || 'us-east-1' }}
      ecr_repository: ${{ vars.ECR_REPOSITORY || 'testlookup' }}
      container_port: 8000
      tf_state_bucket: ${{ vars.TF_STATE_BUCKET }}
      tf_lock_table: ${{ vars.TF_LOCK_TABLE }}
      terraform_working_directory: infra/aws-ecs-uat
      ci_command: |
        python -m pip install --upgrade pip
        python scripts/quality_gate.py
        echo "Full PR CI remains in .github/workflows/ci.yml"
      uat_test_command: |
        set -euo pipefail
        echo "Testing ${APP_BASE_URL}"
        curl --fail --silent --show-error "${APP_BASE_URL}/health/live"
        curl --fail --silent --show-error "${APP_BASE_URL}/docs" >/dev/null
```

Why this workflow is manual and main-only:

- PRs should keep using the existing `ci.yml`.
- UAT deploys cost AWS money.
- The cleanup job will destroy the environment after tests finish.

## 7. Modify the Reusable Workflow for TestLookup Backend Builds

Open:

`.github/workflows/reusable-aws-ecs-cicd.yml`

Find the build step:

```yaml
- name: Build and push Docker image
```

Replace its shell script with this TestLookup-specific version:

```yaml
      - name: Build and push Docker image
        id: build
        env:
          ECR_REGISTRY: ${{ steps.ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        shell: bash
        run: |
          set -euo pipefail

          STAGED_SDK="./backend/__client_sdks_staged"
          rm -rf "${STAGED_SDK}"
          mkdir -p "${STAGED_SDK}"
          rsync -a \
            --exclude='.pytest_cache' \
            --exclude='__pycache__' \
            --exclude='*.pyc' \
            --exclude='.venv' \
            --exclude='venv' \
            --exclude='node_modules' \
            --exclude='.tox' \
            --exclude='.mypy_cache' \
            --exclude='.ruff_cache' \
            --exclude='target' \
            --exclude='build' \
            --exclude='*.egg-info' \
            --exclude='.coverage' \
            --exclude='htmlcov' \
            --exclude='.DS_Store' \
            ./client/ "${STAGED_SDK}/"

          IMAGE_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
          docker build \
            --target production \
            -f backend/Dockerfile \
            -t "${IMAGE_URI}" \
            ./backend
          docker push "${IMAGE_URI}"
          echo "image_uri=${IMAGE_URI}" >> "${GITHUB_OUTPUT}"
```

This is required because TestLookup's backend Dockerfile expects the client SDK staging folder during production builds.

## 8. Adjust Terraform Variables for TestLookup

Edit:

`infra/aws-ecs-uat/terraform.tfvars.example`

Use:

```hcl
aws_region     = "us-east-1"
project_name   = "testlookup"
environment    = "uat-local"
image_uri      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/testlookup:replace-me"
container_port = 8000

desired_count     = 1
task_cpu          = 1024
task_memory       = 2048
health_check_path = "/health/live"

app_environment_variables = {
  APP_ENV             = "production"
  AI_OFFLINE_MODE     = "true"
  ANALYSIS_MODE       = "rules"
  POSTGRES_HOST       = "127.0.0.1"
  POSTGRES_PORT       = "5432"
  POSTGRES_DB         = "testlookup"
  POSTGRES_USER       = "testlookup_user"
  POSTGRES_PASSWORD   = "testlookup_uat_password"
  DATABASE_URL        = "postgresql+asyncpg://testlookup_user:testlookup_uat_password@127.0.0.1:5432/testlookup"
  MONGO_HOST          = "127.0.0.1"
  MONGO_PORT          = "27017"
  MONGO_DB            = "testlookup_logs"
  MONGO_USER          = "testlookup"
  MONGO_PASSWORD      = "testlookup_uat_password"
  MONGO_URI           = "mongodb://testlookup:testlookup_uat_password@127.0.0.1:27017/testlookup_logs?authSource=admin"
  REDIS_URL           = "redis://127.0.0.1:6379/0"
  CELERY_BROKER_URL   = "redis://127.0.0.1:6379/0"
  CELERY_RESULT_BACKEND = "redis://127.0.0.1:6379/1"
  MINIO_ENDPOINT      = "127.0.0.1:9000"
  MINIO_ACCESS_KEY    = "testlookup_minio"
  MINIO_SECRET_KEY    = "testlookup_uat_secret"
  MINIO_BUCKET_NAME   = "test-telemetry"
  MINIO_USE_SSL       = "false"
  APP_SECRET_KEY      = "replace-with-generated-uat-secret"
  JWT_SECRET_KEY      = "replace-with-generated-uat-secret"
  WEBHOOK_SECRET      = "replace-with-generated-uat-secret"
}

tags = {
  Owner = "anandtopu"
}
```

For real use, generate the secret values:

```bash
openssl rand -hex 32
```

## 9. Important Terraform Change for TestLookup Dependencies

The starter kit's default Terraform runs one app container. TestLookup's backend also needs PostgreSQL, MongoDB, Redis, and MinIO.

For the first UAT pipeline, update `infra/aws-ecs-uat/main.tf` so `aws_ecs_task_definition.app.container_definitions` contains these containers:

- `postgres`
- `mongo`
- `redis`
- `minio`
- `app`

The `app` container should be the only container exposed through the load balancer on port `8000`.

Beginner shortcut:

1. Keep the existing starter-kit networking, IAM, ALB, target group, and ECS service.
2. Replace only the `container_definitions = jsonencode([...])` block.
3. Add sidecar containers before the `app` container.
4. Set the app container environment values listed in section 8.
5. Add `dependsOn` to the app container so it starts after dependencies are healthy.

Use this dependency pattern in the app container:

```hcl
dependsOn = [
  { containerName = "postgres", condition = "HEALTHY" },
  { containerName = "mongo", condition = "START" },
  { containerName = "redis", condition = "HEALTHY" },
  { containerName = "minio", condition = "START" }
]
```

For an even simpler first smoke test, create managed dependencies outside the task and keep the starter kit as one container. In that case, set `DATABASE_URL`, `MONGO_URI`, `REDIS_URL`, and `MINIO_ENDPOINT` to the managed service endpoints.

## 10. Commit and Push

From the `testlookup` repo:

```bash
git status
git add .github/workflows/aws-ecs-uat.yml \
        .github/workflows/reusable-aws-ecs-cicd.yml \
        infra/aws-ecs-uat \
        scripts/aws-ecs-uat
git commit -m "Add low-cost AWS ECS UAT pipeline"
git push -u origin chore/aws-ecs-uat-pipeline
```

Open a pull request into `main`.

Let the existing `TestLookup — CI/CD` workflow pass.

After merge, the new `TestLookup AWS ECS UAT` workflow will run on pushes to `main`. You can also trigger it manually from the GitHub Actions tab.

## 11. First Manual Run

In GitHub:

1. Open `Actions`.
2. Select `TestLookup AWS ECS UAT`.
3. Click `Run workflow`.
4. Select branch `main`.
5. Start the run.

Watch these jobs:

1. `CI tests`
2. `Build and push image`
3. `Deploy temporary UAT stack`
4. `UAT, E2E, and regression tests`
5. `Cleanup temporary UAT stack`

The most important job is cleanup. It must run even if UAT tests fail.

## 12. Validate in AWS

During the deploy job, check:

- ECR has image `testlookup:<commit-sha>`
- ECS has a temporary cluster and service
- EC2 Load Balancers has a temporary ALB
- CloudWatch has `/ecs/testlookup-...` logs
- S3 state bucket has a UAT state file

After cleanup, confirm:

- ECS service is deleted
- ECS cluster is deleted
- ALB is deleted
- Target group is deleted
- VPC/subnets/security groups are deleted

The ECR image and Terraform state bucket remain by design.

## 13. Common Failures

### Backend image build fails because `__client_sdks_staged` is missing

Confirm the build step includes the `rsync ./client/ ./backend/__client_sdks_staged/` staging command.

### ECS task starts but backend is unhealthy

Check CloudWatch logs. The most likely causes are:

- `DATABASE_URL` is wrong
- PostgreSQL sidecar is not ready before Alembic runs
- `MONGO_URI` credentials do not match the Mongo sidecar
- Container port is not `8000`
- Health path is not `/health/live`

### Terraform destroy fails

Run the cleanup workflow again, or run locally:

```bash
export AWS_REGION="us-east-1"
export TF_STATE_BUCKET="<value from GitHub vars>"
export TF_LOCK_TABLE="<value from GitHub vars>"
export TF_STATE_KEY="uat/testlookup/<github-run-id>.tfstate"
export PROJECT_NAME="testlookup"
export ENVIRONMENT="uat-<github-run-id>"
export IMAGE_URI="<account>.dkr.ecr.us-east-1.amazonaws.com/testlookup:<sha>"
export CONTAINER_PORT="8000"
export INFRA_DIR="infra/aws-ecs-uat"

bash scripts/aws-ecs-uat/cleanup-environment.sh
```

### AWS OIDC access denied

Check the IAM role trust policy. It should include:

```text
repo:anandtopu/testlookup:*
```

After it works, tighten this for production environments.

## 14. Production Path After UAT Works

Do not use sidecar databases for production. Move toward:

- Backend: ECS Fargate
- Frontend: S3 + CloudFront, or ECS Fargate nginx container
- PostgreSQL: RDS PostgreSQL
- Redis: ElastiCache Serverless or small Redis instance
- Object storage: S3 instead of MinIO
- MongoDB: MongoDB Atlas, DocumentDB, or remove Mongo dependency if the app can be consolidated
- Secrets: AWS Secrets Manager or SSM Parameter Store
- HTTPS: ACM certificate on ALB or CloudFront
- Deploy environments: `uat`, `staging`, `production`
- Production GitHub Environment with approval gate

## 15. Minimal New Files Summary

Add these to `anandtopu/testlookup`:

```text
.github/workflows/aws-ecs-uat.yml
.github/workflows/reusable-aws-ecs-cicd.yml
infra/aws-ecs-uat/
scripts/aws-ecs-uat/
```

Do not delete or replace:

```text
.github/workflows/ci.yml
infra/
k8s/
docker-compose.yml
```

The new AWS ECS UAT pipeline should live alongside the existing CI/Kubernetes deployment paths.
