output "aws_region" {
  description = "AWS 리전"
  value       = var.aws_region
}

output "vpc_id" {
  description = "생성된 VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록"
  value       = aws_subnet.private[*].id
}

output "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS API 서버 엔드포인트"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_version" {
  description = "EKS 쿠버네티스 버전"
  value       = aws_eks_cluster.main.version
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC 프로바이더 ARN (IRSA 설정 시 사용)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "backend_sa_role_arn" {
  description = "백엔드 서비스 어카운트 IAM 역할 ARN"
  value       = aws_iam_role.backend_sa.arn
}

output "backend_service_account_name" {
  description = "Backend Kubernetes ServiceAccount name"
  value       = var.backend_service_account_name
}

output "kubernetes_namespace" {
  description = "Application Kubernetes namespace"
  value       = var.kubernetes_namespace
}

output "backend_irsa_annotation_command" {
  description = "PowerShell command to annotate the backend ServiceAccount with the IRSA role"
  value       = "kubectl annotate serviceaccount ${var.backend_service_account_name} -n ${var.kubernetes_namespace} eks.amazonaws.com/role-arn=${aws_iam_role.backend_sa.arn} --overwrite"
}
output "ecr_backend_repository_url" {
  description = "백엔드 ECR 리포지토리 URL"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_repository_url" {
  description = "프론트엔드 ECR 리포지토리 URL"
  value       = aws_ecr_repository.frontend.repository_url
}

output "kubeconfig_command" {
  description = "kubeconfig 업데이트 명령어 (terraform apply 후 실행)"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "rds_endpoint" {
  description = "RDS 엔드포인트 (DB_URL 구성에 사용)"
  value       = aws_db_instance.main.address
}

output "rds_db_url" {
  description = "Spring Boot DB_URL 환경변수 값"
  value       = "jdbc:mysql://${aws_db_instance.main.address}:3306/${var.db_name}?serverTimezone=Asia/Seoul&characterEncoding=UTF-8"
}

output "s3_bucket_name" {
  description = "S3 버킷 이름 (S3_BUCKET_NAME 환경변수 값)"
  value       = aws_s3_bucket.app.bucket
}

output "s3_vpc_endpoint_id" {
  description = "S3 Gateway VPC endpoint ID for private subnet access"
  value       = aws_vpc_endpoint.s3.id
}

output "aws_load_balancer_controller_role_arn" {
  description = "AWS Load Balancer Controller ServiceAccount IAM role ARN"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "aws_load_balancer_controller_check_command" {
  description = "Command to verify AWS Load Balancer Controller deployment"
  value       = "kubectl get deployment -n kube-system aws-load-balancer-controller"
}

output "waf_web_acl_arn" {
  description = "AWS WAFv2 Web ACL ARN for ALB Ingress annotation"
  value       = aws_wafv2_web_acl.app.arn
}

output "waf_ingress_annotation" {
  description = "Annotation to attach this WAF Web ACL to an AWS Load Balancer Controller ALB Ingress"
  value       = "alb.ingress.kubernetes.io/wafv2-acl-arn: ${aws_wafv2_web_acl.app.arn}"
}

output "waf_log_group_name" {
  description = "CloudWatch Logs log group name for AWS WAF full request logs"
  value       = aws_cloudwatch_log_group.waf.name
}

output "app_secret_arn" {
  description = "AWS Secrets Manager secret ARN for application runtime secrets"
  value       = aws_secretsmanager_secret.app.arn
}

output "external_secrets_role_arn" {
  description = "External Secrets Operator ServiceAccount IAM role ARN"
  value       = aws_iam_role.external_secrets.arn
}

output "external_secrets_check_command" {
  description = "Command to verify External Secrets Operator deployment"
  value       = "kubectl get deployment -n ${var.external_secrets_namespace} external-secrets"
}
