# WRF Storage Node - Cloudflare Tunnel Setup (Easiest & Most Secure)

## 🚀 Why Cloudflare Tunnel?

Cloudflare Tunnel is the **easiest and most secure** way to expose your WRF storage node:

- ✅ **No open ports** on your router/firewall
- ✅ **Zero Trust security** by default
- ✅ **Built-in DDoS protection**
- ✅ **Simple configuration**
- ✅ **Free Cloudflare account sufficient**

## 📋 Prerequisites

1. **Free Cloudflare Account**: Sign up at https://cloudflare.com
2. **Domain Name**: Any domain (can be free from Freenom, etc.)
3. **Domain on Cloudflare**: Add your domain to Cloudflare DNS

## 🔧 Setup Steps

### Step 1: Install Cloudflared on Unraid

#### Option A: Docker Container (Recommended)

Add this service to your docker-compose.yml:

```yaml
cloudflared:
  image: cloudflare/cloudflared:latest
  container_name: wrf-cloudflared
  restart: unless-stopped

  # Security
  user: '65534:65534' # nobody
  read_only: true
  security_opt:
    - no-new-privileges:true

  # Resource limits
  mem_limit: 256m
  cpus: 0.5

  # Configuration
  volumes:
    - /mnt/user/appdata/wrfcoin/cloudflared:/etc/cloudflared:ro

  # Command - will be configured after tunnel creation
  command: ['tunnel', '--no-autoupdate', 'run', '--token', '${CLOUDFLARE_TUNNEL_TOKEN}']

  # Network
  networks:
    - wrf-isolated-network

  # Labels
  labels:
    - 'com.wrfcoin.service=cloudflare-tunnel'
    - 'com.wrfcoin.description=Secure tunnel for WRF storage access'
```

#### Option B: Direct Installation

```bash
# Download cloudflared
wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /usr/local/bin/cloudflared
```

### Step 2: Create Cloudflare Tunnel

#### Via Cloudflare Dashboard (Easiest):

