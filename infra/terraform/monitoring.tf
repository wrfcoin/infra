# Comprehensive Monitoring and Alerting for Wrfcoin
# Implements production-grade observability with 99.9% uptime monitoring

# Prometheus and Grafana deployment
resource "kubernetes_namespace" "monitoring" {
  depends_on = [module.eks]
  
  metadata {
    name = "monitoring"
    
    labels = {
      name        = "monitoring"
      environment = var.environment
      purpose     = "observability"
    }
  }
}

# Prometheus Operator via Helm
resource "helm_release" "prometheus_operator" {
  depends_on = [kubernetes_namespace.monitoring]
  
  name       = "prometheus-operator"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "51.2.0"

  values = [
    file("${path.module}/../monitoring/prometheus-values.yaml")
  ]

  set {
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "30d"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "100Gi"
  }

  set {
    name  = "alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage"
    value = "10Gi"
  }
}

resource "random_password" "grafana_admin" {
  length  = 16
  special = true
}

# Custom ServiceMonitors for Wrfcoin services
resource "kubernetes_manifest" "wrfcoin_service_monitor" {
  depends_on = [helm_release.prometheus_operator]
  
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "wrfcoin-services"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels = {
        app = "wrfcoin"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          app = "wrfcoin-api"
        }
      }
      namespaceSelector = {
        matchNames = ["default"]
      }
      endpoints = [
        {
          port     = "metrics"
          interval = "30s"
          path     = "/metrics"
        }
      ]
    }
  }
}

# Blockchain-specific monitoring
resource "kubernetes_manifest" "blockchain_service_monitor" {
  depends_on = [helm_release.prometheus_operator]
  
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "blockchain-nodes"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels = {
        app = "blockchain"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          component = "blockchain"
        }
      }
      namespaceSelector = {
        matchNames = ["default"]
      }
      endpoints = [
        {
          port     = "metrics"
          interval = "15s"
          path     = "/metrics"
        }
      ]
    }
  }
}

# Custom PrometheusRules for Wrfcoin alerting
resource "kubernetes_manifest" "wrfcoin_prometheus_rules" {
  depends_on = [helm_release.prometheus_operator]
  
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "wrfcoin-alerts"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels = {
        app  = "wrfcoin"
        role = "alert-rules"
      }
    }
    spec = {
      groups = [
        {
          name = "wrfcoin.blockchain"
          rules = [
            {
              alert = "BlockchainNodeDown"
              expr  = "up{job=\"blockchain-nodes\"} == 0"
              for   = "1m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary     = "Blockchain node is down"
                description = "Blockchain node {{ $labels.instance }} has been down for more than 1 minute."
              }
            },
            {
              alert = "BlockProductionSlow"
              expr  = "rate(blocks_produced_total[5m]) < 0.1"
              for   = "2m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Block production is slow"
                description = "Block production rate is {{ $value }} blocks/second, below expected threshold."
              }
            },
            {
              alert = "HighTransactionPoolSize"
              expr  = "transaction_pool_size > 10000"
              for   = "5m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "High transaction pool size"
                description = "Transaction pool size is {{ $value }}, indicating potential congestion."
              }
            }
          ]
        },
        {
          name = "wrfcoin.weather"
          rules = [
            {
              alert = "WeatherDataIngestionFailure"
              expr  = "rate(weather_data_errors_total[5m]) > 0.1"
              for   = "3m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Weather data ingestion failures"
                description = "Weather data ingestion error rate is {{ $value }} errors/second."
              }
            },
            {
              alert = "WeatherDataStaleness"
              expr  = "time() - weather_data_last_update_timestamp > 1800"
              for   = "0m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary     = "Weather data is stale"
                description = "Weather data hasn't been updated for {{ $value }} seconds."
              }
            }
          ]
        },
        {
          name = "wrfcoin.cross_chain"
          rules = [
            {
              alert = "CrossChainBridgeFailure"
              expr  = "rate(bridge_transaction_failures_total[5m]) > 0.05"
              for   = "2m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary     = "Cross-chain bridge failures"
                description = "Bridge {{ $labels.bridge }} failure rate is {{ $value }} failures/second."
              }
            },
            {
              alert = "BridgeLiquidityLow"
              expr  = "bridge_liquidity_ratio < 0.2"
              for   = "5m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Low bridge liquidity"
                description = "Bridge {{ $labels.bridge }} liquidity ratio is {{ $value }}."
              }
            }
          ]
        },
        {
          name = "wrfcoin.infrastructure"
          rules = [
            {
              alert = "HighCPUUsage"
              expr  = "100 - (avg by(instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 85"
              for   = "5m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "High CPU usage"
                description = "CPU usage on {{ $labels.instance }} is {{ $value }}%."
              }
            },
            {
              alert = "HighMemoryUsage"
              expr  = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90"
              for   = "5m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary     = "High memory usage"
                description = "Memory usage on {{ $labels.instance }} is {{ $value }}%."
              }
            },
            {
              alert = "DiskSpaceLow"
              expr  = "(1 - (node_filesystem_avail_bytes / node_filesystem_size_bytes)) * 100 > 85"
              for   = "5m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Low disk space"
                description = "Disk usage on {{ $labels.instance }} is {{ $value }}%."
              }
            }
          ]
        }
      ]
    }
  }
}

