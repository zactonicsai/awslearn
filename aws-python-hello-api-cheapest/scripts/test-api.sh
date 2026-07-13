#!/usr/bin/env bash
# Use env so the script finds bash in a portable way.

# Stop the script if a command fails, if a variable is missing, or if a pipeline fails.
set -euo pipefail

# Find the folder where this script lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Move from the scripts folder to the Terraform folder.
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

# Change into the Terraform folder so terraform output can read the state.
cd "${TERRAFORM_DIR}"

# Read the API endpoint output from Terraform without extra quotes.
API_URL="$(terraform output -raw api_endpoint)"

# Print the GET test that is about to run.
echo "Testing GET /hello..."

# Send a GET request to the /hello route.
curl "${API_URL}hello"

# Print a blank line for cleaner terminal output.
echo

# Print the POST test that is about to run.
echo "Testing POST /hello with name=Zach..."

# Send a POST request with a JSON body containing the name argument.
curl -X POST "${API_URL}hello" -H "Content-Type: application/json" -d '{"name":"Zach"}'

# Print a blank line for cleaner terminal output.
echo
