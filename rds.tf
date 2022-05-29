resource "random_password" "db_master_pass" {
  length           = 40
  special          = true
  min_special      = 5
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db-pass" {
  name = "db-pass-${random_id.id.hex}"
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

