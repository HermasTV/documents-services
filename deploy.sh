#!/bin/bash

echo "🚀 Deploying PDF Converter to AWS Lambda..."

# Find AWS CLI path
AWS_CMD=""
if command -v aws &> /dev/null; then
    AWS_CMD="aws"
elif [ -f "/usr/local/bin/aws" ]; then
    AWS_CMD="/usr/local/bin/aws"
    echo "🔧 Using AWS CLI at /usr/local/bin/aws"
else
    echo "❌ AWS CLI not found. Please install it first."
    exit 1
fi

# Find SAM CLI path
SAM_CMD="/usr/local/bin/aws sam"
# if command -v /usr/local/bin/aws sam &> /dev/null; then
#     SAM_CMD="sam"
# elif [ -f "/usr/local/bin/aws sam" ]; then
#     SAM_CMD="/usr/local/bin/aws sam"
#     echo "🔧 Using SAM CLI at /usr/local/bin/aws/ sam"
# else
#     echo "❌ AWS SAM CLI not found. Please install it first."
#     exit 1
# fi

# Check AWS credentials
echo "🔍 Checking AWS credentials..."
if ! $AWS_CMD sts get-caller-identity &> /dev/null; then
    echo "❌ AWS credentials not configured. Please run '$AWS_CMD configure' first."
    exit 1
fi

echo "✅ AWS credentials configured"

# Build the application
echo "🔨 Building SAM application..."
$SAM_CMD build

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

# Deploy the application
echo "🚀 Deploying to AWS..."
$SAM_CMD deploy --guided --stack-name hermasai-pdf-converter

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Deployment successful!"
    echo "📋 Getting API Gateway URL..."
    API_URL=$($AWS_CMD cloudformation describe-stacks --stack-name hermasai-pdf-converter --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayUrl`].OutputValue' --output text)
    echo ""
    echo "🌐 Your API is available at: $API_URL"
    echo ""
    echo "📝 Update your Next.js environment variables:"
    echo "NEXT_PUBLIC_PDF_CONVERTER_API_URL=$API_URL"
    echo ""
else
    echo "❌ Deployment failed!"
    exit 1
fi