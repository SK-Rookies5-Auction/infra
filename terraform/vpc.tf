# ────────────────────────────────────────────────────────────────────────────
# VPC
# ────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS 노드가 DNS로 서로를 찾기 위해 필요

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ────────────────────────────────────────────────────────────────────────────
# 퍼블릭 서브넷 (인터넷 게이트웨이 → 외부 접근 가능, ALB 배치)
# EKS 태그: kubernetes.io/role/elb = "1" → AWS Load Balancer Controller가
#           퍼블릭 서브넷에 인터넷 facing ALB를 자동 생성할 때 사용
# ────────────────────────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = true # 퍼블릭 서브넷 인스턴스에 공인 IP 자동 할당

  tags = {
    Name                                            = "${var.project_name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
    "kubernetes.io/role/elb"                        = "1"
  }
}

# ────────────────────────────────────────────────────────────────────────────
# 프라이빗 서브넷 (NAT 게이트웨이 경유, EKS 워커 노드 배치)
# EKS 태그: kubernetes.io/role/internal-elb = "1" → 내부 ALB용
# ────────────────────────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                            = "${var.project_name}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
    "kubernetes.io/role/internal-elb"               = "1"
  }
}

# ────────────────────────────────────────────────────────────────────────────
# 인터넷 게이트웨이 (퍼블릭 서브넷 → 인터넷)
# ────────────────────────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ────────────────────────────────────────────────────────────────────────────
# NAT 게이트웨이 (프라이빗 서브넷 → 인터넷 아웃바운드)
# 비용 절감을 위해 단일 NAT 사용 (prod 환경은 AZ별로 1개씩 권장)
# ────────────────────────────────────────────────────────────────────────────

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # 첫 번째 퍼블릭 서브넷에 배치

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-nat"
  }
}

# ────────────────────────────────────────────────────────────────────────────
# 라우팅 테이블
# ────────────────────────────────────────────────────────────────────────────

# 퍼블릭: 0.0.0.0/0 → IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 프라이빗: 0.0.0.0/0 → NAT GW
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
