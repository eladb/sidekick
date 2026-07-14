#!/usr/bin/env bash
# EC2, no SSH: cloud-init user-data does all setup (provision.sh +
# configure-and-start.sh straight from the repo, bare-VM/systemd mode, no
# Docker on the box). The tunnel URL is scraped via `aws ec2
# get-console-output`, which is an HTTPS API call, not SSH — but note it is
# NOT real-time (can lag ~a minute and doesn't stream), hence the generous
# timeout below. No SSH key pair is created or needed: the security group
# has no inbound rules at all, since ingress is entirely via the outbound
# Cloudflare tunnel.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${AUTH_TOKEN:?}" "${SERVER_ID:?}"

command -v aws >/dev/null 2>&1 || {
  echo "error: aws CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
}

REGION="${SIDEKICK_EC2_REGION:-us-east-1}"
INSTANCE_TYPE="${SIDEKICK_EC2_INSTANCE_TYPE:-t3.small}"
REPO="${SIDEKICK_REPO:-eladb/sidekick}"
REPO_REF="${SIDEKICK_REPO_REF:-main}"

AMI_ID="${SIDEKICK_EC2_AMI:-}"
if [ -z "$AMI_ID" ]; then
  echo "==> looking up latest Debian 12 AMI in $REGION"
  # 136693071363 is Debian's official AWS account. Override with
  # SIDEKICK_EC2_AMI if this lookup is stale or fails in your region.
  AMI_ID="$(aws ec2 describe-images --region "$REGION" \
    --owners 136693071363 \
    --filters "Name=name,Values=debian-12-amd64-*" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
fi
if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
  echo "error: could not resolve a Debian 12 AMI; set SIDEKICK_EC2_AMI explicitly." >&2
  exit 1
fi

USER_DATA_FILE="$(mktemp)"
trap 'rm -f "$USER_DATA_FILE"' EXIT
cat > "$USER_DATA_FILE" <<EOF
#!/bin/bash
set -x
export AUTH_TOKEN='${AUTH_TOKEN}'
export SERVER_ID='${SERVER_ID}'
mkdir -p /opt/sidekick-src
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${REPO_REF}.tar.gz" \\
  | tar xz -C /opt/sidekick-src --strip-components=1
chmod +x /opt/sidekick-src/provision.sh /opt/sidekick-src/configure-and-start.sh
/opt/sidekick-src/provision.sh
/opt/sidekick-src/configure-and-start.sh
EOF

echo "==> creating security group with no inbound rules (outbound-only box)"
# A freshly created security group already has zero inbound rules and a
# default allow-all outbound rule, which is exactly what we want: nothing
# reaches this box except via the outbound Cloudflare tunnel.
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws ec2 create-security-group --region "$REGION" \
  --group-name "sidekick-${SERVER_ID}" --description "sidekick (no inbound; egress only)" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)"

echo "==> launching instance ($INSTANCE_TYPE, $AMI_ID)"
INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --security-group-ids "$SG_ID" \
  --user-data "file://${USER_DATA_FILE}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=sidekick-${SERVER_ID}}]" \
  --query 'Instances[0].InstanceId' --output text)"
echo "==> instance: $INSTANCE_ID"

echo "==> waiting for tunnel URL (EC2 console output lags real time; this can take a few minutes)"
BASE_URL="$(sidekick_wait_for_tunnel_url "aws ec2 get-console-output --region $REGION --instance-id $INSTANCE_ID --output text" 480)" || {
  echo "error: timed out waiting for the tunnel URL." >&2
  echo "Check manually: aws ec2 get-console-output --region $REGION --instance-id $INSTANCE_ID --output text" >&2
  exit 1
}

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TOKEN="$(sidekick_build_token "$SERVER_ID" "$BASE_URL" "$AUTH_TOKEN" "ec2" "$CREATED_AT")"
sidekick_print_summary "$TOKEN" "$BASE_URL" "${SIDEKICK_TOKEN_FILE:-./sidekick-token.txt}"
