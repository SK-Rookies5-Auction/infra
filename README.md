# MACTA Infrastructure

SK쉴더스 루키즈 개발 5기 미니프로젝트3 실시간 경매 사이트 **MACTA** 서비스를 AWS 기반으로 배포하기 위한 인프라 레포입니다. Terraform으로 AWS 리소스를 구성하고, Kubernetes manifest와 Argo CD를 통해 EKS 위에 프론트엔드/백엔드 애플리케이션을 배포하는 구조입니다.

현재 구조의 핵심은 다음과 같습니다.

- Terraform: VPC, EKS, RDS, S3, ECR, WAF, IRSA, Helm 기반 컨트롤러 설치
- EKS: 프론트엔드, 백엔드, Ingress, External Secrets 리소스 실행
- SSM Parameter Store: DB, S3, IAM Role ARN, WAF ARN, ACM ARN 등 환경별 값을 저장
- External Secrets Operator: SSM 값을 Kubernetes Secret으로 동기화
- AWS Load Balancer Controller: Kubernetes Ingress를 보고 ALB 생성
- Route53 + ACM: `macta.store` 도메인과 HTTPS 인증서 연결
- 통신 구조: 정적 파일은 프론트 Nginx가 서빙하고, 동적 API 호출은 ALB가 `/api/v1` 경로로 백엔드 서비스에 직접 전달

&nbsp;
## 전체 구조
<img width="2115" height="1671" alt="image" src="https://github.com/user-attachments/assets/f1146f1e-fc5a-476d-9ff8-39c1532fc645" />


```mermaid
flowchart TB
  user[User Browser]
  r53[Route53<br/>macta.store A Alias]
  acm[ACM Certificate<br/>macta.store]
  waf[AWS WAFv2<br/>Regional Web ACL]
  alb[Public ALB<br/>AWS Load Balancer Controller]
  internet[Internet]

  subgraph vpc[VPC]
    igw[Internet Gateway]

    subgraph public[Public Subnets]
      alb
      nat[NAT Gateway<br/>single AZ]
      natEip[Elastic IP<br/>for NAT Gateway]
      publicRt[Public Route Table<br/>0.0.0.0/0 -> IGW]
    end

    subgraph private[Private Subnets]
      privateRt[Private Route Table<br/>0.0.0.0/0 -> NAT GW<br/>S3 prefix -> S3 Gateway Endpoint]

      subgraph eks[EKS Cluster<br/>rookies5-macta-eks]
        ing[Kubernetes Ingress<br/>macta.store]

        subgraph frontend[Frontend Stack]
          feSvc[frontend Service<br/>ClusterIP :80]
          fePod[React + TypeScript Pods<br/>Vite Build + Nginx Static Serving]
          feTech[Vite<br/>React<br/>TypeScript<br/>React Router Dom<br/>Tailwind CSS<br/>Shadcn/ui<br/>Lucide React<br/>Axios<br/>TanStack Query v5<br/>Zustand<br/>React Hook Form<br/>Zod<br/>date-fns]
        end

        subgraph backend[Backend Stack]
          beSvc[backend Service<br/>ClusterIP :8080]
          bePod[Spring Boot Pods<br/>REST API Server]
          beTech[Java<br/>Spring Boot<br/>Spring Web<br/>Spring Security<br/>JWT<br/>JPA / Hibernate<br/>Spring Data JPA<br/>MariaDB Driver<br/>AWS SDK<br/>Gradle]
        end

        subgraph k8sops[Kubernetes Ops]
          eso[External Secrets Operator]
          patch[SSM Annotation Patch Job]
          irsaPod[IRSA ServiceAccount<br/>backend-sa]
          deploy[Deployment<br/>Rolling Update]
        end
      end

      rds[RDS MariaDB 10.11<br/>mactadb]
    end

    s3ep[S3 Gateway Endpoint]
  end

  ssm[SSM Parameter Store<br/>DB / S3 / ARN / Image URI]
  cw[CloudWatch<br/>logs and metrics]
  ecr[ECR<br/>frontend/backend images]
  s3[S3 Bucket<br/>rookies5-team4-macta-bucket]
  irsa[IRSA IAM Roles]
  gha[GitHub Actions<br/>Build / Test / Docker Push]
  argocd[Argo CD<br/>GitOps Sync]
  repo[GitHub Repositories<br/>backend / frontend / infra]

  user -->|https://macta.store| r53
  r53 --> internet
  internet <--> igw
  igw <--> publicRt
  publicRt --> alb

  acm -->|HTTPS listener cert| alb
  waf -->|associated by Ingress annotation| alb

  alb --> ing
  ing -->|/| feSvc
  ing -->|/api/v1| beSvc

  feSvc --> fePod
  fePod -.-> feTech

  beSvc --> bePod
  bePod -.-> beTech

  bePod -->|JDBC 3306| rds
  bePod -->|S3 API| privateRt --> s3ep --> s3

  natEip --> nat
  privateRt -->|default route| nat
  nat --> publicRt

  fePod -->|pull image| privateRt
  bePod -->|pull image| privateRt
  privateRt -->|outbound via NAT| internet
  internet --> ecr
  internet --> ssm

  eso -->|read parameters| privateRt
  eso -->|creates Kubernetes Secrets| bePod

  patch -->|read synced Secret| privateRt
  patch -->|patch SA, Ingress, image| ing

  irsa --> eso
  irsa --> bePod
  irsaPod --> bePod

  deploy --> fePod
  deploy --> bePod

  repo --> gha
  gha -->|Docker image push| ecr
  gha -->|update manifest image tag| repo
  repo --> argocd
  argocd -->|sync manifests| eks

  eks -->|cluster and workload metrics/logs| cw
  alb -->|access metrics| cw
  rds -->|database metrics/logs| cw
```

