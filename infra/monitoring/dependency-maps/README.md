# WRFCoin Service Dependency Map

Generated on: 2025-07-22T06:04:22.834Z

## Overview

This directory contains comprehensive service dependency mapping for the WRFCoin platform, including
21 services across 18 tiers.

## Files

- **service-dependencies.dot**: Graphviz DOT format for visual graph generation
- **service-dependencies.mmd**: Mermaid diagram format for documentation
- **service-dependencies.json**: Complete JSON structure with metadata
- **prometheus-services.yml**: Prometheus configuration for monitoring

## Service Tiers

### Monitoring Infrastructure

- **Services**: prometheus
- **Count**: 1
- **Priority**: 0

### Blockchain Core

- **Services**: wrfcoin-core
- **Count**: 1
- **Priority**: 1

### Data Storage

- **Services**: postgresql
- **Count**: 1
- **Priority**: 1

### Caching Layer

- **Services**: redis-cache
- **Count**: 1
- **Priority**: 1

### API Services

- **Services**: wrfcoin-main-api
- **Count**: 1
- **Priority**: 2

### API Gateway

- **Services**: api-gateway
- **Count**: 1
- **Priority**: 3

### Cross-Chain Bridges

- **Services**: cross-chain-protocol
- **Count**: 1
- **Priority**: 2

### Data Processing

- **Services**: weather-service, etl-pipeline
- **Count**: 2
- **Priority**: 2

### Network Services

- **Services**: compute-networks, ai-ml-networks
- **Count**: 2
- **Priority**: 2

### Storage Services

- **Services**: storage-networks, nas-storage
- **Count**: 2
- **Priority**: 2

### Compute Services

- **Services**: ml-inference
- **Count**: 1
- **Priority**: 3

### Microservices

- **Services**: nft-service, user-service
- **Count**: 2
- **Priority**: 4

### IoT Networks

- **Services**: iot-sensor-networks
- **Count**: 1
- **Priority**: 1

### Service Discovery

- **Services**: node-discovery
- **Count**: 1
- **Priority**: 1

### Security Services

- **Services**: clamav-antivirus
- **Count**: 1
- **Priority**: 1

### Governance

- **Services**: governance-server
- **Count**: 1
- **Priority**: 3

### Reward Systems

- **Services**: weather-earnings
- **Count**: 1
- **Priority**: 4

### Runtime Metrics

- **Services**:
- **Count**: 0
- **Priority**: 5

## Critical Services

- **wrfcoin-core**: Core blockchain service with WVM
- **postgresql**: Primary database (21-table schema)
- **wrfcoin-main-api**: Main API server with GraphQL

## Generating Visuals

### Using Graphviz

```bash
dot -Tpng service-dependencies.dot -o service-dependencies.png
dot -Tsvg service-dependencies.dot -o service-dependencies.svg
```

### Using Mermaid CLI

```bash
mmdc -i service-dependencies.mmd -o service-dependencies.png
```

## Monitoring Integration

The generated Prometheus configuration can be integrated into your existing Prometheus setup:

```yaml
# Add to your prometheus.yml
include:
  - 'prometheus-services.yml'
```

## Health Endpoints

- **prometheus**: http://localhost:9090/metrics
- **wrfcoin-core**: http://localhost:5000/health
- **iot-sensor-networks**: http://localhost:3002/health
- **node-discovery**: http://localhost:9001/health
- **wrfcoin-main-api**: http://localhost:4001/health
- **cross-chain-protocol**: http://localhost:3000/health
- **weather-service**: http://localhost:3001/health
- **compute-networks**: http://localhost:6000/health
- **ai-ml-networks**: http://localhost:6001/health
- **storage-networks**: http://localhost:7000/health
- **api-gateway**: http://localhost:4000/health
- **ml-inference**: http://localhost:8080/health
- **etl-pipeline**: http://localhost:5000/health
- **governance-server**: http://localhost:8000/health
- **nas-storage**: http://localhost:7001/health
- **nft-service**: http://localhost:4002/health
- **user-service**: http://localhost:4003/health
- **weather-earnings**: http://localhost:8080/health
