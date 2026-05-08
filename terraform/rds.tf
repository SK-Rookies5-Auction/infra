# ────────────────────────────────────────────────────────────────────────────
# 보안 그룹 - EKS 노드에서 RDS 3306 포트 접근 허용
# ────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow MySQL from EKS nodes"
  vpc_id      = aws_vpc.main.id

  # EKS 노드가 배치된 프라이빗 서브넷 CIDR에서 3306 허용
  # (managed node group은 remote_access 미설정 시 SG ID를 노출하지 않음)
  ingress {
    description = "MySQL from private subnets (EKS nodes)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# ────────────────────────────────────────────────────────────────────────────
# DB 서브넷 그룹 - RDS가 배치될 프라이빗 서브넷 지정 (2개 AZ 필수)
# ────────────────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnet-group"
  subnet_ids  = aws_subnet.private[*].id
  description = "Private subnets for RDS"

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# ────────────────────────────────────────────────────────────────────────────
# RDS MySQL 인스턴스
# ────────────────────────────────────────────────────────────────────────────

resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-mysql"

  engine         = "mariadb"
  engine_version = "10.11"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100 # 스토리지 자동 확장 상한

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false # 프라이빗 서브넷, 외부 접근 차단
  skip_final_snapshot = true  # 실습용: 삭제 시 스냅샷 생략

  tags = {
    Name = "${var.project_name}-mysql"
  }
}