# Jaeger for distributed tracing
resource "kubernetes_namespace" "tracing" {
  depends_on = [module.eks]
  
  metadata {
    name = "tracing"
    
    labels = {
      name        = "tracing"
      environment = var.environment
      purpose     = "observability"
    }
  }
}

resource "helm_release" "jaeger" {
  depends_on = [kubernetes_namespace.tracing]
  
  name       = "jaeger"
  repository = "https://jaegertracing.github.io/helm-charts"
  chart      = "jaeger"
  namespace  = kubernetes_namespace.tracing.metadata[0].name
  version    = "0.71.2"

  values = [
    yamlencode({
      provisionDataStore = {
        cassandra = false
        elasticsearch = true
      }
      elasticsearch = {
        deploy = true
        replicas = 2
        minimumMasterNodes = 1
        resources = {
          requests = {
            cpu    = "500m"
            memory = "1Gi"
          }
          limits = {
            cpu    = "1000m"
            memory = "2Gi"
          }
        }
      }
      collector = {
        resources = {
          requests = {
            cpu    = "200m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      query = {
        resources = {
          requests = {
            cpu    = "200m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
    })
  ]
}

# Fluentd for log aggregation
resource "kubernetes_namespace" "logging" {
  depends_on = [module.eks]
  
  metadata {
    name = "logging"
    
    labels = {
      name        = "logging"
      environment = var.environment
      purpose     = "observability"
    }
  }
}

resource "helm_release" "fluentd" {
  depends_on = [kubernetes_namespace.logging]
  
  name       = "fluentd"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluentd"
  namespace  = kubernetes_namespace.logging.metadata[0].name
  version    = "0.3.9"

  values = [
    yamlencode({
      image = {
        repository = "fluent/fluentd-kubernetes-daemonset"
        tag        = "v1.16-debian-elasticsearch7-1"
      }
      env = [
        {
          name  = "FLUENT_ELASTICSEARCH_HOST"
          value = "elasticsearch.logging.svc.cluster.local"
        },
        {
          name  = "FLUENT_ELASTICSEARCH_PORT"
          value = "9200"
        }
      ]
      resources = {
        requests = {
          cpu    = "100m"
          memory = "200Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "500Mi"
        }
      }
    })
  ]
}

# Elasticsearch for log storage
resource "helm_release" "elasticsearch" {
  depends_on = [kubernetes_namespace.logging]
  
  name       = "elasticsearch"
  repository = "https://helm.elastic.co"
  chart      = "elasticsearch"
  namespace  = kubernetes_namespace.logging.metadata[0].name
  version    = "7.17.3"

  values = [
    yamlencode({
      replicas = 2
      minimumMasterNodes = 1
      
      resources = {
        requests = {
          cpu    = "500m"
          memory = "2Gi"
        }
        limits = {
          cpu    = "1000m"
          memory = "4Gi"
        }
      }
      
      volumeClaimTemplate = {
        storageClassName = "gp3"
        resources = {
          requests = {
            storage = "50Gi"
          }
        }
      }
      
      esConfig = {
        "elasticsearch.yml" = "xpack.security.enabled: false\n"
      }
    })
  ]
}

# CloudWatch integration for AWS native monitoring
resource "aws_cloudwatch_dashboard" "wrfcoin_overview" {
  dashboard_name = "${local.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/EKS", "cluster_failed_request_count", "ClusterName", module.eks.cluster_name],
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "EKS and Load Balancer Metrics"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", module.database.db_instance_identifier],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", module.database.db_instance_identifier],
            ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", module.database.db_instance_identifier]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Database Performance"
        }
      }
    ]
  })
}

# Custom metrics for blockchain monitoring
resource "aws_cloudwatch_metric_alarm" "blockchain_consensus_failure" {
  alarm_name          = "${local.name_prefix}-consensus-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ConsensusFailures"
  namespace           = "Wrfcoin/Blockchain"
  period              = "300"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Blockchain consensus failures detected"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  treat_missing_data = "notBreaching"

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "weather_data_staleness" {
  alarm_name          = "${local.name_prefix}-weather-data-stale"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "WeatherDataAge"
  namespace           = "Wrfcoin/Weather"
  period              = "300"
  statistic           = "Maximum"
  threshold           = "1800"  # 30 minutes
  alarm_description   = "Weather data is becoming stale"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  treat_missing_data = "breaching"

  tags = local.common_tags
}

# SNS topic subscription for email alerts
resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Store monitoring secrets in AWS Secrets Manager
resource "aws_secretsmanager_secret" "monitoring_credentials" {
  name        = "${local.name_prefix}-monitoring-credentials"
  description = "Monitoring system credentials"

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "monitoring_credentials" {
  secret_id = aws_secretsmanager_secret.monitoring_credentials.id
  secret_string = jsonencode({
    grafana_admin_password = random_password.grafana_admin.result
    prometheus_endpoint    = "http://prometheus-operator-kube-p-prometheus.monitoring.svc.cluster.local:9090"
    grafana_endpoint      = "http://prometheus-operator-grafana.monitoring.svc.cluster.local"
    jaeger_endpoint       = "http://jaeger-query.tracing.svc.cluster.local:16686"
  })
}

# Output monitoring endpoints
output "monitoring_endpoints" {
  description = "Monitoring system endpoints"
  value = {
    grafana_admin_password = random_password.grafana_admin.result
    cloudwatch_dashboard   = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${local.name_prefix}-overview"
    sns_topic_arn         = aws_sns_topic.alerts.arn
  }
  sensitive = true
}