&nbsp;
## 요청 라우팅

```mermaid
sequenceDiagram
  participant Browser
  participant ALB as ALB Ingress
  participant FE as Frontend Nginx Pod
  participant BE as Backend Pod

  Browser->>ALB: GET https://macta.store/
  ALB->>FE: route /
  FE-->>Browser: React static files

  Browser->>ALB: GET https://macta.store/api/v1/...
  ALB->>BE: route /api/v1
  BE-->>Browser: JSON API response
```

프론트엔드 Nginx는 React 정적 파일과 SPA fallback만 담당합니다.

```nginx
server {
    listen 80;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
}
```

프론트엔드의 API base URL은 같은 도메인 상대경로를 권장합니다.

```env
VITE_API_BASE_URL=/api/v1
```

&nbsp;
## AWS&CI/CD 리소스

| <span style="color:white;background-color:#1F3A5F;padding:4px 8px;border-radius:4px;">구분</span> | <span style="color:white;background-color:#1F3A5F;padding:4px 8px;border-radius:4px;">연동 대상</span> | <span style="color:white;background-color:#1F3A5F;padding:4px 8px;border-radius:4px;">역할</span> |
|---|---|---|
| 네트워크 | VPC | EKS / RDS / ALB 네트워크 분리 및 내부 통신 구성 |
| 네트워크 | Public Subnet | Public ALB 및 NAT Gateway 배치 |
| 네트워크 | Private Subnet | EKS Worker Node / Pod / RDS 내부망 구성 |
| 인터넷 연결 | Internet Gateway(IGW) | VPC 외부 인터넷 통신 제공 |
| 아웃바운드 | NAT Gateway | Private Subnet의 외부 인터넷 접근 제공 |
| DNS | Route53 | macta.store 도메인을 ALB로 연결 |
| 인증서 | ACM | HTTPS 인증서 제공 |
| 진입점 | ALB | 외부 HTTP/HTTPS 트래픽 수신 |
| Ingress 자동화 | AWS Load Balancer Controller | Kubernetes Ingress 기반 ALB 생성 및 관리 |
| 컨테이너 오케스트레이션 | EKS | Kubernetes 기반 애플리케이션 운영 |
| 노드 관리 | EKS Node Group | EKS Worker Node 자동 관리 |
| 보안 | WAFv2 | ALB 앞단 요청 필터링 및 Rate Limit 적용 |
| 컨테이너 이미지 | ECR | Frontend / Backend Docker Image 저장 |
| DB | RDS MariaDB 10.11 | 백엔드 영속 데이터 저장 |
| 캐시 | Redis | 캐시 및 실시간 데이터 처리 |
| 파일 저장소 | S3 | 이미지 및 파일 저장 |
| 내부 S3 통신 | S3 Gateway VPC Endpoint | Private Subnet에서 S3 접근 |
| Secret 저장 | SSM Parameter Store | DB/S3/JWT 설정 저장 |
| Secret 동기화 | External Secrets Operator | SSM 값을 Kubernetes Secret으로 변환 |
| 권한 관리 | IRSA | Pod 단위 IAM Role 사용 |
| 배포 자동화 | GitHub Actions | Build / Test / Image Push / Manifest 갱신 |
| GitOps | Argo CD | Kubernetes Manifest 자동 Sync |
| 모니터링 | CloudWatch | EKS / ALB / RDS / WAF 로그 및 메트릭 수집 |

