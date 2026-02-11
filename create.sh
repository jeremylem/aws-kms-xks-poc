#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-3"
STACK_NAME="xks-proxy-poc"
DOMAIN_NAME="xks.lemaire.tel"
KEY_NAME="EC2Tutorial2"
SSH_KEY="$HOME/Downloads/EC2Tutorial2.pem"
XKS_SOURCE_DIR="$HOME/Developer/Projects/aws-kms-xks-proxy/xks-axum"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS="-i $SSH_KEY -o ConnectTimeout=5 -o StrictHostKeyChecking=no"

# Print failed CloudFormation events on error
trap 'on_error' ERR
on_error() {
    echo "ERROR: Script failed. Checking CloudFormation events..."
    aws cloudformation describe-stack-events \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
        --output table 2>/dev/null || true
}

# --- Step 1: Prerequisites check ---
echo "==> Checking prerequisites..."
for cmd in aws cargo-zigbuild zig; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is not installed or not in PATH."
        echo "Install with: brew install zig && cargo install cargo-zigbuild"
        exit 1
    fi
done

if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found at $SSH_KEY"
    exit 1
fi

# --- Step 2: Cross-compile for aarch64 ---
echo "==> Cross-compiling xks-proxy for aarch64 (cargo-zigbuild)..."
cd "$XKS_SOURCE_DIR"
# Use rustup's toolchain (not Homebrew's) so we have the linux target sysroot
export RUSTUP_TOOLCHAIN="1.93.0-aarch64-apple-darwin"
export PATH="$HOME/.rustup/toolchains/$RUSTUP_TOOLCHAIN/bin:$PATH"
rustup target add aarch64-unknown-linux-gnu 2>/dev/null || true
cargo zigbuild --release --target aarch64-unknown-linux-gnu
BINARY="$XKS_SOURCE_DIR/target/aarch64-unknown-linux-gnu/release/xks-proxy"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi
cd "$SCRIPT_DIR"

# --- Step 3: Discover default VPC and subnets ---
echo "==> Discovering default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
    echo "ERROR: No default VPC found in $REGION"
    exit 1
fi
echo "    VPC: $VPC_ID"

SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
    --query "Subnets[*].SubnetId" \
    --output text)

# Convert space-separated to comma-separated
SUBNET_IDS_CSV=$(echo "$SUBNET_IDS" | tr '\t' ',')
echo "    Subnets: $SUBNET_IDS_CSV"

# --- Step 4: Get Route53 hosted zone ID ---
echo "==> Looking up Route53 hosted zone for lemaire.tel..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "lemaire.tel" \
    --query "HostedZones[0].Id" \
    --output text | sed 's|/hostedzone/||')

if [ "$HOSTED_ZONE_ID" = "None" ] || [ -z "$HOSTED_ZONE_ID" ]; then
    echo "ERROR: No hosted zone found for lemaire.tel"
    exit 1
fi
echo "    Hosted Zone: $HOSTED_ZONE_ID"

# --- Step 5: Request ACM certificate (if not already exists) ---
echo "==> Checking for existing ACM certificate..."
CERT_ARN=$(aws acm list-certificates \
    --region "$REGION" \
    --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn | [0]" \
    --output text)

if [ "$CERT_ARN" = "None" ] || [ -z "$CERT_ARN" ]; then
    echo "    Requesting new ACM certificate for $DOMAIN_NAME..."
    CERT_ARN=$(aws acm request-certificate \
        --region "$REGION" \
        --domain-name "$DOMAIN_NAME" \
        --validation-method DNS \
        --query "CertificateArn" \
        --output text)
    echo "    Certificate ARN: $CERT_ARN"

    # Wait for DNS validation details to become available
    echo "    Waiting for validation details..."
    for i in $(seq 1 30); do
        VALIDATION_CNAME_NAME=$(aws acm describe-certificate \
            --region "$REGION" \
            --certificate-arn "$CERT_ARN" \
            --query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" \
            --output text 2>/dev/null)
        if [ "$VALIDATION_CNAME_NAME" != "None" ] && [ -n "$VALIDATION_CNAME_NAME" ]; then
            break
        fi
        sleep 2
    done

    VALIDATION_CNAME_VALUE=$(aws acm describe-certificate \
        --region "$REGION" \
        --certificate-arn "$CERT_ARN" \
        --query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" \
        --output text)

    # --- Step 6: Create DNS validation record ---
    echo "    Creating DNS validation record..."
    aws route53 change-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch "{
            \"Changes\": [{
                \"Action\": \"UPSERT\",
                \"ResourceRecordSet\": {
                    \"Name\": \"$VALIDATION_CNAME_NAME\",
                    \"Type\": \"CNAME\",
                    \"TTL\": 300,
                    \"ResourceRecords\": [{\"Value\": \"$VALIDATION_CNAME_VALUE\"}]
                }
            }]
        }"

    # --- Step 7: Wait for certificate validation ---
    echo "    Waiting for certificate validation (this may take a few minutes)..."
    aws acm wait certificate-validated \
        --region "$REGION" \
        --certificate-arn "$CERT_ARN"
    echo "    Certificate validated!"
