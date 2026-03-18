#!/usr/bin/env bash
# bootstrap-runner.sh — EC2 user data script
#
# Runs on first boot. Fetches the GitHub registration token from SSM,
# installs the Actions runner binary, and registers it as a systemd service.
#
# SSM parameters (written by deploy-runner.yaml before instance launch):
#   /github-runner/owner   — GitHub username or org
#   /github-runner/token   — Short-lived registration token (SecureString)
#
# Optional environment overrides:
#   RUNNER_NAME    — defaults to EC2 hostname
#   RUNNER_LABELS  — defaults to: self-hosted,ec2-runner,ubuntu
#   RUNNER_VERSION — defaults to value in versions.env at build time

set -euo pipefail

RUNNER_VERSION="${RUNNER_VERSION:-2.317.0}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,ec2-runner,ubuntu}"
RUNNER_DIR="/opt/actions-runner"

# ── System dependencies ───────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl tar jq unzip

# ── Install AWS CLI v2 (needed to read SSM) ───────────────────────────────────
if ! command -v aws &>/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# ── Fetch config from SSM ─────────────────────────────────────────────────────
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

GITHUB_OWNER=$(aws ssm get-parameter \
  --name "/github-runner/owner" \
  --region "$REGION" \
  --query "Parameter.Value" --output text)

RUNNER_TOKEN=$(aws ssm get-parameter \
  --name "/github-runner/token" \
  --region "$REGION" \
  --with-decryption \
  --query "Parameter.Value" --output text)

# ── Download runner binary ────────────────────────────────────────────────────
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

curl -fsSL \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  -o runner.tar.gz
tar -xzf runner.tar.gz
rm runner.tar.gz

./bin/installdependencies.sh

# ── Configure and register the runner ────────────────────────────────────────
sudo -u ubuntu ./config.sh \
  --url "https://github.com/${GITHUB_OWNER}" \
  --token "${RUNNER_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --runnergroup "Default" \
  --work "_work" \
  --unattended \
  --ephemeral

# ── Start as a systemd service ────────────────────────────────────────────────
./svc.sh install ubuntu
./svc.sh start

echo "✅ Runner registered: ${RUNNER_NAME} → github.com/${GITHUB_OWNER}"