&nbsp;
## 디렉터리 구조

```text
infra/
  argocd/
    backend-application.yml
    frontend-application.yml
  k8s/
    ingress.yaml
    ssm-annotation-patch-job.yaml
    backend/
      namespace.yaml
      backend.yaml
      external-secret.yaml
    frontend/
      frontend.yaml
  terraform/
    main.tf
    variables.tf
    outputs.tf
    vpc.tf
    eks.tf
    ecr.tf
    rds.tf
    s3.tf
    waf.tf
    external-secrets.tf
    aws-load-balancer-controller.tf
    policies/
      aws-load-balancer-controller-iam-policy.json
```

&nbsp;
## Terraform 기본값

| 항목 | 값 |
| --- | --- |
| AWS region | `ap-northeast-2` |
| AWS profile | `team4` |
| Project name | `rookies5-macta` |
| Environment | `dev` |
| EKS cluster | `rookies5-macta-eks` |
| Kubernetes namespace | `rookies5-macta` |
| Backend ServiceAccount | `backend-sa` |
| External Secrets namespace | `external-secrets` |
| External Secrets ServiceAccount | `external-secrets` |
| Domain | `macta.store` |

DB 계정 정보는 `terraform/terraform.tfvars`에서 관리합니다. 이 파일은 Git에 올리지 않습니다.

```hcl
db_instance_class = "db.t3.micro"
db_name           = "mactadb"
db_username       = "admin"
db_password       = "change-me"
```

&nbsp;
## Terraform 적용

```powershell
cd C:\rookies\macta\infra\terraform
$env:AWS_PROFILE = "team4"

terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

kubeconfig 설정:

```powershell
aws eks update-kubeconfig --profile team4 --region ap-northeast-2 --name rookies5-macta-eks
```

주요 output 확인:

```powershell
terraform output -raw eks_cluster_name
terraform output -raw ecr_backend_repository_url
terraform output -raw ecr_frontend_repository_url
terraform output -raw backend_sa_role_arn
terraform output -raw rds_db_url
terraform output -raw s3_bucket_name
terraform output -raw waf_web_acl_arn
```

&nbsp;
## SSM Parameter Store

Kubernetes YAML에는 DB 비밀번호, DB URL, ARN, 인증서 ARN 같은 환경별 값을 직접 넣지 않습니다. SSM Parameter Store에 저장하고 External Secrets Operator가 Kubernetes Secret으로 동기화합니다.

현재 manifest가 참조하는 SSM 경로는 다음과 같습니다.

| SSM parameter | 용도 |
| --- | --- |
| `/rookies5-macta/dev/backend/DB_URL` | 백엔드 DB JDBC URL |
| `/rookies5-macta/dev/backend/DB_USERNAME` | DB 사용자명 |
| `/rookies5-macta/dev/backend/DB_PASSWORD` | DB 비밀번호 |
| `/rookies5-macta/dev/backend/S3_BUCKET_NAME` | S3 버킷명 |
| `/rookies5-macta/dev/backend/AWS_REGION` | AWS region |
| `/rookies5-macta/dev/infra/BACKEND_ROLE_ARN` | 백엔드 IRSA Role ARN |
| `/rookies5-macta/dev/infra/WAF_WEB_ACL_ARN` | WAF Web ACL ARN |
| `/rookies5-macta/dev/infra/ACM_CERTIFICATE_ARN` | ACM 인증서 ARN |
| `/rookies5-macta/dev/infra/BACKEND_IMAGE` | 백엔드 이미지 URI |
| `/rookies5-macta/dev/infra/FRONTEND_IMAGE` | 프론트엔드 이미지 URI |

SSM 값 생성 예시:

```powershell
cd C:\rookies\macta\infra\terraform

