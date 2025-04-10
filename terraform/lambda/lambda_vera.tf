###
# General data sources
###

# Current AWS account id
data "aws_caller_identity" "current" {}

# Region
data "aws_region" "current" {}


###
# Fetch secret ARNs from Secrets Manager
# We don't want to store sensitive information in our codebase (or in terraform's state file),
# so we fetch it from Secrets Manager
###

data "aws_secretsmanager_secret" "devopsbot_secrets_json" {
  name = "DEVOPSBOT_SECRETS_JSON"
}

/*
This secret should be formatted like this:
{"SLACK_BOT_TOKEN":"xoxb-xxxxxx-arOa","SLACK_SIGNING_SECRET":"2cxxxxxxxxxxxxda"}
*/


###
# IAM Role and policies for GitHubCop Trigger Lambda
###

data "aws_iam_policy_document" "DevOpsBotIamRole_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "DevOpsBotIamRole" {
  name               = "DevOpsBotIamRole"
  assume_role_policy = data.aws_iam_policy_document.DevOpsBotIamRole_assume_role.json
}

resource "aws_iam_role_policy" "DevOpsBotSlack_ReadSecret" {
  name = "ReadSecret"
  role = aws_iam_role.DevOpsBotRole.id

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "secretsmanager:GetResourcePolicy",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecretVersionIds"
          ],
          "Resource" : [
            data.aws_secretsmanager_secret.devopsbot_secrets_json.arn,
          ]
        },
        {
          "Effect" : "Allow",
          "Action" : "secretsmanager:ListSecrets",
          "Resource" : "*"
        }
      ]
    }
  )
}

resource "aws_iam_role_policy" "DevOpsBotSlack_Bedrock" {
  name = "Bedrock"
  role = aws_iam_role.DevOpsBotRole.id

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        # Grant permission to invoke bedrock models of any type in US regions
        {
          "Effect" : "Allow",
          "Action" : [
            "bedrock:InvokeModel",
            "bedrock:InvokeModelStream",
            "bedrock:InvokeModelWithResponseStream",
          ],
          # Both no longer specify region, since Bedrock wants cross-region access
          "Resource" : [
            "arn:aws:bedrock:us-east-1::foundation-model/*",
            "arn:aws:bedrock:us-east-2::foundation-model/*",
            "arn:aws:bedrock:us-west-1::foundation-model/*",
            "arn:aws:bedrock:us-west-2::foundation-model/*",
            "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/*",
            "arn:aws:bedrock:us-east-2:${data.aws_caller_identity.current.account_id}:inference-profile/*",
            "arn:aws:bedrock:us-west-1:${data.aws_caller_identity.current.account_id}:inference-profile/*",
            "arn:aws:bedrock:us-west-2:${data.aws_caller_identity.current.account_id}:inference-profile/*",
          ]
        },
        # Grant permission to invoke bedrock guardrails of any type in us-west-2 region
        {
          "Effect" : "Allow",
          "Action" : "bedrock:ApplyGuardrail",
          "Resource" : "arn:aws:bedrock:us-west-2:${data.aws_caller_identity.current.account_id}:guardrail/*"
        },
        # Grant permissions to use knowledge bases in us-west-2 region
        {
          "Effect" : "Allow",
          "Action" : [
            "bedrock:Retrieve",
            "bedrock:RetrieveAndGenerate",
          ],
          "Resource" : "arn:aws:bedrock:us-west-2:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
        },
      ]
    }
  )
}

resource "aws_iam_role_policy" "DevOpsBotSlackTrigger_Cloudwatch" {
  name = "Cloudwatch"
  role = aws_iam_role.DevOpsBotIamRole.id

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : "logs:CreateLogGroup",
          "Resource" : "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.id}:*"
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ],
          "Resource" : [
            "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.id}:log-group:/aws/lambda/DevOpsBot:*"
          ]
        }
      ]
    }
  )
}


###
# Create lambda layers
###

# Source files created by the following commands:

# Source files created by the following commands:
/*
# Create new python 3.12 venv
mkdir venv_old
mv pyvenv.cfg venv_old
mv bin venv_old
mv include venv_old
mv lib venv_old
# Deactivate old venv
deactivate
# Create new python 3.12 venv
python3.12 -m venv .
# Activate new env
source ./bin/activate
# Remove old files and create new ones
rm -rf lambda/slack_bolt
mkdir -p lambda/slack_bolt/python/lib/python3.12/site-packages/
pip3 install slack_bolt -t lambda/slack_bolt/python/lib/python3.12/site-packages/. --no-cache-dir 
*/

# Committing the zip file directly, rather than creating it, so don't have to commit huge number of files
# data "archive_file" "slack_bolt" {
#   type        = "zip"
#   source_dir  = "${path.module}/slack_bolt"
#   output_path = "${path.module}/slack_bolt_layer.zip"
# }
resource "aws_lambda_layer_version" "slack_bolt" {
  layer_name       = "SlackBolt"
  filename         = "${path.module}/slack_bolt_layer.zip"
  source_code_hash = filesha256("${path.module}/slack_bolt_layer.zip")

  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["arm64"]
}


###
# Build lambda
###

# Zip up python lambda code
data "archive_file" "devopsbot_slack_trigger_lambda" {
  type        = "zip"
  source_file = "python/devopsbot.py"
  output_path = "${path.module}/devopsbot.zip"
}

# Build lambda function
resource "aws_lambda_function" "devopsbot_slack" {
  filename      = "${path.module}/devopsbot.zip"
  function_name = "DevOpsBot"
  role          = aws_iam_role.DevOpsBotIamRole.arn
  handler       = "devopsbot.lambda_handler"
  timeout       = 30
  memory_size   = 512
  runtime       = "python3.12"
  architectures = ["arm64"]
  publish       = true

  # Layers are packaged code for lambda
  layers = [
    # This layer permits us to ingest secrets from Secrets Manager
    "arn:aws:lambda:us-east-1:${data.aws_caller_identity.current.id}:layer:AWS-Parameters-and-Secrets-Lambda-Extension-Arm64:12",

    # Slack bolt layer to support slack app
    aws_lambda_layer_version.slack_bolt.arn,
  ]

  source_code_hash = data.archive_file.devopsbot_slack_trigger_lambda.output_base64sha256

  environment {
    variables = {
      VERA_DEBUG = "True"
    }
  }
}
