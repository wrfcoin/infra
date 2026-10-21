# WRFCoin Infrastructure Directory

This directory contains all infrastructure-related configurations and deployment scripts for the
WRFCoin platform.

## Directory Structure

```
infra/
├── deployment/          # Deployment scripts and configurations
│   ├── capacity-validation/     # Performance and scalability testing
│   ├── cross-chain-testing/     # Cross-chain bridge validation
│   ├── disaster-recovery/       # DR plans and automation
│   ├── enterprise-testing/      # Enterprise workload testing
│   ├── htlc-testing/           # Hash Time Lock Contract testing
│   ├── unraid/                 # Unraid-specific configurations
│   ├── advanced-deployment.sh  # Advanced deployment scripts
│   ├── deploy.sh              # Main deployment script
│   └── cloudflare-waf-config.json  # WAF configuration
├── docker/             # Docker configurations
│   ├── docker-compose.yml           # Main docker-compose file
│   ├── docker-compose.nas.yml       # NAS storage specific
│   ├── attic/                  # Historical, unbuildable Compose variants
│   ├── Dockerfile.*             # Service-specific Dockerfiles
│   ├── nginx.conf              # Nginx configuration
│   └── prometheus.yml          # Prometheus configuration
├── helm/               # Helm charts (to be populated)
├── k8s/                # Kubernetes manifests
│   ├── base/           # Base Kubernetes configurations
│   └── advanced/       # Advanced K8s features (Istio, etc.)
├── monitoring/         # Monitoring and observability
│   ├── grafana/        # Grafana dashboards and datasources
│   ├── docker-compose.monitoring.yml   # Monitoring stack
│   ├── prometheus-enhanced.yml         # Enhanced Prometheus config
│   ├── alertmanager.yml               # Alert management
│   └── setup-performance-monitoring.sh # Setup scripts
└── terraform/          # Infrastructure as Code
    ├── main.tf         # Main Terraform configuration
    ├── monitoring.tf   # Monitoring infrastructure
    └── multi-region.tf # Multi-region deployment
```

## Quick Start

### Docker Deployment

```bash
# Deploy main platform
cd infra/docker
docker-compose up -d

# Deploy with monitoring
docker-compose -f docker-compose.yml -f ../monitoring/docker-compose.monitoring.yml up -d

# Deploy NAS storage nodes
docker-compose -f docker-compose.nas.yml up -d
```

The former offline and microservices stacks are historical source in
the private Docker archive (not included in the public snapshot). Their missing local build inputs prevent
bring-up; do not use them as development quickstarts. The five retained variants
have an offline build-input inventory; external checkout contexts remain
unverified. Run `python3 scripts/check-legacy-compose-build-inputs.py` from the
repository root. This check does not establish runtime or build readiness.

### Kubernetes Deployment

> **NOT THE TESTNET DEPLOYMENT PATH.** The WRFCoin testnet is built locally and deployed from
> `testnet/` to the N5 Pro over SSH; images are never pushed to a registry. This section is
> reference material for other environments and is not used, tested or validated for the testnet.

```bash
# Deploy base services
kubectl apply -k infra/k8s/base/

# Deploy advanced features (Istio, etc.)
kubectl apply -k infra/k8s/advanced/
```

### Terraform Infrastructure

> **NOT THE TESTNET DEPLOYMENT PATH.** The WRFCoin testnet is built locally and deployed from
> `testnet/` to the N5 Pro over SSH; images are never pushed to a registry. This section is
> reference material for other environments and is not used, tested or validated for the testnet.

```bash
cd infra/terraform
terraform init
terraform plan
terraform apply
```

## Key Components

### Deployment Scripts

- `deployment/deploy.sh` - Main deployment orchestrator
- `deployment/advanced-deployment.sh` - Enterprise-grade deployment
- `deployment/capacity-validation/` - Performance testing suite
- `deployment/disaster-recovery/` - DR automation and testing

### Docker Services

- **Core Services**: Main blockchain, weather data, ML inference
- **Microservices**: NFT marketplace, user management, API gateway
- **Storage**: NAS integration, IPFS, distributed storage
- **Cross-Chain**: Bridge services and validators
- **Monitoring**: Prometheus, Grafana, Alertmanager

### Kubernetes Configurations

- **Base**: Essential services and databases
- **Advanced**: Service mesh, chaos engineering, canary deployments
- **Security**: Network policies, RBAC, security scanning

### Monitoring Stack

- **Grafana**: Comprehensive dashboards for all services
- **Prometheus**: Metrics collection and alerting
- **Jaeger/Tempo**: Distributed tracing
- **AlertManager**: Intelligent alerting and escalation

## Environment-Specific Configurations

### Development

```bash
# Quick dev setup
docker-compose -f infra/docker/docker-compose.yml up -d
```

### Staging

```bash
# Staging with monitoring
docker-compose -f infra/docker/docker-compose.yml -f infra/monitoring/docker-compose.monitoring.yml up -d
```

### Production

```bash
# Full production deployment
./infra/deployment/advanced-deployment.sh
```

## Security Considerations

- All configurations use least-privilege principles
- Secrets management via HashiCorp Vault integration
- Network isolation through Docker networks and K8s network policies
- Regular security scanning and compliance validation
- HSM integration for cryptographic operations

## Maintenance

### Backup Procedures

```bash
# Database backups
./infra/deployment/disaster-recovery/dr-automation.py backup

# Configuration backups
tar -czf infra-backup-$(date +%Y%m%d).tar.gz infra/
```

### Updates and Rollbacks

```bash
# Rolling updates
kubectl rollout restart deployment/wrfcoin-core

# Rollback
kubectl rollout undo deployment/wrfcoin-core
```

### Health Monitoring

```bash
# Check all services
./infra/deployment/capacity-validation/quick-validation-test.js

# Comprehensive health check
./infra/monitoring/setup-performance-monitoring.sh
```

## Troubleshooting

### Common Issues

1. **Port Conflicts**: Check `config/port-registry.json`
2. **Resource Limits**: Review Docker/K8s resource allocations
3. **Network Issues**: Validate Docker network configurations
4. **Storage Issues**: Check volume mounts and permissions

### Debug Commands

```bash
# Docker logs
docker-compose logs -f [service-name]

# Kubernetes logs
kubectl logs -f deployment/wrfcoin-core

# System metrics
curl http://localhost:9090/metrics
```

## Contributing

When adding new infrastructure:

1. Follow the directory structure conventions
2. Update this README with new components
3. Add appropriate monitoring and health checks
4. Include security configurations
5. Test in development environment first

## Support

For infrastructure issues:

- Check monitoring dashboards first
- Review logs using provided commands
- Consult disaster recovery procedures if needed
- Contact DevOps team for critical issues