$backendRoleArn = terraform output -raw backend_sa_role_arn
$wafWebAclArn   = terraform output -raw waf_web_acl_arn
$backendImage   = "$(terraform output -raw ecr_backend_repository_url):latest"
$frontendImage  = "$(terraform output -raw ecr_frontend_repository_url):latest"
$dbUrl          = terraform output -raw rds_db_url
$s3BucketName   = terraform output -raw s3_bucket_name

aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/backend/DB_URL" --type SecureString --value $dbUrl --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/backend/DB_USERNAME" --type SecureString --value "admin" --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/backend/DB_PASSWORD" --type SecureString --value "CHANGE_ME" --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/backend/S3_BUCKET_NAME" --type SecureString --value $s3BucketName --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/backend/AWS_REGION" --type String --value "ap-northeast-2" --overwrite

aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/infra/BACKEND_ROLE_ARN" --type SecureString --value $backendRoleArn --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/infra/WAF_WEB_ACL_ARN" --type SecureString --value $wafWebAclArn --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/infra/ACM_CERTIFICATE_ARN" --type SecureString --value "CHANGE_ME_ACM_CERTIFICATE_ARN" --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/infra/BACKEND_IMAGE" --type SecureString --value $backendImage --overwrite
aws ssm put-parameter --profile team4 --region ap-northeast-2 --name "/rookies5-macta/dev/infra/FRONTEND_IMAGE" --type SecureString --value $frontendImage --overwrite
```

조회:

```powershell
aws ssm get-parameters-by-path --profile team4 --region ap-northeast-2 --path "/rookies5-macta/dev" --recursive --with-decryption --query "Parameters[*].[Name,Type,Value]" --output table
```

&nbsp;
## External Secrets

Terraform은 External Secrets Operator를 Helm으로 설치합니다.

- Namespace: `external-secrets`
- ServiceAccount: `external-secrets`
- 인증 방식: IRSA
- SSM 권한: `ssm:GetParameter`, `ssm:GetParameters`, `ssm:GetParametersByPath`, `ssm:DescribeParameters`

Kubernetes manifest:

- `k8s/backend/external-secret.yaml`
  - `ClusterSecretStore`: AWS SSM Parameter Store 연결
  - `ExternalSecret rookies5-macta-backend-secret`: 백엔드 런타임 환경변수 Secret 생성
  - `ExternalSecret rookies5-macta-infra-config`: IAM Role, WAF, ACM, 이미지 URI Secret 생성

확인:

```powershell
kubectl get deployment -n external-secrets external-secrets
kubectl get externalsecret -n rookies5-macta
kubectl get secret backend-secret -n rookies5-macta
kubectl get secret rookies5-macta-infra-config -n rookies5-macta
```

&nbsp;
## Kubernetes 배포

수동 적용:

```powershell
cd C:\rookies\macta\infra

