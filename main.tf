provider "aws" {
}

resource "random_password" "db_master_pass" {
  length           = 40
  special          = true
  min_special      = 5
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "random_id" "id" {
  byte_length = 8
}

resource "aws_secretsmanager_secret" "db-pass" {
  name = "db-pass-${random_id.id.hex}"
}

resource "aws_secretsmanager_secret_rotation" "rotation" {
  secret_id           = aws_secretsmanager_secret.db-pass.id
  rotation_lambda_arn = aws_serverlessapplicationrepository_cloudformation_stack.rotate-stack.outputs.RotationLambdaARN

  rotation_rules {
    automatically_after_days = 30
  }
}

resource "aws_secretsmanager_secret_version" "db-pass-val" {
  secret_id = aws_secretsmanager_secret.db-pass.id
  secret_string = jsonencode(
    {
      username = aws_rds_cluster.cluster.master_username
      password = aws_rds_cluster.cluster.master_password
      engine   = "mysql"
      host     = aws_rds_cluster.cluster.endpoint
    }
  )
}

resource "aws_vpc" "db" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.db.id
  cidr_block        = cidrsubnet(aws_vpc.db.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_security_group" "db" {
  vpc_id = aws_vpc.db.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.db.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.db.cidr_block]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.db.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.db[0].id]
  security_group_ids  = [aws_security_group.db.id]
}


resource "aws_db_subnet_group" "db" {
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_rds_cluster" "cluster" {
  engine                 = "aurora-mysql"
  engine_version         = "5.7.mysql_aurora.2.07.1"
  engine_mode            = "serverless"
  database_name          = "mydb"
  master_username        = "admin"
  master_password        = random_password.db_master_pass.result
  enable_http_endpoint   = true
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.db.id]
  db_subnet_group_name   = aws_db_subnet_group.db.name
}

data "aws_serverlessapplicationrepository_application" "rotator" {
  application_id = "arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSMySQLRotationSingleUser"
}

data "aws_partition" "current" {}
data "aws_region" "current" {}

resource "aws_serverlessapplicationrepository_cloudformation_stack" "rotate-stack" {
  name             = "Rotate-${random_id.id.hex}"
  application_id   = data.aws_serverlessapplicationrepository_application.rotator.application_id
  semantic_version = data.aws_serverlessapplicationrepository_application.rotator.semantic_version
  capabilities     = data.aws_serverlessapplicationrepository_application.rotator.required_capabilities

  parameters = {
    endpoint            = "https://secretsmanager.${data.aws_region.current.name}.${data.aws_partition.current.dns_suffix}"
    functionName        = "rotator-${random_id.id.hex}"
    vpcSubnetIds        = aws_subnet.db[0].id
    vpcSecurityGroupIds = aws_security_group.db.id
  }
}

resource "null_resource" "db_setup2" {
  provisioner "local-exec" {
    command = <<EOF
aws rds-data execute-statement --resource-arn "$DB_ARN" --database "$DB_NAME" --secret-arn "$SECRET_ARN" --sql "CREATE TABLE IF NOT EXISTS TEST (
id INT NOT NULL AUTO_INCREMENT,PRIMARY KEY(id)
)"
EOF
    environment = {
      DB_ARN     = aws_rds_cluster.cluster.arn
      DB_NAME    = aws_rds_cluster.cluster.database_name
      SECRET_ARN = aws_secretsmanager_secret.db-pass.arn
    }
  }
}