else
    echo "    Using existing certificate: $CERT_ARN"
fi

# --- Step 8: Handle ROLLBACK_COMPLETE ---
STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "ROLLBACK_COMPLETE" ]; then
    echo "==> Stack in ROLLBACK_COMPLETE state. Deleting before re-creation..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "    Deleted."
fi

# --- Step 9: Deploy CloudFormation stack ---
echo "==> Deploying CloudFormation stack..."
aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --template-file "$SCRIPT_DIR/cloudformation.yaml" \
    --parameter-overrides \
        VpcId="$VPC_ID" \
        SubnetIds="$SUBNET_IDS_CSV" \
        CertificateArn="$CERT_ARN" \
        KeyName="$KEY_NAME" \
        HostedZoneId="$HOSTED_ZONE_ID" \
        DomainName="$DOMAIN_NAME" \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset

echo "    Stack deployed."

# --- Get EC2 public IP ---
EC2_IP=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='EC2PublicIP'].OutputValue | [0]" \
    --output text)

echo "    EC2 Public IP: $EC2_IP"

# --- Step 10: Wait for EC2 to be ready ---
echo "==> Waiting for EC2 SSH to be reachable..."
for i in $(seq 1 60); do
    if ssh $SSH_OPTS "ec2-user@$EC2_IP" "echo ready" &>/dev/null; then
        echo "    EC2 is ready."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "ERROR: Timed out waiting for EC2 SSH"
        exit 1
    fi
    sleep 5
done

# --- Step 11: SCP binary and settings ---
echo "==> Uploading xks-proxy binary and settings.toml..."
scp $SSH_OPTS "$BINARY" "ec2-user@$EC2_IP:/tmp/xks-proxy"
scp $SSH_OPTS "$SCRIPT_DIR/configuration/settings.toml" "ec2-user@$EC2_IP:/tmp/settings.toml"

# --- Step 12: Install and start ---
echo "==> Installing and starting xks-proxy..."
ssh $SSH_OPTS "ec2-user@$EC2_IP" "\
    sudo mv /tmp/xks-proxy /usr/sbin/xks-proxy && \
    sudo chmod +x /usr/sbin/xks-proxy && \
    sudo mv /tmp/settings.toml /var/local/xks-proxy/.secret/settings.toml && \
    sudo systemctl start xks-proxy"

# --- Step 13: Print outputs ---
echo ""
echo "============================================"
echo "  XKS Proxy POC deployed successfully!"
echo "============================================"
echo ""
echo "EC2 Public IP: $EC2_IP"
echo "Endpoint:      https://$DOMAIN_NAME"
echo "CloudWatch:    /xks-proxy/ec2"
echo ""
echo "--- Next steps ---"
echo ""
echo "1. Install p11-kit on your Mac (if not installed):"
echo "   brew install p11-kit"
echo ""
echo "2. Start p11-kit server wrapping SoftHSM:"
echo "   p11-kit server --provider /opt/homebrew/lib/softhsm/libsofthsm2.so \"pkcs11:\""
echo "   (note the P11_KIT_SERVER_ADDRESS from output)"
echo ""
echo "3. Open SSH reverse tunnel (Unix socket):"
echo "   ssh -i $SSH_KEY -R /home/ec2-user/.p11-kit.sock:\\\${P11_KIT_SERVER_ADDRESS#unix:path=} ec2-user@$EC2_IP"
echo ""
echo "4. Test (once tunnel is up and ALB health check passes ~30s):"
echo "   curl https://$DOMAIN_NAME/ping"
echo ""
echo "5. Check logs:"
echo "   aws logs tail /xks-proxy/ec2 --region $REGION --follow"
