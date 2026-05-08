# Infra

실시간 경매 플랫폼을 AWS 기반으로 배포하기 위한 인프라 코드입니다. Terraform으로 네트워크, EKS, RDS, S3, ECR, WAF, AWS Load Balancer Controller를 구성하고, 애플리케이션 배포는 이후 Kubernetes manifests, GitHub Actions, ArgoCD와 연동하는 구조를 전제로 합니다.

## Architecture

```text
Internet
  |
  | HTTPS / WSS
  v
Route53 + ACM
  |
  v
AWS WAF
  |
  v
ALB (Public Subnet)
  |
  v
EKS Worker Nodes (Private Subnet)
  |
  +-- Backend / Frontend Pods
  +-- AWS Load Balancer Controller
  |
  +-- RDS MySQL (Private Subnet)
  +-- S3 Gateway Endpoint -> S3 Bucket
```

## Infra Scope

현재 Terraform에서 관리하는 주요 리소스는 다음과 같습니다.

- VPC
- Public Subnet 2개
- Private Subnet 2개
- Internet Gateway
- NAT Gateway
- Public / Private Route Table
- EKS Cluster
- EKS Managed Node Group
- ECR Repository
  - backend
  - frontend
- RDS MySQL
- S3 Bucket
- S3 Gateway VPC Endpoint
- AWS Secrets Manager Secret
- External Secrets Operator
  - IAM Role / Policy
  - Helm Release
- AWS Load Balancer Controller
  - IAM Policy
  - IAM Role
  - Kubernetes ServiceAccount
  - Helm Release
- AWS WAFv2 Web ACL
  - Rate Limit
  - AWS Managed Common Rule Set
  - AWS Managed Known Bad Inputs Rule Set
  - AWS Managed SQLi Rule Set

## Directory Structure

```text
infra/
  scripts/
    configure-backend-irsa.ps1
    configure-backend-irsa.sh
  terraform/
    aws-load-balancer-controller.tf
    ecr.tf
    eks.tf
    main.tf
    outputs.tf
    rds.tf
    s3.tf
    variables.tf
    vpc.tf
    waf.tf
    policies/
      aws-load-balancer-controller-iam-policy.json
```

## Terraform Variables

기본 설정은 `terraform/variables.tf`에 정의되어 있습니다.

현재 주요 기본값:

| Variable | Value |
| --- | --- |
| `aws_region` | `ap-northeast-2` |
| `project_name` | `rookies5-macta` |
| `environment` | `dev` |
| `s3_bucket_name` | `rookies5-team4-macta-buckett` |
| `kubernetes_namespace` | `rookies5-macta` |
| `kubernetes_version` | `1.32` |
| `external_secrets_namespace` | `external-secrets` |
| `external_secrets_chart_version` | `0.14.3` |
| `node_instance_type` | `t3.medium` |
| `node_desired_size` | `2` |
| `node_min_size` | `1` |
| `node_max_size` | `4` |
| `waf_rate_limit_per_5_minutes` | `2500` |

DB 설정과 비밀번호는 Git에 올리지 않는 `terraform/terraform.tfvars`에서 관리합니다.

예시:

```hcl
db_instance_class = "db.t3.micro"
db_name           = "mactadb"
db_username       = "admin"
db_password       = "change-me"
```

`terraform.tfvars`는 `.gitignore`에 포함되어 있으므로 Git에 커밋하지 않습니다.

## Usage

Terraform 명령은 `terraform` 디렉터리에서 실행합니다.

