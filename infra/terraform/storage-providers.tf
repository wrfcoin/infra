# Storage Providers Infrastructure
# Deploys IPFS, Filecoin Lotus, and Arweave gateway nodes
# Related: wrfcoin/storage-providers repo, infra#13

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "storage_region" {
  description = "Primary region for storage nodes"
  type        = string
  default     = "us-east-1"
}

variable "ipfs_node_count" {
  description = "Number of IPFS nodes in the cluster"
  type        = number
  default     = 3
}

variable "filecoin_lotus_enabled" {
  description = "Enable Filecoin Lotus full node"
  type        = bool
  default     = true
}

variable "arweave_gateway_enabled" {
  description = "Enable Arweave gateway"
  type        = bool
  default     = true
}

variable "ipfs_storage_size" {
  description = "PVC size for each IPFS node"
  type        = string
  default     = "100Gi"
}

variable "filecoin_storage_size" {
  description = "PVC size for Filecoin Lotus chain data"
  type        = string
  default     = "500Gi"
}

variable "arweave_cache_size" {
  description = "PVC size for Arweave gateway cache"
  type        = string
  default     = "50Gi"
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "storage" {
  metadata {
    name = "storage"

    labels = {
      "app.kubernetes.io/part-of" = "wrfcoin"
      "app.kubernetes.io/managed-by" = "terraform"
      purpose                        = "storage-providers"
    }
  }
}

# ---------------------------------------------------------------------------
# IPFS Cluster
# ---------------------------------------------------------------------------

resource "kubernetes_stateful_set" "ipfs" {
  metadata {
    name      = "ipfs"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "ipfs"
      component = "storage"
    }
  }

  spec {
    service_name = "ipfs"
    replicas     = var.ipfs_node_count

    selector {
      match_labels = {
        app = "ipfs"
      }
    }

    template {
      metadata {
        labels = {
          app       = "ipfs"
          component = "storage"
        }

        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "5001"
          "prometheus.io/path"   = "/debug/metrics/prometheus"
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
        }

        container {
          name  = "ipfs"
          image = "ipfs/kubo:v0.24.0"

          port {
            name           = "swarm"
            container_port = 4001
            protocol       = "TCP"
          }

          port {
            name           = "api"
            container_port = 5001
            protocol       = "TCP"
          }

          port {
            name           = "gateway"
            container_port = 8080
            protocol       = "TCP"
          }

          env {
            name  = "IPFS_PROFILE"
            value = "server"
          }

          resources {
            requests = {
              memory = "512Mi"
              cpu    = "500m"
            }
            limits = {
              memory = "2Gi"
              cpu    = "1"
            }
          }

          volume_mount {
            name       = "ipfs-data"
            mount_path = "/data/ipfs"
          }

          readiness_probe {
            http_get {
              path = "/api/v0/id"
              port = 5001
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
          }

          liveness_probe {
            http_get {
              path = "/api/v0/id"
              port = 5001
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "ipfs-data"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "gp3"

        resources {
          requests = {
            storage = var.ipfs_storage_size
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "ipfs_api" {
  metadata {
    name      = "ipfs-api"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "ipfs"
      component = "storage"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "ipfs"
    }

    port {
      name        = "api"
      port        = 5001
      target_port = 5001
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "ipfs_gateway" {
  metadata {
    name      = "ipfs-gateway"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "ipfs"
      component = "storage"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "ipfs"
    }

    port {
      name        = "gateway"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "ipfs_swarm" {
  metadata {
    name      = "ipfs-swarm"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "ipfs"
      component = "storage"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "ipfs"
    }

    port {
      name        = "swarm"
      port        = 4001
      target_port = 4001
      protocol    = "TCP"
    }
  }
}

# ---------------------------------------------------------------------------
# Filecoin Lotus
# ---------------------------------------------------------------------------

resource "kubernetes_stateful_set" "filecoin_lotus" {
  count = var.filecoin_lotus_enabled ? 1 : 0

  metadata {
    name      = "filecoin-lotus"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "filecoin-lotus"
      component = "storage"
    }
  }

  spec {
    service_name = "filecoin-lotus"
    replicas     = 1

    selector {
      match_labels = {
        app = "filecoin-lotus"
      }
    }

    template {
      metadata {
        labels = {
          app       = "filecoin-lotus"
          component = "storage"
        }

        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "1234"
        }
      }

      spec {
        container {
          name  = "lotus"
          image = "filecoin/lotus:v1.25.2"

          port {
            name           = "api"
            container_port = 1234
            protocol       = "TCP"
          }

          port {
            name           = "p2p"
            container_port = 1235
            protocol       = "TCP"
          }

          env {
            name = "LOTUS_API_LISTENADDRESS"
            value = "/ip4/0.0.0.0/tcp/1234/http"
          }

          resources {
            requests = {
              memory = "4Gi"
              cpu    = "2"
            }
            limits = {
              memory = "8Gi"
              cpu    = "4"
            }
          }

          volume_mount {
            name       = "lotus-data"
            mount_path = "/root/.lotus"
          }

          liveness_probe {
            http_get {
              path = "/rpc/v0"
              port = 1234
            }
            initial_delay_seconds = 120
            period_seconds        = 60
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/rpc/v0"
              port = 1234
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "lotus-data"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "gp3"

        resources {
          requests = {
            storage = var.filecoin_storage_size
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "filecoin_api" {
  count = var.filecoin_lotus_enabled ? 1 : 0

  metadata {
    name      = "filecoin-api"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "filecoin-lotus"
      component = "storage"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "filecoin-lotus"
    }

    port {
      name        = "api"
      port        = 1234
      target_port = 1234
      protocol    = "TCP"
    }
  }
}

# ---------------------------------------------------------------------------
# Arweave Gateway
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "arweave_gateway" {
  count = var.arweave_gateway_enabled ? 1 : 0

  metadata {
    name      = "arweave-gateway"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "arweave-gateway"
      component = "storage"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "arweave-gateway"
      }
    }

    template {
      metadata {
        labels = {
          app       = "arweave-gateway"
          component = "storage"
        }

        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "1984"
        }
      }

      spec {
        container {
          name  = "arweave-gateway"
          image = "arweave/gateway:v0.5.0"

          port {
            name           = "http"
            container_port = 1984
            protocol       = "TCP"
          }

          resources {
            requests = {
              memory = "1Gi"
              cpu    = "500m"
            }
            limits = {
              memory = "4Gi"
              cpu    = "2"
            }
          }

          volume_mount {
            name       = "arweave-cache"
            mount_path = "/app/cache"
          }

          readiness_probe {
            http_get {
              path = "/info"
              port = 1984
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }

          liveness_probe {
            http_get {
              path = "/info"
              port = 1984
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
          }
        }

        volume {
          name = "arweave-cache"

          persistent_volume_claim {
            claim_name = "arweave-cache"
          }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "arweave_cache" {
  count = var.arweave_gateway_enabled ? 1 : 0

  metadata {
    name      = "arweave-cache"
    namespace = kubernetes_namespace.storage.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "gp3"

    resources {
      requests = {
        storage = var.arweave_cache_size
      }
    }
  }
}

resource "kubernetes_service" "arweave_gateway" {
  count = var.arweave_gateway_enabled ? 1 : 0

  metadata {
    name      = "arweave-gateway"
    namespace = kubernetes_namespace.storage.metadata[0].name

    labels = {
      app       = "arweave-gateway"
      component = "storage"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "arweave-gateway"
    }

    port {
      name        = "http"
      port        = 1984
      target_port = 1984
      protocol    = "TCP"
    }
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "ipfs_api_endpoint" {
  description = "IPFS API endpoint (cluster-internal)"
  value       = "http://ipfs-api.storage.svc.cluster.local:5001"
}

output "ipfs_gateway_endpoint" {
  description = "IPFS gateway endpoint (cluster-internal)"
  value       = "http://ipfs-gateway.storage.svc.cluster.local:8080"
}

output "filecoin_api_endpoint" {
  description = "Filecoin Lotus API endpoint (cluster-internal)"
  value       = var.filecoin_lotus_enabled ? "http://filecoin-api.storage.svc.cluster.local:1234/rpc/v0" : ""
}

output "arweave_gateway_endpoint" {
  description = "Arweave gateway endpoint (cluster-internal)"
  value       = var.arweave_gateway_enabled ? "http://arweave-gateway.storage.svc.cluster.local:1984" : ""
}
