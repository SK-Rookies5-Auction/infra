#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-rookies5-macta-eks}"
REGION="${REGION:-ap-northeast-2}"
NAMESPACE="${NAMESPACE:-rookies5-macta}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-backend-sa}"
DEPLOYMENT="${DEPLOYMENT:-backend}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${REPO_ROOT}/terraform}"

ROLE_ARN="$(terraform -chdir="${TERRAFORM_DIR}" output -raw backend_sa_role_arn)"
BUCKET_NAME="$(terraform -chdir="${TERRAFORM_DIR}" output -raw s3_bucket_name)"

echo "Backend IRSA role: ${ROLE_ARN}"
echo "Private S3 bucket: ${BUCKET_NAME}"

aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}" "eks.amazonaws.com/role-arn=${ROLE_ARN}" --overwrite

kubectl rollout restart "deployment/${DEPLOYMENT}" -n "${NAMESPACE}"
kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}"

echo "IRSA environment check:"
kubectl exec "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" -- env | grep -E "AWS_ROLE|AWS_WEB_IDENTITY|AWS_REGION|AWS_DEFAULT_REGION" || true