kubectl apply -f .\k8s\backend\namespace.yaml
kubectl apply -f .\k8s\backend\external-secret.yaml
kubectl apply -f .\k8s\backend\backend.yaml
kubectl apply -f .\k8s\frontend\frontend.yaml
kubectl apply -f .\k8s\ingress.yaml
kubectl apply -f .\k8s\ssm-annotation-patch-job.yaml
```

확인:

```powershell
kubectl get pods -n rookies5-macta
kubectl get svc -n rookies5-macta
kubectl get ingress -n rookies5-macta
```

&nbsp;
## Ingress, ALB, HTTPS

ALB는 Terraform에서 직접 생성하지 않습니다. Terraform은 AWS Load Balancer Controller가 동작할 수 있도록 IAM Role, ServiceAccount, Helm release를 구성하고, 실제 ALB는 `k8s/ingress.yaml`의 Kubernetes Ingress 리소스를 AWS Load Balancer Controller가 감지해 생성합니다.

즉, 이 구조에서 Ingress는 클러스터 외부 트래픽을 프론트엔드와 백엔드 Service로 나누는 진입 라우터 역할을 합니다.

현재 라우팅:

```text
https://macta.store/        -> rookies5-macta-frontend-service:80
https://macta.store/api/v1  -> rookies5-macta-backend-service:8080
```

요청 흐름:

```text
User Browser
  -> Route53 macta.store A Alias
  -> Public ALB
  -> Kubernetes Ingress
      /        -> frontend Service -> frontend Pod
      /api/v1  -> backend Service  -> backend Pod
```

프론트엔드는 React 정적 파일을 Nginx로 서빙하고, API 호출은 같은 도메인의 `/api/v1` 상대 경로를 사용합니다. 브라우저가 `https://macta.store/api/v1/...`로 요청하면 ALB Ingress가 해당 요청을 백엔드 Service로 전달합니다. 따라서 프론트엔드 Pod가 백엔드 Pod를 직접 호출하는 구조가 아니라, 사용자 브라우저의 API 요청이 ALB와 Ingress의 경로 기반 라우팅을 통해 백엔드로 전달되는 구조입니다.

Ingress 주요 설정:

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  ingressClassName: alb
  rules:
    - host: macta.store
      http:
        paths:
          - path: /api/v1
            pathType: Prefix
            backend:
              service:
                name: rookies5-macta-backend-service
                port:
                  number: 8080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rookies5-macta-frontend-service
                port:
                  number: 80
```

주요 annotation 의미:

| annotation | 의미 |
| --- | --- |
| `kubernetes.io/ingress.class: alb` | AWS Load Balancer Controller가 처리할 Ingress임을 표시 |
| `alb.ingress.kubernetes.io/scheme: internet-facing` | 외부 인터넷에서 접근 가능한 public ALB 생성 |
| `alb.ingress.kubernetes.io/target-type: ip` | ALB Target Group이 Pod IP를 직접 대상으로 사용 |
| `alb.ingress.kubernetes.io/listen-ports` | ALB listener 포트 설정. 현재 HTTP 80, HTTPS 443 사용 |
| `alb.ingress.kubernetes.io/ssl-redirect: "443"` | HTTP 요청을 HTTPS로 리다이렉트 |

WAF/ACM처럼 환경마다 ARN이 달라지는 값은 manifest에 직접 고정하지 않고 SSM Parameter Store에 저장합니다. External Secrets Operator가 이 값을 `rookies5-macta-infra-config` Secret으로 동기화하고, `ssm-annotation-patch-job`이 Ingress annotation으로 주입합니다.

- `alb.ingress.kubernetes.io/wafv2-acl-arn`
- `alb.ingress.kubernetes.io/certificate-arn`
- `alb.ingress.kubernetes.io/listen-ports: [{"HTTP":80},{"HTTPS":443}]`
- `alb.ingress.kubernetes.io/ssl-redirect: "443"`

이 방식으로 기본 Ingress 라우팅은 Git에 선언하고, 계정/환경에 따라 달라지는 WAF Web ACL ARN과 ACM 인증서 ARN은 SSM을 통해 런타임에 반영합니다.

확인:

```powershell
kubectl get ingress rookies5-macta-frontend-ingress -n rookies5-macta
kubectl describe ingress rookies5-macta-frontend-ingress -n rookies5-macta
```

확인할 항목:

- `Address`: AWS Load Balancer Controller가 생성한 ALB DNS 이름
- `Rules`: `macta.store` host와 `/`, `/api/v1` path 라우팅
- `Annotations`: certificate ARN, WAF ACL ARN, HTTPS listener, SSL redirect 적용 여부
- `Events`: ALB, TargetGroup, Listener 생성 또는 오류 메시지

&nbsp;
## Route53 and ACM

도메인:

```text
macta.store
```

Route53 public hosted zone에 필요한 레코드:

| 이름 | 타입 | 대상 |
| --- | --- | --- |
| `macta.store` | `A Alias` | ALB dualstack DNS |
| `*.macta.store` | `A Alias` | ALB dualstack DNS, 필요 시 |
| `_...macta.store` | `CNAME` | ACM DNS validation |

주의:

- ACM DNS validation CNAME은 인증서 검증용입니다. 서비스 트래픽을 ALB로 보내지 않습니다.
- `*.macta.store`는 `www.macta.store`, `api.macta.store` 같은 서브도메인에만 매칭됩니다.
- 루트 도메인 `macta.store`를 쓰려면 별도 `macta.store A Alias -> ALB` 레코드가 필요합니다.
- ALB 기본 DNS로 HTTPS 접속하면 인증서 이름이 맞지 않아 브라우저 경고가 납니다. 최종 접속은 `https://macta.store`로 확인합니다.

