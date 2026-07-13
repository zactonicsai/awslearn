# Import Python's built-in JSON library so we can read and write JSON data.
import json

# Import Python's built-in base64 library so we can handle encoded Lambda Function URL HTTP bodies if needed.
import base64

# Define a small helper function that builds the HTTP response sent back to the Lambda Function URL caller.
def build_response(status_code, payload):
    # Return the exact dictionary shape that Lambda Function URL expects from the Lambda handler.
    return {
        # Tell Lambda what HTTP status code to send to the caller.
        "statusCode": status_code,
        # Tell the browser or curl that the response body is JSON.
        "headers": {"Content-Type": "application/json"},
        # Convert the Python dictionary payload into a JSON string.
        "body": json.dumps(payload),
    }

# Define a helper function that safely reads the body from the Lambda Function URL event.
def read_json_body(event):
    # Get the raw body string from the Function URL event, or use an empty string if no body was sent.
    raw_body = event.get("body") or ""

    # Check whether Lambda sent the body as base64 text instead of plain text.
    if event.get("isBase64Encoded"):
        # Decode the base64 body into regular UTF-8 text.
        raw_body = base64.b64decode(raw_body).decode("utf-8")

    # If the caller did not send a body, return an empty dictionary.
    if not raw_body:
        # Return empty JSON-like data so later code can use .get() safely.
        return {}

    # Try to parse the raw text as JSON.
    try:
        # Convert the JSON string, like {"name":"Zach"}, into a Python dictionary.
        return json.loads(raw_body)
    # If the body is not valid JSON, handle the error without crashing the Lambda function.
    except json.JSONDecodeError:
        # Return a special error marker so the main handler can send a clean 400 response.
        return {"_error": "Request body must be valid JSON."}

# Define the Lambda entry point that AWS calls for every API request.
def lambda_handler(event, context):
    # Get the HTTP method, such as GET or POST, from the HTTP API version 2 event shape.
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")

    # Get query string values, such as ?name=Zach, or use an empty dictionary if none were sent.
    query = event.get("queryStringParameters") or {}

    # If this is a GET request, return a simple hello message.
    if method == "GET":
        # Build and return a successful JSON response for GET /hello.
        return build_response(200, {"message": "Hello from Python Lambda!", "method": "GET"})

    # If this is a POST request, read the JSON body and look for a name value.
    if method == "POST":
        # Parse the request body as JSON.
        body = read_json_body(event)

        # If the body parser found bad JSON, return a helpful 400 Bad Request response.
        if body.get("_error"):
            # Tell the caller exactly what was wrong with the request body.
            return build_response(400, {"error": body["_error"]})

        # Read the name from JSON first, then from the query string, then use World as a default.
        name = body.get("name") or query.get("name") or "World"

        # Convert the name to text and remove extra spaces from the beginning and end.
        name = str(name).strip()

        # If the caller sent an empty name like "", use World instead.
        if not name:
            # Use a friendly default name.
            name = "World"

        # Build and return a successful JSON response for POST /hello.
        return build_response(200, {"message": f"Hello, {name}!", "method": "POST"})

    # If the caller uses any method besides GET or POST, return 405 Method Not Allowed.
    return build_response(405, {"error": "Only GET and POST are supported."})
