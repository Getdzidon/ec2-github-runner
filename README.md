# EC2 GitHub Actions Self-Hosted Runner

Self-hosted GitHub Actions runner on an Ubuntu EC2 instance. Cheaper and simpler than ARC/Kubernetes for solo developers and small teams.

GitHub account: **getdzidon** — `https://github.com/getdzidon`

---

## How it works

```
Manual steps (one-time)  →  push to main  →  deploy-runner.yaml runs  →  runner is live on EC2
```

The deploy pipeline provisions an EC2 instance, injects a fresh GitHub registration token, and the instance registers itself with GitHub on first boot via `bootstrap-runner.sh` as user data. No manual SSH required.

---

## How the runner registers itself

```
deploy-runner.yaml (GitHub Actions)
        │
        ├── 1. Generates a runner registration token via GitHub API
        ├── 2. Stores the token in SSM Parameter Store (SecureString)
        ├── 3. Terminates any existing runner instance
        └── 4. Launches a new EC2 instance with bootstrap-runner.sh as user data
                        │
                        └── EC2 first boot (bootstrap-runner.sh)
                                │
                                ├── Installs AWS CLI + runner dependencies
                                ├── Fetches token from SSM
                                ├── Downloads and installs runner binary
                                ├── Registers with GitHub
                                └── Starts runner as systemd service
```

---

## Project structure

```
ec2-github-runner/
├── .github/
│   ├── workflows/
│   │   ├── deploy-runner.yaml    # GitOps pipeline — provisions the EC2 runner (automated)
│   │   └── example-job.yaml      # Example CI job that runs ON the EC2 runner
│   └── dependabot.yml
├── scripts/
│   └── bootstrap-runner.sh       # EC2 user data — installs, registers, and starts the runner
├── versions.env                  # Pinned runner version and instance type (updated by Renovate)
├── renovate.json                 # Automated runner version update config
├── .gitignore
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| aws cli | ≥ 2.x | [docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| An AWS account | — | with permissions to create EC2, IAM, SSM, VPC resources |
| A GitHub account | — | `https://github.com/getdzidon` |

---

## ⚠️ Manual steps — do these first, in order

These steps cannot be automated. Complete all of them before pushing to `main`.

---

### Step 1 — Create a GitHub Personal Access Token (PAT)

The deploy pipeline uses a PAT to call the GitHub API and generate a short-lived runner registration token.

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
2. Set:
   - **Token name**: `ec2-runner-deploy`
   - **Expiration**: your preference (90 days recommended — set a calendar reminder to rotate it)
   - **Resource owner**: `getdzidon`
   - **Repository access**: *Only select repositories* → select `ec2-github-runner`
3. Under **Permissions → Organization permissions**:
   - `Self-hosted runners` → Read & Write
4. Click **Generate token** and copy it immediately — you cannot view it again

You will store this token as a GitHub Actions secret in Step 5.

---

### Step 2 — Create the AWS infrastructure

All resources below must exist before the pipeline can run. Create them via the AWS Console or AWS CLI.

---

#### 2a — VPC and subnet

You need a subnet with outbound internet access (for the runner to reach GitHub). Use an existing VPC/subnet or create one.

If creating new:

```bash
# Create VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --query "Vpc.VpcId" --output text)

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames

# Create public subnet
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 \
  --query "Subnet.SubnetId" --output text)

# Attach internet gateway
IGW_ID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

# Route table
RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query "RouteTable.RouteTableId" --output text)
aws ec2 create-route --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

echo "Subnet ID: $SUBNET_ID"
```

Note the **Subnet ID** — you need it in Step 5.

---

#### 2b — Security group

The runner only needs outbound HTTPS to reach GitHub. No inbound rules are needed.

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name "github-runner-sg" \
  --description "GitHub Actions EC2 runner — outbound only" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" --output text)

# Allow outbound HTTPS only
aws ec2 authorize-security-group-egress \
  --group-id "$SG_ID" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

# Remove the default allow-all egress rule
aws ec2 revoke-security-group-egress \
  --group-id "$SG_ID" \
  --protocol -1 --port -1 --cidr 0.0.0.0/0

echo "Security Group ID: $SG_ID"
```

Note the **Security Group ID** — you need it in Step 5.

---

#### 2c — IAM role for the EC2 instance

The EC2 instance needs permission to read the registration token from SSM.

```bash
# Create trust policy
cat > /tmp/ec2-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