DNS 확인:

```powershell
nslookup macta.store
nslookup macta.store 8.8.8.8
```

&nbsp;
## RDS

현재 RDS 엔진은 MySQL이 아니라 MariaDB입니다.

| 항목 | 값 |
| --- | --- |
| Engine | `mariadb` |
| Engine version | `10.11` |
| DB name | `mactadb` |
| Port | `3306` |
| Subnet | Private subnets |
| Public access | disabled |

JDBC URL은 MariaDB의 MySQL 호환 프로토콜을 사용해 다음 형태로 구성합니다.

```text
jdbc:mysql://<rds-endpoint>:3306/mactadb?serverTimezone=Asia/Seoul&characterEncoding=UTF-8
```

이 값은 SSM의 `/rookies5-macta/dev/backend/DB_URL`에 저장하고, External Secrets가 `backend-secret`으로 동기화합니다.

&nbsp;
## S3

S3는 애플리케이션 파일 저장소로 사용합니다.

- Bucket: `rookies5-team4-macta-bucket`
- Public access block 적용
- EKS private subnet에서 S3 Gateway Endpoint로 접근
- 백엔드 Pod는 IRSA Role을 통해 S3 권한 사용

백엔드 ServiceAccount:

```text
backend-sa
```

IRSA annotation은 SSM 값을 읽은 patch Job이 주입합니다.

```text
eks.amazonaws.com/role-arn=<BACKEND_ROLE_ARN>
```

확인:

```powershell
kubectl get serviceaccount backend-sa -n rookies5-macta -o yaml
```

&nbsp;
## ECR and Images

Terraform이 ECR repository를 생성합니다.

```powershell
terraform output -raw ecr_backend_repository_url
terraform output -raw ecr_frontend_repository_url
```

이미지 예시:

```text
105588835975.dkr.ecr.ap-northeast-2.amazonaws.com/rookies5-macta/backend:<tag>
105588835975.dkr.ecr.ap-northeast-2.amazonaws.com/rookies5-macta/frontend:<tag>
```

현재 Kubernetes manifest의 `image`는 placeholder로 둘 수 있습니다. 실제 이미지는 CI/CD 또는 SSM patch Job에서 반영합니다.

이미지 pull 오류 확인:

```powershell
kubectl describe pod -n rookies5-macta -l app=rookies5-macta-frontend
kubectl describe pod -n rookies5-macta -l app=rookies5-macta-backend
```

&nbsp;
## WAF

Terraform은 Regional WAF Web ACL을 생성합니다.

적용 rule:

- Rate limit per IP
- AWS Managed Rules Common Rule Set
- AWS Managed Rules Known Bad Inputs Rule Set
- AWS Managed Rules SQLi Rule Set