```powershell
cd C:\rookies\mini3\infra\terraform

$env:AWS_PROFILE = "team4"

terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

`apply` 실행 시 계획을 확인한 뒤 `yes`를 입력하면 AWS 리소스가 생성됩니다.

## AWS Profile

현재 팀 계정은 `team4` AWS CLI profile 사용을 전제로 합니다.

```powershell
$env:AWS_PROFILE = "team4"
aws sts get-caller-identity
```

## Network Design

네트워크는 외부 접근 영역과 내부 서비스 영역을 분리합니다.

- Public Subnet
  - ALB 배치 대상
  - Internet Gateway 라우팅
- Private Subnet
  - EKS Worker Node 배치 대상
  - RDS 배치 대상
  - NAT Gateway를 통해 외부 패키지 다운로드 가능
- S3 Gateway Endpoint
  - Private Subnet의 EKS Pod가 인터넷 경유 없이 S3에 접근할 수 있도록 구성

## EKS

EKS는 실시간 경매 서비스의 컨테이너 실행 환경입니다.

- Managed Node Group 사용
- 기본 노드 타입: `t3.medium`
- 기본 노드 수: desired 2, min 1, max 4
- Backend Pod가 S3에 접근할 수 있도록 IRSA Role 제공
- AWS Load Balancer Controller를 Helm으로 설치

Apply 후 kubeconfig 설정:

```powershell
aws eks update-kubeconfig --region ap-northeast-2 --name rookies5-macta-eks
```

Terraform output에서도 동일 명령을 확인할 수 있습니다.

```powershell
terraform output kubeconfig_command
```

## AWS Load Balancer Controller

ALB는 Terraform에서 직접 생성하지 않고, Kubernetes Ingress를 통해 AWS Load Balancer Controller가 생성합니다.

Terraform은 다음을 준비합니다.

- Controller IAM Policy
- Controller IAM Role
- Controller ServiceAccount
- Helm Release

배포 확인:

```powershell
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## WAF And Rate Limiting

`terraform/waf.tf`에서 Regional WAF Web ACL을 생성합니다.

적용 규칙:

- IP 기준 5분당 요청 수 제한
- AWS Managed Rules Common Rule Set
- AWS Managed Rules Known Bad Inputs Rule Set
- AWS Managed Rules SQLi Rule Set

WAF는 생성만으로 ALB에 자동 연결되지 않습니다. 이후 Kubernetes Ingress manifest에 Terraform output의 annotation을 추가해야 합니다.

```powershell
terraform output waf_ingress_annotation
```

Ingress 예시:

```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/wafv2-acl-arn: arn:aws:wafv2:ap-northeast-2:...
```

## RDS

RDS MySQL은 Private Subnet에 생성합니다.

- Public access 비활성화
- Private Subnet CIDR에서 MySQL 3306 접근 허용
- DB 접속 정보는 Terraform output으로 확인 가능

```powershell
terraform output rds_endpoint
terraform output rds_db_url
```

운영 접근은 직접 public open 방식이 아니라, 이후 SSM 또는 Bastion Host를 통해 제한적으로 구성하는 것을 권장합니다.

## S3

파일 업로드 저장소로 S3 Bucket을 생성합니다.

- 기본 버킷명: `rookies5-mini3-team4-bucket`
- Public Access Block 활성화
- Backend ServiceAccount에 S3 접근 권한 부여
- Private Subnet에서 S3 Gateway Endpoint를 통해 접근

Backend IRSA 설정 스크립트:

```powershell
..\scripts\configure-backend-irsa.ps1
```

또는 Bash:

```bash
../scripts/configure-backend-irsa.sh
```

## Secrets

Terraform은 애플리케이션 런타임 값을 저장할 AWS Secrets Manager secret을 생성합니다.

현재 secret에 포함되는 값:

- `DB_HOST`
- `DB_NAME`
- `DB_USERNAME`
- `DB_PASSWORD`
- `S3_BUCKET_NAME`

External Secrets Operator는 Terraform에서 Helm chart로 설치합니다.

- Namespace: `external-secrets`
- ServiceAccount: `external-secrets`
- IAM Role: IRSA로 Secrets Manager read 권한 부여
- Chart repository: `https://charts.external-secrets.io`

ESO 설치 확인:

```powershell
terraform output external_secrets_check_command
kubectl get deployment -n external-secrets external-secrets
```

`SecretStore`, `ClusterSecretStore`, `ExternalSecret`은 애플리케이션 배포 manifests 또는 ArgoCD 쪽에서 관리합니다.

