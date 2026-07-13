# Create a variable for the AWS Region where the API and Lambda will be created.
variable "aws_region" {
  # Describe the variable so future readers understand what it controls.
  description = "AWS Region where Terraform will create the API and Lambda resources."
  # Set the value type to string because a Region is text like us-east-1.
  type = string
  # Use us-east-1 by default because it is common and usually low-cost.
  default = "us-east-1"
}

# Create a variable for the project name used in resource names and tags.
variable "project_name" {
  # Describe the project name variable in plain language.
  description = "Short project name used for AWS names and tags."
  # Set the value type to string because the project name is text.
  type = string
  # Use a clear default project name.
  default = "hello-python-api"
}

# Create a variable for the environment name, such as dev, test, or prod.
variable "environment" {
  # Describe the environment variable in plain language.
  description = "Environment name, such as dev, test, or prod."
  # Set the value type to string because the environment name is text.
  type = string
  # Use dev by default because this is a small learning example.
  default = "dev"
}

# Create a variable for the Lambda Python runtime version.
variable "lambda_runtime" {
  # Explain that this controls the Python version Lambda will run.
  description = "AWS Lambda Python runtime version, such as python3.14 or python3.13."
  # Set the value type to string because the runtime name is text.
  type = string
  # Use Python 3.14 for the current example. Change to python3.13 if your Region/account does not support 3.14 yet.
  default = "python3.14"
}

# Create a variable for how much memory the Lambda function receives.
variable "lambda_memory_size" {
  # Explain that memory also affects CPU power and cost.
  description = "Lambda memory size in MB; 128 is the smallest and cheapest common setting."
  # Set the value type to number because memory is a number.
  type = number
  # Use 128 MB for the lowest-cost simple hello API.
  default = 128
}

# Create a variable for the Lambda timeout.
variable "lambda_timeout_seconds" {
  # Explain how long Lambda may run before AWS stops it.
  description = "Maximum number of seconds the Lambda function can run."
  # Set the value type to number because timeout is a number.
  type = number
  # Use 10 seconds, which is plenty for a hello API.
  default = 10
}

# Create a variable for CloudWatch Logs retention.
variable "log_retention_days" {
  # Explain that shorter retention helps avoid keeping logs forever.
  description = "Number of days to keep Lambda logs in CloudWatch."
  # Set the value type to number because days are a number.
  type = number
  # Use 7 days so logs are useful but not kept forever.
  default = 7
}

# Create a variable for allowed browser origins in CORS.
variable "allowed_cors_origins" {
  # Explain that CORS controls which browser websites can call this API from JavaScript.
  description = "Browser origins allowed by CORS. Use [\"*\"] for a simple lab, or full origins like [\"http://localhost:3000\", \"https://www.example.com\"]. Do not put bare IP addresses here."
  # Set the value type to list of strings because there can be many origins.
  type = list(string)
  # Allow all browser origins for a simple test API.
  default = ["*"]

  # Validate the CORS origin values before Terraform sends them to AWS.
  validation {
    # Each origin must be either the wildcard * or a full URL that starts with http:// or https://.
    condition = alltrue([
      # Loop through every value in allowed_cors_origins.
      for origin in var.allowed_cors_origins :
      # Accept the wildcard character used for simple labs.
      origin == "*" ||
      # Accept normal HTTP origins such as http://localhost:3000.
      startswith(origin, "http://") ||
      # Accept normal HTTPS origins such as https://www.example.com.
      startswith(origin, "https://")
    ])
    # Show a plain-language error if someone enters a bare IP or invalid origin.
    error_message = "allowed_cors_origins must contain only '*' or full origins such as 'http://localhost:3000' or 'https://www.example.com'. Do not use a bare IP like 68.32.112.68."
  }
}
