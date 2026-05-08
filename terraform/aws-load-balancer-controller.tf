# ────────────────────────────────────────────────────────────────────────────
# AWS Load Balancer Controller
# Kubernetes Ingress/Service 리소스를 보고 ALB/NLB를 생성하는 컨트롤러
# HTTPS Ingress 구성을 위해 필요
# ────────────────────────────────────────────────────────────────────────────

locals {
  aws_load_balancer_controller_service_account = "aws-load-balancer-controller"
  aws_load_balancer_controller_namespace       = "kube-system"
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${var.project_name}-aws-load-balancer-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "${var.project_name}-aws-load-balancer-controller-role"

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
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${local.aws_load_balancer_controller_namespace}:${local.aws_load_balancer_controller_service_account}"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = local.aws_load_balancer_controller_service_account
    namespace = local.aws_load_balancer_controller_namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_load_balancer_controller.arn
    }

    labels = {
      "app.kubernetes.io/name"      = local.aws_load_balancer_controller_service_account
      "app.kubernetes.io/component" = "controller"
    }
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.aws_load_balancer_controller,
  ]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = local.aws_load_balancer_controller_service_account
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = local.aws_load_balancer_controller_namespace
  version    = var.aws_load_balancer_controller_chart_version

  set {
    name  = "clusterName"
    value = aws_eks_cluster.main.name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = aws_vpc.main.id
  }

  depends_on = [
    kubernetes_service_account.aws_load_balancer_controller,
  ]
}