WAF는 생성만으로 ALB에 자동 연결되지 않습니다. 현재 구조에서는 WAF ARN을 SSM에 저장하고, `ssm-annotation-patch-job`이 Ingress annotation으로 주입합니다.

```text
alb.ingress.kubernetes.io/wafv2-acl-arn=<WAF_WEB_ACL_ARN>
```

&nbsp;
## Argo CD
### EKS 배포 애플리케이션 상태 확인
<img width="2540" height="1232" alt="image" src="https://github.com/user-attachments/assets/486f58b8-13d5-4fe7-8f63-fe5e5a102413" />

### 백엔드 클러스터 내 배포 리소스 상태 확인
<img width="2264" height="1150" alt="image" src="https://github.com/user-attachments/assets/4d91be76-0bbd-46d6-807d-35c0c1cb0912" />

### 프론트엔드 클러스터 내 배포 리소스 상태 확인
<img width="2044" height="1342" alt="image" src="https://github.com/user-attachments/assets/edba98d6-213c-4899-97d2-0a8ddc504fbf" />


Argo CD는 애플리케이션 배포 상태를 확인하고 GitOps 방식으로 manifest를 sync하기 위한 도구입니다.

프론트엔드/백엔드 레포에서 이미지 빌드 후 infra manifest를 갱신하더라도 Argo CD가 즉시 변경사항을 감지하지 못할 수 있습니다. 이를 줄이기 위해 Argo CD webhook을 함께 사용합니다. GitHub push 이벤트가 Argo CD webhook으로 전달되면 Application refresh가 트리거되어 기본 polling 주기를 기다리지 않고 빠르게 sync 대상 변경을 감지할 수 있습니다.

설치 예시:

```powershell
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

UI를 임시로 볼 때:

```powershell
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

브라우저:

```text
https://localhost:8080
```

초기 비밀번호:

```powershell
$encoded = kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}"
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
```

LoadBalancer로 노출할 수도 있지만, 실습 후에는 `ClusterIP`로 되돌리는 것을 권장합니다.

```powershell
kubectl patch svc argocd-server -n argocd --type merge -p '{"spec":{"type":"LoadBalancer"}}'
kubectl patch svc argocd-server -n argocd --type merge -p '{"spec":{"type":"ClusterIP"}}'
```

GitHub webhook URL:

```text
https://<argocd-server-domain-or-lb>/api/webhook
```

GitHub webhook 설정:

```text
Payload URL: https://<argocd-server-domain-or-lb>/api/webhook
Content type: application/json
Event: Just the push event
```

Argo CD를 외부 LoadBalancer로 노출하지 않는 운영 환경에서는 port-forward 대신 Ingress, VPN, 사내망, 또는 별도 webhook relay 구성을 사용합니다.

&nbsp;
## CI/CD 방향

권장 흐름:

```text
Frontend or Backend repo push
  -> GitHub Actions
  -> Docker build
  -> ECR push
  -> infra manifest image tag update commit
  -> GitHub webhook triggers Argo CD refresh
  -> Argo CD sync
  -> EKS rolling update
```

SSM에 유지할 값:

- DB URL, username, password
- S3 bucket name
- Backend IRSA Role ARN
- WAF Web ACL ARN
- ACM certificate ARN
- AWS region

이미지 URI는 일반적으로 민감정보가 아니므로, 완전한 GitOps를 원하면 manifest에 이미지 태그를 커밋하고 Argo CD가 sync하게 하는 구조가 더 단순합니다.

현재 SSM 기반 patch Job도 지원합니다.

```text
SSM FRONTEND_IMAGE/BACKEND_IMAGE
  -> ExternalSecret
  -> rookies5-macta-infra-config Secret
  -> ssm-annotation-patch-job
  -> kubectl set image
```

&nbsp;
## Rolling Update

프론트엔드와 백엔드는 Kubernetes Deployment의 Rolling Update 방식을 사용합니다. 이미지 태그가 변경되거나 Pod template이 변경되면 Kubernetes가 새 ReplicaSet을 만들고, 기존 Pod를 한 번에 모두 내리지 않고 순차적으로 새 Pod로 교체합니다.

