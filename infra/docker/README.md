# Wrfcoin NAS Storage Docker Setup

Turn your Network Attached Storage devices into earning nodes using the same proven "set it and
forget it" model as your weather station.

## Quick Start

1. **Download the setup files**

   ```bash
   git clone <repository-url>
   cd docker/nas-storage
   ```

2. **Run the automated setup**

   ```bash
   ./setup.sh
   ```

3. **Access your dashboard**
   - Open Wrfcoin frontend at http://localhost:5000
   - Go to Settings > NAS Storage
   - Click "Discover NAS Devices"
   - Register discovered devices to start earning

## What This Does

The Docker containers will:

- Automatically discover NAS devices on your network
- Register compatible storage devices for rewards
- Participate in storage validation challenges
- Accumulate WRF tokens in your wallet automatically

## Supported Devices

- **Synology**: All DiskStation models
- **QNAP**: All TurboNAS models
- **Western Digital**: My Cloud series
- **TrueNAS**: SCALE and CORE
- **Generic NAS**: Any device with SMB/NFS sharing

## Configuration Options

### Environment Variables

- `WALLET_ADDRESS`: Your WRF wallet address
- `MAX_STORAGE_ALLOCATION`: Percentage of storage to allocate (50%, 80%, 90%)
- `AUTO_DISCOVERY`: Enable automatic device discovery (true/false)
- `AUTO_REGISTER`: Enable automatic device registration (true/false)
- `COLLECTION_INTERVAL`: How often to check for rewards (milliseconds)

### Manual Configuration

Create a `.env` file:

```bash
WALLET_ADDRESS=your_wallet_address_here
MAX_STORAGE_ALLOCATION=80%
AUTO_DISCOVERY=true
AUTO_REGISTER=true
COLLECTION_INTERVAL=120000
```

## Management Commands

### Start Services

```bash
docker-compose up -d
```

### Stop Services

```bash
docker-compose down
```

### View Logs

```bash
# Auto-collector logs (earnings activity)
docker-compose logs -f nas-auto-collector

# Storage server logs
docker-compose logs -f nas-storage-server
```

### Check Status

```bash
docker-compose ps
curl http://localhost:7001/health
```

## Earning Estimates

Based on your storage allocation:

| Storage Size | Est. Monthly Earnings |
| ------------ | --------------------- |
| 2TB          | 1.2 WRF               |
| 4TB          | 2.4 WRF               |
| 8TB          | 4.8 WRF               |
| 16TB         | 9.6 WRF               |

_Earnings depend on network demand and validation performance_

## Security Features

- Containers run as non-root user
- Network isolation via Docker bridge
- Read-only access to Docker socket
- Health checks and automatic restart
- Encrypted data transmission

## Troubleshooting

### No Devices Found

1. Ensure NAS devices are powered on
2. Check network connectivity
3. Verify devices are on same network
4. Try manual device registration in dashboard

### Low Earnings

1. Check storage allocation percentage
2. Verify devices are online and responding
3. Monitor validation challenge success rate
4. Ensure adequate bandwidth for data transfers

### Container Issues

```bash
# Check container status
docker-compose ps

# View detailed logs
docker-compose logs nas-storage-server

# Restart services
docker-compose restart
```

## Integration with Weather Stations

Your NAS storage earnings work alongside your existing weather station:

- Weather Station: Currently earning WRF tokens
- Storage Network: Additional earnings from unused storage
- Combined Dashboard: Unified view of all earnings
- Protected Weather Earnings: Weather collection cannot be accidentally stopped

## Advanced Options

### Custom Network Configuration

```yaml
# In docker-compose.yml
environment:
  - NETWORK_INTERFACE=eth1
  - DISCOVERY_TIMEOUT=30000
  - VALIDATION_RETRIES=3
```

### Resource Limits

```yaml
# In docker-compose.yml
deploy:
  resources:
    limits:
      memory: 1G
      cpus: '0.5'
```

## Support

- Dashboard: Settings > NAS Storage
- API Health: http://localhost:7001/health
- Logs: `docker-compose logs -f`
- Network Stats: http://localhost:7001/api/stats

Your storage devices will begin earning WRF tokens automatically once discovered and registered.
