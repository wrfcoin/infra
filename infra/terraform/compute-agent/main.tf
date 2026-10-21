# Compute-Agent EKS Deployment Module
# Deploys the WRFCoin compute-agent to EKS with IRSA, autoscaling, and monitoring.
# References: infra#36, core4 Dockerfile non-root pattern (UID 1001)

locals {
  name      = "wrfcoin-compute-agent"
  component = "compute-agent"
  labels = {
    "app.kubernetes.io/name"      = local.name
    "app.kubernetes.io/component" = local.component
    "app.kubernetes.io/part-of"   = "wrfcoin"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# ---------------------------------------------------------------------------
# IAM — IRSA (IAM Roles for Service Accounts)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${local.name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "compute_agent" {
  name               = "wrfcoin-${var.environment}-compute-agent"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(var.tags, {
    Component = local.component
  })
}

data "aws_iam_policy_document" "permissions" {
  # CloudWatch Logs for observability
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws/eks/*/compute-agent:*"]
  }

  # ECR pull for container images
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "compute_agent" {
  name   = "wrfcoin-compute-agent-policy"
  role   = aws_iam_role.compute_agent.id
  policy = data.aws_iam_policy_document.permissions.json
}

# ---------------------------------------------------------------------------
# Kubernetes — Namespace, ServiceAccount, ConfigMap
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "compute_agent" {
  metadata {
    name = var.namespace

    labels = merge(local.labels, {
      name        = var.namespace
      environment = var.environment
    })
  }
}

resource "kubernetes_service_account" "compute_agent" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.compute_agent.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.compute_agent.arn
    }

    labels = local.labels
  }
}

resource "kubernetes_config_map" "compute_agent" {
  metadata {
    name      = "${local.name}-config"
    namespace = kubernetes_namespace.compute_agent.metadata[0].name
    labels    = local.labels
  }

  data = {
    TASK_API_URL          = var.task_api_url
    POLL_INTERVAL_MS      = "10000"
    HEARTBEAT_INTERVAL_MS = "30000"
    HEALTH_PORT           = "3333"
  }
}

# ---------------------------------------------------------------------------
# Kubernetes — Deployment
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "compute_agent" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.compute_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.name
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    template {
      metadata {
        labels = local.labels

        annotations = {
          "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
        }
      }

      spec {
        service_account_name             = kubernetes_service_account.compute_agent.metadata[0].name
        termination_grace_period_seconds = 120

        security_context {
          run_as_non_root = true
          run_as_user     = var.run_as_user
          run_as_group    = var.run_as_user
          fs_group        = var.run_as_user

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Conditional node affinity for dedicated compute-agent node group
        dynamic "toleration" {
          for_each = var.enable_node_affinity ? [1] : []
          content {
            key      = "dedicated"
            value    = "compute-agent"
            effect   = "NoSchedule"
            operator = "Equal"
          }
        }

        dynamic "affinity" {
          for_each = var.enable_node_affinity ? [1] : []
          content {
            node_affinity {
              required_during_scheduling_ignored_during_execution {
                node_selector_term {
                  match_expressions {
                    key      = "workload"
                    operator = "In"
                    values   = ["compute-agent"]
                  }
                }
              }
            }
          }
        }

        container {
          name              = local.component
          image             = var.image
          image_pull_policy = "IfNotPresent"

          env_from {
            config_map_ref {
              name = kubernetes_config_map.compute_agent.metadata[0].name
            }
          }

          env {
            name = "WALLET_ADDRESS"
            value_from {
              secret_key_ref {
                name = "${local.name}-secrets"
                key  = "wallet-address"
              }
            }
          }

          port {
            name           = "health"
            container_port = 3333
            protocol       = "TCP"
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true

            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          startup_probe {
            http_get {
              path = "/health"
              port = "health"
            }
            failure_threshold = 12
            period_seconds    = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "health"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "health"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Kubernetes — Service
# ---------------------------------------------------------------------------

resource "kubernetes_service" "compute_agent" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.compute_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = local.name
    }

    port {
      name        = "health"
      port        = 3333
      target_port = "health"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

# ---------------------------------------------------------------------------
# Kubernetes — HPA (Horizontal Pod Autoscaler)
# ---------------------------------------------------------------------------

resource "kubernetes_horizontal_pod_autoscaler_v2" "compute_agent" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.compute_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    min_replicas = 1
    max_replicas = 5

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.compute_agent.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }

    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 60
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 60
        }
        policy {
          type           = "Pods"
          value          = 2
          period_seconds = 60
        }
        select_policy = "Max"
      }

      scale_down {
        stabilization_window_seconds = 900
        policy {
          type           = "Percent"
          value          = 25
          period_seconds = 300
        }
        policy {
          type           = "Pods"
          value          = 1
          period_seconds = 300
        }
        select_policy = "Min"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Kubernetes — PodDisruptionBudget
# ---------------------------------------------------------------------------

resource "kubernetes_pod_disruption_budget_v1" "compute_agent" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace.compute_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    min_available = "1"

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.name
      }
    }
  }
}
