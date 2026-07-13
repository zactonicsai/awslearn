# Configure the AWS provider so Terraform knows which Region to use.
provider "aws" {
  # Use the Region from terraform.tfvars or the default in variables.tf.
  region = var.aws_region

  # Add default tags to every AWS resource that supports provider-level tags.
  default_tags {
    # Define the common tag map applied by the AWS provider.
    tags = {
      # Store the project name on resources for cost tracking and cleanup.
      Project = var.project_name
      # Store the environment name on resources for cost tracking and cleanup.
      Environment = var.environment
      # Mark that Terraform owns these resources.
      ManagedBy = "Terraform"
      # Explain this stack's purpose.
      Purpose = "Cheapest Python hello API example"
    }
  }
}

# Create local helper values so repeated names stay consistent and easy to change.
locals {
  # Build one shared name prefix like hello-python-api-dev.
  name_prefix = "${var.project_name}-${var.environment}"
}

# Ask Terraform's archive provider to zip the Python Lambda file into a deployable package.
data "archive_file" "lambda_zip" {
  # Tell the archive provider to create a ZIP file.
  type = "zip"
  # Point to the single Python file that contains the Lambda handler code.
  source_file = "${path.module}/../lambda/app.py"
  # Put the generated ZIP file in the Terraform folder so source_code_hash can read it.
  output_path = "${path.module}/lambda.zip"
}

# Create a CloudWatch Log Group for the Lambda function before the function runs.
resource "aws_cloudwatch_log_group" "lambda_logs" {
  # Use the exact log group name Lambda expects for this function.
  name = "/aws/lambda/${local.name_prefix}-handler"
  # Keep logs for only a small number of days to reduce long-term log storage cost.
  retention_in_days = var.log_retention_days
}

# Create an IAM role that the Lambda function can assume when it runs.
resource "aws_iam_role" "lambda_execution_role" {
  # Name the role with the same project and environment prefix.
  name = "${local.name_prefix}-lambda-role"

  # Define the trust policy that allows the Lambda service to use this role.
  assume_role_policy = jsonencode({
    # Set the IAM policy language version.
    Version = "2012-10-17"
    # Create a list of policy statements.
    Statement = [
      # Start the one trust statement Lambda needs.
      {
        # Allow the action instead of denying it.
        Effect = "Allow"
        # Identify the AWS service that is allowed to assume this role.
        Principal = {
          # Permit the Lambda service principal.
          Service = "lambda.amazonaws.com"
        }
        # Allow Lambda to assume the role using AWS Security Token Service.
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach the AWS-managed basic Lambda policy so Lambda can write logs to CloudWatch.
resource "aws_iam_role_policy_attachment" "lambda_basic_logging" {
  # Attach the policy to the Lambda execution role created above.
  role = aws_iam_role.lambda_execution_role.name
  # Use the AWS-managed policy that grants basic CloudWatch Logs permissions.
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Create the Python Lambda function that runs the hello API code.
resource "aws_lambda_function" "hello" {
  # Give the Lambda function a predictable name.
  function_name = "${local.name_prefix}-handler"
  # Point Lambda to the ZIP file created by the archive_file data block.
  filename = data.archive_file.lambda_zip.output_path
  # Give Lambda the IAM role ARN that it uses at runtime.
  role = aws_iam_role.lambda_execution_role.arn
  # Tell Lambda which Python function to call inside app.py.
  handler = "app.lambda_handler"
  # Use the Python managed runtime configured in variables.tf or terraform.tfvars.
  runtime = var.lambda_runtime
  # Use ARM64 because it is usually the lower-cost Lambda architecture for simple code.
  architectures = ["arm64"]
  # Use the smallest common memory size for the cheapest hello-world example.
  memory_size = var.lambda_memory_size
  # Stop the function if it runs longer than the configured timeout.
  timeout = var.lambda_timeout_seconds
  # Use the ZIP hash so Terraform updates Lambda when app.py changes.
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # Make sure the log group and IAM policy attachment exist before Lambda starts running.
  depends_on = [
    # Wait for the CloudWatch Log Group so retention is set from the beginning.
    aws_cloudwatch_log_group.lambda_logs,
    # Wait for the logging policy so Lambda can write logs.
    aws_iam_role_policy_attachment.lambda_basic_logging
  ]
}

# Create a Lambda Function URL, which gives the Lambda function a direct HTTPS endpoint.
resource "aws_lambda_function_url" "hello_url" {
  # Attach the Function URL to the Lambda function created above.
  function_name = aws_lambda_function.hello.function_name
  # Use no AWS IAM auth for this small public lab API.
  authorization_type = "NONE"

  # Configure browser CORS rules directly on the Lambda Function URL.
  cors {
    # Allow configured browser origins such as * for a lab.
    allow_origins = var.allowed_cors_origins
    # Allow the methods used by this example API.
    allow_methods = ["GET", "POST"]
    # Allow common headers for JSON API calls.
    allow_headers = ["content-type", "authorization"]
    # Let browsers cache the CORS preflight answer for one hour.
    max_age = 3600
  }
}

# Allow public callers to invoke the Lambda function through the Function URL.
resource "aws_lambda_permission" "allow_public_function_url" {
  # Give this permission statement a unique name.
  statement_id = "AllowPublicFunctionUrlInvoke"
  # Allow invocation through a Lambda Function URL.
  action = "lambda:InvokeFunctionUrl"
  # Apply the permission to the Lambda function name.
  function_name = aws_lambda_function.hello.function_name
  # Use * because this example is a public lab API with authorization_type NONE.
  principal = "*"
  # Limit this permission to Function URL calls that use authorization_type NONE.
  function_url_auth_type = "NONE"
}
