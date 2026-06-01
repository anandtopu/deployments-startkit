#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION, for example us-east-1}"
: "${PROJECT_NAME:?Set PROJECT_NAME, for example myapp}"
: "${GITHUB_OWNER:?Set GITHUB_OWNER, for example your GitHub user or org}"
: "${GITHUB_REPO:?Set GITHUB_REPO, for example your repository name}"

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
ROLE_NAME="${PROJECT_NAME}-github-actions-deploy-role"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
ECR_REPOSITORY="${PROJECT_NAME}"
TF_STATE_BUCKET="${PROJECT_NAME}-tfstate-${AWS_ACCOUNT_ID}-${AWS_REGION}"
TF_LOCK_TABLE="${PROJECT_NAME}-tf-locks"

echo "AWS account: ${AWS_ACCOUNT_ID}"
echo "AWS region:  ${AWS_REGION}"
echo "GitHub repo: ${GITHUB_OWNER}/${GITHUB_REPO}"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "OIDC provider already exists: ${OIDC_PROVIDER_ARN}"
else
  echo "Creating GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
fi

TRUST_POLICY="$(mktemp)"
cat > "${TRUST_POLICY}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_OWNER}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
JSON

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Updating role trust policy: ${ROLE_NAME}"
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "file://${TRUST_POLICY}" >/dev/null
else
  echo "Creating role: ${ROLE_NAME}"
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY}" >/dev/null
fi

PERMISSIONS_POLICY="$(mktemp)"
cat > "${PERMISSIONS_POLICY}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:CreateRepository",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:PutLifecyclePolicy",
        "ecr:UploadLayerPart"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": [
        "arn:aws:s3:::${TF_STATE_BUCKET}",
        "arn:aws:s3:::${TF_STATE_BUCKET}/*",
        "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${TF_LOCK_TABLE}"
      ]
    },
    {
      "Sid": "ManageTemporaryEcsStack",
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "elasticloadbalancing:*",
        "ecs:*",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "logs:*",
        "application-autoscaling:*"
      ],
      "Resource": "*"
    }
  ]
}
JSON

echo "Attaching inline deploy policy to role..."
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${PROJECT_NAME}-github-actions-deploy-policy" \
  --policy-document "file://${PERMISSIONS_POLICY}" >/dev/null

if aws ecr describe-repositories --repository-names "${ECR_REPOSITORY}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "ECR repository already exists: ${ECR_REPOSITORY}"
else
  echo "Creating ECR repository: ${ECR_REPOSITORY}"
  aws ecr create-repository \
    --repository-name "${ECR_REPOSITORY}" \
    --image-scanning-configuration scanOnPush=true \
    --region "${AWS_REGION}" >/dev/null
fi

LIFECYCLE_POLICY="$(mktemp)"
cat > "${LIFECYCLE_POLICY}" <<JSON
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep only the latest 20 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 20
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
JSON

aws ecr put-lifecycle-policy \
  --repository-name "${ECR_REPOSITORY}" \
  --lifecycle-policy-text "file://${LIFECYCLE_POLICY}" \
  --region "${AWS_REGION}" >/dev/null

if aws s3api head-bucket --bucket "${TF_STATE_BUCKET}" >/dev/null 2>&1; then
  echo "Terraform state bucket already exists: ${TF_STATE_BUCKET}"
else
  echo "Creating Terraform state bucket: ${TF_STATE_BUCKET}"
  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${TF_STATE_BUCKET}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${TF_STATE_BUCKET}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi

  aws s3api put-bucket-versioning \
    --bucket "${TF_STATE_BUCKET}" \
    --versioning-configuration Status=Enabled >/dev/null

  aws s3api put-bucket-encryption \
    --bucket "${TF_STATE_BUCKET}" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
fi

if aws dynamodb describe-table --table-name "${TF_LOCK_TABLE}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Terraform lock table already exists: ${TF_LOCK_TABLE}"
else
  echo "Creating Terraform lock table: ${TF_LOCK_TABLE}"
  aws dynamodb create-table \
    --table-name "${TF_LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" >/dev/null
fi

rm -f "${TRUST_POLICY}" "${PERMISSIONS_POLICY}" "${LIFECYCLE_POLICY}"

cat <<EOF

Bootstrap complete.

Add this GitHub repository secret:
AWS_ROLE_ARN=${ROLE_ARN}

Add these GitHub repository variables:
AWS_REGION=${AWS_REGION}
ECR_REPOSITORY=${ECR_REPOSITORY}
TF_STATE_BUCKET=${TF_STATE_BUCKET}
TF_LOCK_TABLE=${TF_LOCK_TABLE}
CONTAINER_PORT=8080

EOF

