# Auto-Collectors

This directory contains "set it and forget it" auto-collector scripts that continuously earn WRF
tokens by contributing various resources to the network.

## Available Collectors

### Weather Data Collectors

- `acurite-working-collector.js` - Basic authenticated AcuRite weather station collector
- `acurite-enhanced-collector.js` - Enhanced collector with IPFS and data-aware blocks
- `acurite-auto-collector.js` - Fully automated multi-source weather collection

### Compute Collectors

- `compute-auto-collector.js` - One-click computational power contribution

### Storage Collectors

- `nas-auto-collector.js` - Automatic NAS device discovery and storage contribution

## Usage

Each collector can be run independently:

```bash
node scripts/collectors/acurite-working-collector.js
node scripts/collectors/compute-auto-collector.js
node scripts/collectors/nas-auto-collector.js
```

All collectors follow the "weather station model" - simple setup with continuous automated earning.
