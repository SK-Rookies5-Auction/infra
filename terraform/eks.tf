# ────────────────────────────────────────────────────────────────────────────
# EKS 클러스터 IAM 역할
# AmazonEKSClusterPolicy: EKS 컨트롤 플레인이 EC2·ELB 등 AWS 리소스를 관리하기 위해 필요
# ────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role-rookies-mj"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ────────────────────────────────────────────────────────────────────────────
# EKS 클러스터
# ────────────────────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-eks"
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true # VPC 내부에서 API 서버 접근 허용
    endpoint_public_access  = true # kubectl 로컬 사용을 위해 퍼블릭도 허용
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ────────────────────────────────────────────────────────────────────────────
# OIDC Provider (IRSA - IAM Roles for Service Accounts 사용에 필요)
# Pod가 IAM 역할을 직접 assume할 수 있게 해주는 인증 브릿지
# ────────────────────────────────────────────────────────────────────────────

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# ────────────────────────────────────────────────────────────────────────────
# 백엔드 서비스 어카운트용 IAM 역할 (IRSA)
# 백엔드 Pod가 S3에 직접 접근하기 위해 사용
# ────────────────────────────────────────────────────────────────────────────

locals {
  oidc_issuer = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

resource "aws_iam_role" "backend_sa" {
  name = "${var.project_name}-backend-sa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${var.kubernetes_namespace}:${var.backend_service_account_name}"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "backend_s3" {
  name = "${var.project_name}-backend-s3-policy"
  role = aws_iam_role.backend_sa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BucketRead"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads"
        ]
        Resource = aws_s3_bucket.app.arn
      },
      {
        Sid    = "ObjectReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.app.arn}/*"
      }
    ]
  })
}

# ────────────────────────────────────────────────────────────────────────────
# 노드 그룹 IAM 역할
# AmazonEKSWorkerNodePolicy : 노드가 클러스터에 등록되고 통신하기 위해 필요
# AmazonEC2ContainerRegistryReadOnly : ECR에서 이미지를 pull하기 위해 필요
# AmazonEKS_CNI_Policy : VPC CNI 플러그인이 Pod IP를 할당하기 위해 필요
# ────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "eks_node" {
  name = "${var.project_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_read_only" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ────────────────────────────────────────────────────────────────────────────
# EKS 관리형 노드 그룹
# 프라이빗 서브넷에 워커 노드 배치 (보안상 권장)
# ────────────────────────────────────────────────────────────────────────────

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-node-group"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id # 노드는 프라이빗 서브넷에 배치

  instance_types = [var.node_instance_type]
  ami_type       = "AL2_x86_64"
  version        = var.kubernetes_version

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1 # 롤링 업데이트 시 동시에 교체할 최대 노드 수
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only,
    aws_iam_role_policy_attachment.eks_cni_policy,
  ]
}
