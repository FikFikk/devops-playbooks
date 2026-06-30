terraform {
  required_version = ">= 1.5"
  
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.51.0"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [file("${path.module}/argocd-values.yaml")]

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.14.0"
  namespace  = "kube-system"

  set {
    name  = "provider"
    value = var.dns_provider
  }

  set {
    name  = "domainFilters[0]"
    value = var.preview_domain
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.13.0"
  namespace  = "cert-manager"
  
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "kubernetes_cluster_issuer" "letsencrypt" {
  metadata {
    name = "letsencrypt-prod"
  }

  spec {
    acme {
      server = "https://acme-v02.api.letsencrypt.org/directory"
      email  = var.acme_email

      private_key_secret_ref {
        name = "letsencrypt-prod"
      }

      solvers {
        http01 {
          ingress {
            class = "nginx"
          }
        }
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_cron_job_v1" "cleanup_reaper" {
  metadata {
    name      = "ephemeral-cleanup"
    namespace = "kube-system"
  }

  spec {
    schedule = "0 */6 * * *"  # Every 6 hours

    job_template {
      metadata {}
      
      spec {
        template {
          metadata {}
          
          spec {
            service_account_name = kubernetes_service_account.cleanup_reaper.metadata[0].name
            restart_policy       = "OnFailure"

            container {
              name    = "cleanup"
              image   = "bitnami/kubectl:latest"
              command = ["/bin/bash", "/scripts/cleanup-reaper.sh"]

              env {
                name  = "TTL_HOURS"
                value = "24"
              }

              env {
                name = "GITHUB_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "github-token"
                    key  = "token"
                  }
                }
              }

              env {
                name  = "GITHUB_REPO"
                value = var.github_repo
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map.cleanup_script.metadata[0].name
                default_mode = "0755"
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_account" "cleanup_reaper" {
  metadata {
    name      = "cleanup-reaper"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding" "cleanup_reaper" {
  metadata {
    name = "cleanup-reaper"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.cleanup_reaper.metadata[0].name
    namespace = kubernetes_service_account.cleanup_reaper.metadata[0].namespace
  }
}

resource "kubernetes_config_map" "cleanup_script" {
  metadata {
    name      = "cleanup-reaper-script"
    namespace = "kube-system"
  }

  data = {
    "cleanup-reaper.sh" = file("${path.module}/../scripts/cleanup-reaper.sh")
  }
}