예시:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: rookies5-macta
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-2
      auth:
        jwt:
          serviceAccountRef:
            name: backend-sa
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: backend-secret
  namespace: rookies5-macta
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: backend-secret
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: rookies5-macta/dev/app
        property: DB_PASSWORD
```

주의: Terraform으로 `aws_secretsmanager_secret_version`을 만들면 secret 값이 Terraform state에 저장됩니다. 이 레포는 `terraform.tfstate`를 Git에 올리지 않도록 `.gitignore`에 포함하고 있습니다.

## GitOps And CI/CD

목표 배포 흐름:

```text
GitHub Push
  -> GitHub Actions
  -> Docker Build
  -> ECR Push
  -> Kubernetes Manifest Image Tag Update
  -> ArgoCD Sync
  -> EKS Rolling Update
```

Terraform은 클러스터와 배포 기반 인프라를 준비하고, 애플리케이션 배포는 ArgoCD가 Kubernetes manifests를 기준으로 수행합니다.

## Kubernetes Manifests Scope

다음 항목은 Terraform보다 Kubernetes manifests 또는 Helm/Kustomize에서 관리하는 것이 적절합니다.

- Deployment
- Service
- Ingress
- ConfigMap
- SecretStore / ExternalSecret
- HorizontalPodAutoscaler
- ResourceQuota
- LimitRange
- PodDisruptionBudget

## Resource Quota

입찰 서버가 트래픽 폭주 시 클러스터 자원을 독점하지 않도록 Kubernetes `ResourceQuota`와 `LimitRange`를 적용합니다.

권장 방식:

- 입찰 서버와 조회 서버 namespace 분리
- Bid namespace에 CPU/Memory/Pod 수 제한
- 각 Deployment에 `resources.requests`와 `resources.limits` 명시

예시:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: bid-server-quota
  namespace: rookies5-macta
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "10"
```

## HTTPS And WSS

HTTPS/WSS 적용은 다음 리소스를 통해 구성합니다.

- Route53 hosted zone
- ACM certificate
- ALB Ingress annotation
- TLS listener
- WebSocket 지원 backend route

도메인과 인증서가 준비되면 Kubernetes Ingress에 ACM certificate ARN을 annotation으로 추가합니다.

예시:

```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-2:...
    alb.ingress.kubernetes.io/ssl-redirect: "443"
```

## Monitoring

Prometheus와 Grafana는 EKS 내부에 Helm chart로 설치하는 것을 권장합니다.

권장 구성:

- kube-prometheus-stack
- Grafana Dashboard
- Node / Pod CPU, Memory
- ALB request count
- WAF blocked requests
- WebSocket connection metrics
- 경매 마감 직전 입찰 API latency

이 항목은 Terraform 인프라 생성 이후 Helm 또는 ArgoCD Application으로 관리하는 것이 적절합니다.

## Load Test

부하 테스트는 k6, Locust, Artillery 중 하나를 사용합니다.

검증 대상:

- 마감 직전 동시 입찰
- WebSocket 최고가 갱신
- RDS lock 경합
- WAF rate limit 차단
- EKS CPU/Memory 증가
- Rolling Update 중 서비스 가용성

## State And Sensitive Files

다음 파일은 Git에 올리지 않습니다.

- `terraform/.terraform/`
- `terraform/terraform.tfstate`
- `terraform/terraform.tfstate.backup`
- `terraform/*.tfvars`
- Terraform plan output

현재 `.gitignore`에 위 항목이 포함되어 있습니다.

## Apply Checklist

Apply 전 확인 항목:

- AWS profile이 `team4`인지 확인
- `terraform/terraform.tfvars`에 DB 설정값 입력
- 기존 다른 계정의 `terraform.tfstate`가 남아 있지 않은지 확인
- `terraform fmt` 성공
- `terraform validate` 성공
- `terraform plan`에서 의도한 리소스만 생성되는지 확인

명령:

```powershell
cd C:\rookies\mini3\infra\terraform
$env:AWS_PROFILE = "team4"
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```
