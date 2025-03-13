terraform {
  required_providers {
    k3d = {
      source  = "sneakybugs/k3d"
      version = "1.0.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.11.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.23.0"
    }
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "4.3.1"
    }
  }
}

provider "k3d" {}

resource "k3d_cluster" "kubed" {
  name       = "kubed"
  k3d_config = file("cluster.yaml")
}

# Configure Kubernetes provider to use the k3d cluster
provider "kubernetes" {
  config_path = k3d_cluster.kubed.kubeconfig_path
}

# Configure Helm provider to use the k3d cluster
provider "helm" {
  kubernetes {
    config_path = k3d_cluster.kubed.kubeconfig_path
  }
}

# Install Traefik with auto-discovery
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://helm.traefik.io/traefik"
  chart            = "traefik"
  namespace        = "traefik-system"
  create_namespace = true
  
  values = [
    <<-EOT
    additionalArguments:
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access.log"
      - "--accesslog.format=json"
      - "--api.dashboard=true"
      - "--providers.kubernetesingress.ingressclass=traefik"
      - "--providers.kubernetescrd=true"
      - "--providers.kubernetescrd.allowCrossNamespace=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
    
    experimental:
      plugins:
        enabled: true
    
    logs:
      general:
        level: INFO
      access:
        enabled: true
    
    volumes:
      - name: traefik-logs
        mountPath: /var/log/traefik
        type: persistentVolumeClaim
        persistentVolumeClaim:
          claimName: traefik-logs-pvc
    
    persistence:
      enabled: true
      name: traefik-logs-pvc
      accessMode: ReadWriteOnce
      size: 1Gi
    EOT
  ]
  
  depends_on = [k3d_cluster.kubed]
}

# Install CrowdSec
resource "helm_release" "crowdsec" {
  name             = "crowdsec"
  repository       = "https://crowdsecurity.github.io/helm-charts"
  chart            = "crowdsec"
  namespace        = "crowdsec"
  create_namespace = true
  
  values = [
    <<-EOT
    config:
      console:
        enabled: true
      crowdsec:
        parsers:
          - crowdsecurity/traefik-logs
        acquisition:
          - filenames:
            - /var/log/crowdsec/traefik-access.log
            labels:
              type: traefik
    EOT
  ]
  
  depends_on = [helm_release.traefik]
}

# Install CrowdSec Bouncer middleware for Traefik
resource "kubernetes_manifest" "crowdsec_traefik_middleware" {
  manifest = {
    apiVersion = "traefik.containo.us/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "crowdsec-bouncer"
      namespace = "traefik-system"
    }
    spec = {
      plugin = {
        crowdsec-bouncer = {
          crowdsecLapiKey    = "${random_password.crowdsec_key.result}"
          crowdsecLapiUrl    = "http://crowdsec.crowdsec.svc.cluster.local:8080"
          crowdsecMode       = "stream"
          defaultDecision    = "ban"
          updateIntervalSec  = 60
          clientTrustedIPs   = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16","100.0.0.0/8"]
        }
      }
    }
  }
  
  depends_on = [helm_release.crowdsec, helm_release.traefik]
}

resource "random_password" "crowdsec_key" {
  length  = 32
  special = false
}

# Install Vault for secrets management
resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  namespace        = "vault"
  create_namespace = true
  
  values = [
    <<-EOT
    server:
      dev:
        enabled: true
      service:
        enabled: true
    ui:
      enabled: true
    EOT
  ]
  
  depends_on = [k3d_cluster.kubed]
}

# Install Gitea
resource "helm_release" "gitea" {
  name             = "gitea"
  repository       = "https://dl.gitea.io/charts/"
  chart            = "gitea"
  namespace        = "gitea"
  create_namespace = true
  
  values = [
    <<-EOT
    gitea:
      admin:
        username: gitea_admin
        password: "${random_password.gitea_admin_password.result}"
        email: "admin@example.com"
      config:
        server:
          DOMAIN: gitea
          ROOT_URL: http://gitea.example.com
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: traefik
      hosts:
        - host: gitea.example.com
          paths:
            - path: /
              pathType: Prefix
    postgresql:
      enabled: true
      persistence:
        enabled: true
        size: 1Gi
    EOT
  ]
  
  depends_on = [helm_release.traefik]
}