현재 설정:

```yaml
replicas: 2
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

적용 위치:

```text
k8s/frontend/frontend.yaml
k8s/backend/backend.yaml
```

동작 방식:

```text
1. 현재 frontend/backend Pod는 각각 2개 replica로 실행
2. 새 이미지 태그가 manifest에 반영됨
3. Argo CD sync 또는 kubectl apply가 Deployment 변경을 적용
4. Kubernetes가 새 ReplicaSet 생성
5. maxSurge: 1 설정에 따라 기존 2개 Pod 위에 새 Pod 1개를 추가로 생성
6. readinessProbe가 성공해 새 Pod가 Ready 상태가 되면 Service 트래픽 대상에 포함
7. maxUnavailable: 0 설정에 따라 Ready Pod 수를 유지하면서 기존 Pod 1개 종료
8. 같은 과정을 반복해 모든 Pod를 새 버전으로 교체
```

`maxSurge: 1`은 업데이트 중 원하는 replica 수보다 Pod를 최대 1개 더 만들 수 있다는 의미입니다. `replicas: 2` 기준으로 업데이트 중 일시적으로 최대 3개 Pod가 실행될 수 있습니다.

`maxUnavailable: 0`은 업데이트 중 사용 가능한 Pod 수를 줄이지 않겠다는 의미입니다. 새 Pod가 Ready 되기 전에는 기존 Pod를 먼저 종료하지 않으므로, 배포 중 서비스 중단 가능성을 줄입니다.

따라서 새 버전 Pod가 이미지 오류, 설정 오류, 애플리케이션 기동 실패 등으로 Ready 상태가 되지 못하면 기존 Pod가 계속 유지됩니다. 이 경우 Rolling Update가 중간에서 멈추고 Service는 기존 Ready Pod로 트래픽을 계속 전달하므로, 실패한 배포가 곧바로 서비스 중단으로 이어지지 않습니다.

readinessProbe는 새 Pod를 Service 트래픽에 넣어도 되는지 판단하는 기준입니다.

```text
frontend: HTTP GET /, port 80, initialDelaySeconds 10, periodSeconds 5
backend:  TCP socket 8080, initialDelaySeconds 30, periodSeconds 10
```

배포 상태 확인:

```powershell
kubectl rollout status deployment/rookies5-macta-frontend -n rookies5-macta
kubectl rollout status deployment/rookies5-macta-backend -n rookies5-macta
```

ReplicaSet과 Pod 교체 과정 확인:

```powershell
kubectl get rs -n rookies5-macta
kubectl get pods -n rookies5-macta -w
```

문제가 생겼을 때 이전 버전으로 롤백:

```powershell
kubectl rollout undo deployment/rookies5-macta-frontend -n rookies5-macta
kubectl rollout undo deployment/rookies5-macta-backend -n rookies5-macta
```

&nbsp;
## 운영 확인 명령

```powershell
kubectl get pods -n rookies5-macta
kubectl get svc -n rookies5-macta
kubectl get ingress -n rookies5-macta
kubectl describe ingress rookies5-macta-frontend-ingress -n rookies5-macta
kubectl get externalsecret -n rookies5-macta
kubectl get secret backend-secret -n rookies5-macta
kubectl get secret rookies5-macta-infra-config -n rookies5-macta
```

ALB 접속:

```text
http://<alb-dns>
https://macta.store
```

주의:

- ALB 기본 DNS로 HTTPS 접속하면 인증서 mismatch 경고가 날 수 있습니다.
- 최종 HTTPS 검증은 `https://macta.store`로 합니다.
- `macta.store`가 DNS 오류를 내면 Route53의 `macta.store A Alias -> ALB` 레코드와 도메인 네임서버 위임을 확인합니다.

&nbsp;
## Git에 올리지 않는 파일

다음 파일은 Git에 올리지 않습니다.

- `terraform/.terraform/`
- `terraform/terraform.tfstate`
- `terraform/terraform.tfstate.backup`
- `terraform/*.tfvars`
- Terraform plan output