1. Go to **Cloudflare Dashboard** → **Zero Trust** → **Networks** → **Tunnels**
2. Click **Create a tunnel**
3. Choose **Cloudflared**
4. Name your tunnel: `wrf-storage-node`
5. **Save the tunnel token** (you'll need this)

#### Via CLI (Advanced):

```bash
# Login to Cloudflare
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create wrf-storage-node

# Get tunnel info
cloudflared tunnel list
```

### Step 3: Configure Tunnel Routing

#### In Cloudflare Dashboard:

1. In your tunnel configuration, add **Public Hostname**:

   - **Subdomain**: `wrf-storage`
   - **Domain**: `yourdomain.com`
   - **Service Type**: `HTTP`
   - **URL**: `localhost:7001`

2. Add second hostname for storage port:
   - **Subdomain**: `wrf-storage-api`
   - **Domain**: `yourdomain.com`
   - **Service Type**: `HTTP`
   - **URL**: `localhost:7002`

#### Via Configuration File:

Create `/mnt/user/appdata/wrfcoin/cloudflared/config.yml`:

```yaml
tunnel: wrf-storage-node
credentials-file: /etc/cloudflared/credentials.json

ingress:
  # Main WRF storage API
  - hostname: wrf-storage.yourdomain.com
    service: http://wrf-storage-node:7001
    originRequest:
      httpHostHeader: localhost

  # Storage validation API
  - hostname: wrf-storage-api.yourdomain.com
    service: http://wrf-storage-node:7002
    originRequest:
      httpHostHeader: localhost

  # Health check endpoint
  - hostname: wrf-health.yourdomain.com
    service: http://wrf-storage-node:7001
    path: /health

  # Catch-all (required)
  - service: http_status:404
```

### Step 4: Environment Configuration

Add to your `.env` file:

```bash
# Cloudflare Tunnel Configuration
CLOUDFLARE_TUNNEL_TOKEN=your_tunnel_token_here
CLOUDFLARE_TUNNEL_NAME=wrf-storage-node

# Public URLs (replace with your domain)
WRF_PUBLIC_URL=https://wrf-storage.yourdomain.com
WRF_API_URL=https://wrf-storage-api.yourdomain.com
WRF_HEALTH_URL=https://wrf-health.yourdomain.com

# Tunnel-specific settings
ENABLE_PUBLIC_ACCESS=true
TUNNEL_METRICS_PORT=8080
```

### Step 5: Update WRF Storage Configuration

Modify your WRF storage container to work with tunnels:

```yaml
wrf-storage-node:
  # ... existing configuration ...

  environment:
    # ... existing environment ...

    # Tunnel configuration
    - PUBLIC_URL=${WRF_PUBLIC_URL}
    - API_URL=${WRF_API_URL}
    - BEHIND_PROXY=true
    - TRUST_PROXY=true

    # Security for public access
    - ENABLE_RATE_LIMITING=true
    - MAX_REQUEST_SIZE=10MB
    - REQUIRE_API_KEY=false # Set to true for additional security

  # Don't expose ports to host (tunnel handles this)
  expose:
    - '7001'
    - '7002'
  # Remove 'ports:' section when using tunnel
```

### Step 6: Start Everything

1. **Start the stack**:

   ```bash
   cd /mnt/user/appdata/wrfcoin
   docker-compose up -d
   ```

2. **Check tunnel status**:

   ```bash
   docker logs wrf-cloudflared
   ```

3. **Test public access**:
   ```bash
   curl https://wrf-health.yourdomain.com/health
   ```

## 🔒 Security Features

### Built-in Security:

- **No inbound ports** on your router
- **Encrypted tunnel** (TLS 1.3)
- **DDoS protection** by Cloudflare
- **IP geoblocking** available
- **Rate limiting** built-in

### Optional Enhancements:

#### Enable Access Policies:

1. Go to **Zero Trust** → **Access** → **Applications**
2. Add application for your WRF storage
3. Set policies (IP restrictions, country blocking, etc.)

#### API Key Protection:

```bash
# In your .env file
WRF_API_KEY=your_secure_random_api_key_here

# In requests to your storage node
curl -H "X-API-Key: your_secure_random_api_key_here" https://wrf-storage.yourdomain.com/api/stats
```

## 📊 Monitoring & Maintenance

### Tunnel Health Monitoring:

```bash
# Check tunnel status
docker exec wrf-cloudflared cloudflared tunnel info wrf-storage-node

# View tunnel metrics
curl http://localhost:8080/metrics  # If metrics enabled
```

### Log Analysis:

```bash
# Cloudflare tunnel logs
docker logs wrf-cloudflared

# Storage node logs
docker logs wrf-storage-node

# Combined logging
docker-compose logs -f
```

### Automatic Updates:

Add to your update script:

```bash
# Update cloudflared
docker pull cloudflare/cloudflared:latest
docker-compose up -d cloudflared
```

## 🚨 Security Best Practices

### ✅ Do:

- Use strong, unique domain names
- Enable Cloudflare security features
- Monitor tunnel logs regularly
- Keep cloudflared updated
- Use API keys for additional security

### ❌ Don't:

- Use obvious subdomain names
- Disable Cloudflare proxy (orange cloud)
- Ignore security warnings
- Share tunnel tokens
- Run tunnel as root

## 🛠️ Troubleshooting

### Common Issues:

#### Tunnel Won't Connect:

```bash
# Check token validity
docker exec wrf-cloudflared cloudflared tunnel token validate

# Restart tunnel
docker-compose restart cloudflared
```

#### DNS Issues:

- Ensure domain is on Cloudflare DNS
- Check subdomain CNAME records
- Verify orange cloud is enabled

#### Performance Issues:

- Check Cloudflare datacenter location
- Monitor tunnel metrics
- Verify network bandwidth

### Advanced Configuration:

#### Custom Headers:

```yaml
ingress:
  - hostname: wrf-storage.yourdomain.com
    service: http://wrf-storage-node:7001
    originRequest:
      httpHostHeader: localhost
      headers:
        X-Forwarded-Proto: https
        X-Real-IP: ''
```

## 🎯 Benefits Summary

| Feature             | Cloudflare Tunnel    | Traditional VPN/Port Forward |
| ------------------- | -------------------- | ---------------------------- |
| Setup Difficulty    | ⭐⭐☆☆☆ Easy         | ⭐⭐⭐⭐⭐ Complex           |
| Security            | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐☆☆ Moderate            |
| DDoS Protection     | ✅ Built-in          | ❌ Additional setup needed   |
| No Port Forwarding  | ✅ Zero ports open   | ❌ Requires open ports       |
| Free Tier Available | ✅ Generous limits   | ❌ Usually paid              |
| Maintenance         | ⭐⭐⭐⭐⭐ Minimal   | ⭐⭐☆☆☆ Regular updates      |

---

**💡 Recommendation**: Start with Cloudflare Tunnel for the easiest and most secure setup. You can
always migrate to a VLAN-based approach later if needed.

**⏱️ Setup Time**: 30-60 minutes for complete configuration including domain setup.
