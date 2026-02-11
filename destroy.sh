#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-3"
STACK_NAME="xks-proxy-poc"
DOMAIN_NAME="xks.lemaire.tel"

# --- Step 1: Delete CloudFormation stack ---
echo "==> Deleting CloudFormation stack '$STACK_NAME'..."
STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
    echo "    Stack does not exist, skipping."
else
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    echo "    Waiting for stack deletion..."
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "    Stack deleted."
fi

# --- Step 2: Delete ACM certificate ---
echo "==> Deleting ACM certificate for $DOMAIN_NAME..."
CERT_ARN=$(aws acm list-certificates \
    --region "$REGION" \
    --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn | [0]" \
    --output text)

if [ "$CERT_ARN" = "None" ] || [ -z "$CERT_ARN" ]; then
    echo "    No certificate found, skipping."
else
    aws acm delete-certificate --region "$REGION" --certificate-arn "$CERT_ARN"
    echo "    Certificate deleted: $CERT_ARN"
fi

echo ""
echo "==> Teardown complete."