# Create role
aws iam create-role \
  --role-name github-runner-ec2-role \
  --assume-role-policy-document file:///tmp/ec2-trust.json

# Attach SSM read policy
cat > /tmp/runner-ssm-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ],
    "Resource": [
      "arn:aws:ssm:*:*:parameter/github-runner/*"
    ]
  }]
}
EOF

aws iam put-role-policy \
  --role-name github-runner-ec2-role \
  --policy-name SSMReadRunnerParams \
  --policy-document file:///tmp/runner-ssm-policy.json

# Create instance profile and attach role
aws iam create-instance-profile --instance-profile-name github-runner-ec2-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name github-runner-ec2-profile \
  --role-name github-runner-ec2-role
```

---

#### 2d — IAM role for GitHub Actions OIDC

The deploy pipeline authenticates to AWS via OIDC — no static credentials.

```bash
# 1. Add GitHub OIDC provider to AWS (one time per account — skip if already done)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

# 2. Create trust policy
cat > /tmp/github-oidc-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:getdzidon/ec2-github-runner:*"
      }
    }
  }]
}
EOF

# 3. Create the role
aws iam create-role \
  --role-name github-actions-ec2-runner-role \
  --assume-role-policy-document file:///tmp/github-oidc-trust.json

# 4. Attach required permissions
cat > /tmp/github-actions-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DescribeInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:PutParameter",
        "ssm:GetParameter"
      ],
      "Resource": "arn:aws:ssm:*:*:parameter/github-runner/*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/github-runner-ec2-role"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name github-actions-ec2-runner-role \
  --policy-name EC2RunnerDeploy \
  --policy-document file:///tmp/github-actions-policy.json
```

Note the role ARN — you need it in Step 5.

---

### Step 3 — Store the GitHub owner in SSM

The EC2 instance reads this on boot to know which GitHub account to register with.

```bash
aws ssm put-parameter \
  --name "/github-runner/owner" \
  --value "getdzidon" \
  --type String \
  --region <YOUR_REGION>
```

> The registration token (`/github-runner/token`) is written automatically by the pipeline on every deploy — you do not create it manually.

---

### Step 4 — Find the Ubuntu AMI ID for your region

Get the latest Ubuntu 22.04 LTS AMI for your region:

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text \
  --region <YOUR_REGION>
```

Note the **AMI ID** — you need it in Step 5.

---

### Step 5 — Set GitHub Actions secrets

Go to **GitHub → your repo → Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Value |
|--------|-------|
| `AWS_IAM_ROLE_ARN` | ARN of the role from Step 2d, e.g. `arn:aws:iam::<ACCOUNT_ID>:role/github-actions-ec2-runner-role` |
| `AWS_REGION` | e.g. `eu-central-1` |
| `GH_PAT` | The Personal Access Token from Step 1 |
| `GITHUB_OWNER` | `getdzidon` |
| `EC2_AMI_ID` | Ubuntu 22.04 AMI ID from Step 4 |
| `EC2_SUBNET_ID` | Subnet ID from Step 2a |
| `EC2_SECURITY_GROUP_ID` | Security Group ID from Step 2b |
| `EC2_INSTANCE_PROFILE` | `github-runner-ec2-profile` (created in Step 2c) |

> Do not add `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` — OIDC is used instead.

---

### Step 6 — Install the Renovate GitHub App (optional but recommended)

Renovate automatically opens PRs when a new GitHub Actions runner version is released.