resource "random_password" "gitea_admin_password" {
  length  = 16
  special = true
}

# Install ArgoCD for CI/CD
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  
  values = [
    <<-EOT
    server:
      extraArgs:
        - --insecure
      ingress:
        enabled: true
        annotations:
          kubernetes.io/ingress.class: traefik
          traefik.ingress.kubernetes.io/router.middlewares: traefik-system-crowdsec-bouncer@kubernetescrd
        hosts:
          - argocd.example.com
    configs:
      cm:
        url: https://argocd.example.com
        oidc.config: |
          name: Keycloak
          issuer: https://keycloak.example.com/auth/realms/kubernetes
          clientID: argocd
          clientSecret: $oidc.keycloak.clientSecret
          requestedScopes: ["openid", "profile", "email", "groups"]
    EOT
  ]
  
  depends_on = [helm_release.traefik, kubernetes_manifest.crowdsec_traefik_middleware]
}

# Install Keycloak for OIDC
resource "helm_release" "keycloak" {
  name             = "keycloak"
  repository       = "https://codecentric.github.io/helm-charts"
  chart            = "keycloak"
  namespace        = "keycloak"
  create_namespace = true
  
  values = [
    <<-EOT
    extraEnv: |
      - name: KEYCLOAK_ADMIN
        value: admin
      - name: KEYCLOAK_ADMIN_PASSWORD
        value: "${random_password.keycloak_admin_password.result}"
      - name: PROXY_ADDRESS_FORWARDING
        value: "true"
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: traefik
        traefik.ingress.kubernetes.io/router.middlewares: traefik-system-crowdsec-bouncer@kubernetescrd
      rules:
        - host: keycloak.example.com
          paths:
            - path: /
              pathType: Prefix
    postgresql:
      enabled: true
      persistence:
        enabled: true
        size: 1Gi
    EOT
  ]
  
  depends_on = [helm_release.traefik, kubernetes_manifest.crowdsec_traefik_middleware]
}

resource "random_password" "keycloak_admin_password" {
  length  = 16
  special = true
}

# Configure Vault as a certificate store for Traefik
resource "null_resource" "configure_vault_for_traefik" {
  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG=${k3d_cluster.kubed.kubeconfig_path}
      
      # Wait for Vault to become ready
      kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=vault -n vault --timeout=300s
      
      # Setup Vault KV store for certificates
      kubectl -n vault exec vault-0 -- vault secrets enable -version=2 kv
      
      # Create policy for Traefik
      kubectl -n vault exec vault-0 -- vault policy write traefik -<<EOF
      path "kv/data/certificates/*" {
        capabilities = ["read", "list"]
      }
      EOF
      
      # Create Kubernetes auth
      kubectl -n vault exec vault-0 -- vault auth enable kubernetes
    EOT
  }
  
  depends_on = [helm_release.vault, helm_release.traefik]
}

# Configure Keycloak provider to create OIDC clients
provider "keycloak" {
  client_id     = "admin-cli"
  username      = "admin"
  password      = random_password.keycloak_admin_password.result
  url           = "https://keycloak.example.com"
  initial_login = false
}

# Output important information
output "gitea_admin_password" {
  value     = random_password.gitea_admin_password.result
  sensitive = true
}

output "keycloak_admin_password" {
  value     = random_password.keycloak_admin_password.result
  sensitive = true
}

output "crowdsec_lapi_key" {
  value     = random_password.crowdsec_key.result
  sensitive = true
}

output "kubeconfig_path" {
  value = k3d_cluster.kubed.kubeconfig_path
}