1. Go to [github.com/apps/renovate](https://github.com/apps/renovate)
2. Click **Install** and grant access to this repository

Dependabot (for GitHub Actions version updates in workflow files) is built into GitHub — no installation needed.

---

## ✅ What happens automatically after you push to main

Once all manual steps above are complete, push to `main`. The `deploy-runner.yaml` pipeline runs and does the following without any further input:

1. Loads the pinned runner version and instance type from `versions.env`
2. Authenticates to AWS via OIDC (using the role from Step 2d)
3. Calls the GitHub API to generate a short-lived runner registration token
4. Stores the token in SSM Parameter Store as a SecureString
5. Terminates any existing runner instance tagged `github-ec2-runner`
6. Launches a new EC2 instance with `bootstrap-runner.sh` as user data
7. On first boot, the instance (`bootstrap-runner.sh`):
   - Installs AWS CLI and runner dependencies
   - Fetches the registration token from SSM
   - Downloads and installs the GitHub Actions runner binary
   - Registers itself with GitHub under the `getdzidon` account
   - Starts the runner as a systemd service

The pipeline re-runs automatically on any future push that changes `scripts/**`, `versions.env`, or the workflow file itself.

**Version updates are also automated:**
- Renovate opens a PR when a new runner version is released → merge the PR → pipeline redeploys with the new version
- Dependabot opens weekly PRs for GitHub Actions version bumps in workflow files

---

## Using the runner in other repositories

Any repository under `getdzidon` can use this runner by matching the labels set in `bootstrap-runner.sh`:

```yaml
jobs:
  build:
    runs-on: [self-hosted, ec2-runner, ubuntu]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on EC2 runner!"
```

The labels `self-hosted`, `ec2-runner`, and `ubuntu` all three must match for GitHub to route the job to this runner.

---

## Runner lifecycle

The runner is configured as `--ephemeral`, meaning:
- It accepts exactly one job then deregisters itself from GitHub
- The EC2 instance is tagged with `instance-initiated-shutdown-behavior: terminate` so it terminates after the job completes
- The next push to `main` (or a `workflow_dispatch`) provisions a fresh instance

This means the runner is **not always-on**. If you need a persistent runner that is always waiting for jobs, remove `--ephemeral` from `bootstrap-runner.sh` and remove the terminate step from the pipeline.

---

## Changing the instance type

Edit `INSTANCE_TYPE` in `versions.env` and push to `main`:

```bash
# versions.env
INSTANCE_TYPE=t3.large   # was t3.medium
```

The pipeline will terminate the old instance and launch a new one with the updated type.

---

## Cost estimate (eu-central-1)

| Instance | On-demand/hr | Spot/hr | On-demand/month (always-on) |
|----------|-------------|---------|----------------------------|
| t3.medium (2 vCPU, 4GB) | ~$0.042 | ~$0.013 | ~$30 |
| t3.large (2 vCPU, 8GB) | ~$0.083 | ~$0.025 | ~$60 |

Since the runner is ephemeral, you only pay while a job is running — actual cost is typically a few cents per day for moderate usage.

To use Spot instances, add `--instance-market-options MarketType=spot` to the `aws ec2 run-instances` command in `deploy-runner.yaml`.

---

## Verify the runner is registered

After the pipeline runs and the instance boots (allow ~2 minutes):

1. Go to **GitHub → Settings → Actions → Runners**
2. You should see a runner named after the EC2 hostname with status **Idle**

Or via AWS CLI:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=github-ec2-runner" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,IP:PublicIpAddress}" \
  --output table
```

---

## Troubleshooting

**Runner not appearing in GitHub after instance launches**

Check the user data log on the instance:

```bash
# Requires a key pair — add --key-name <KEY_NAME> to the run-instances command if needed
ssh ubuntu@<INSTANCE_PUBLIC_IP>
sudo cat /var/log/cloud-init-output.log
```

Most common causes:
- SSM parameter `/github-runner/token` is missing or expired
- The EC2 instance profile does not have SSM read permission
- The security group is blocking outbound HTTPS

**Registration token expired**

Tokens are valid for 1 hour. If the instance takes too long to boot, the token may expire. Re-run the pipeline via `workflow_dispatch` to generate a fresh token and a new instance.

**Runner picks up a job then disappears**

This is expected — the runner is ephemeral. It deregisters after one job. Push to `main` or trigger `workflow_dispatch` to provision a new one.

**Pipeline fails at "Generate GitHub runner registration token"**

Check that `GH_PAT` has `Self-hosted runners: Read & Write` permission on the correct organization.

---

## Uninstall

```bash
# Terminate the EC2 instance
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=github-ec2-runner" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"

# Delete SSM parameters
aws ssm delete-parameter --name "/github-runner/token"
aws ssm delete-parameter --name "/github-runner/owner"

# Delete IAM roles
aws iam remove-role-from-instance-profile \
  --instance-profile-name github-runner-ec2-profile \
  --role-name github-runner-ec2-role
aws iam delete-instance-profile --instance-profile-name github-runner-ec2-profile
aws iam delete-role-policy --role-name github-runner-ec2-role --policy-name SSMReadRunnerParams
aws iam delete-role --role-name github-runner-ec2-role
aws iam delete-role-policy --role-name github-actions-ec2-runner-role --policy-name EC2RunnerDeploy
aws iam delete-role --role-name github-actions-ec2-runner-role

# Delete the security group (after instance is terminated)
aws ec2 delete-security-group --group-id <SG_ID>
```
