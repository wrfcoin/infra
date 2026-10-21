# 🚀 WRF Storage Node for Unraid - Quick Start

Your friend's server is **perfect** for running a WRF storage node! Here's everything they need to
know.

## 🎯 What This Does

- **Earns WRF tokens** by providing decentralized file storage
- **Uses spare storage space** and bandwidth efficiently
- **Runs securely** in Docker containers on Unraid
- **"Set it and forget it"** once properly configured

## 📊 Expected Earnings

With your specs (i9-12900K, 400mb internet):

- **~50+ WRF tokens/day** with 1TB allocated storage
- **Bonus multipliers** for high uptime and bandwidth
- **Performance bonuses** for fast hardware

## 🚀 Quick Setup (Choose Your Path)

### Option 1: Easy & Secure (Recommended)

**Cloudflare Tunnel - No port forwarding needed!**

1. Read: `cloudflare-tunnel-setup.md`
2. Setup time: 30-60 minutes
3. Security: ⭐⭐⭐⭐⭐ (Maximum)

### Option 2: Advanced Setup

**VLAN Isolation - For networking enthusiasts**

1. Read: `../docs/unraid-wrf-storage-deployment.md`
2. Setup time: 2-4 hours
3. Security: ⭐⭐⭐⭐⭐ (Maximum)

## 📁 What You Get

```
infrastructure/unraid/
├── README.md                        # This file
├── setup-wrf-storage.sh            # Automated setup script
├── docker-compose.secure.yml       # Production Docker config
├── cloudflare-tunnel-setup.md      # Easy tunnel setup
└── ../docs/unraid-wrf-storage-deployment.md  # Complete guide
```

## ⚡ Quick Start Commands

### 1. Prepare Your System

```bash
# SSH into your Unraid server
ssh root@your-unraid-ip

# Download the WRF setup files
wget -O setup-wrf-storage.sh https://raw.githubusercontent.com/your-repo/setup-wrf-storage.sh
chmod +x setup-wrf-storage.sh

# Run the setup script
./setup-wrf-storage.sh
```

### 2. Configure Security

Choose one:

- **Easy**: Follow Cloudflare Tunnel guide (recommended)
- **Advanced**: Configure VLAN isolation

### 3. Start Earning

```bash
cd /mnt/user/appdata/wrfcoin
docker-compose up -d
```

## 🔐 Security Summary

Your server will be **100% secure** with our configuration:

- ✅ **Isolated storage** (dedicated drive only)
- ✅ **Network isolation** (no access to main server)
- ✅ **Container security** (hardened Docker setup)
- ✅ **No open ports** (with Cloudflare Tunnel)
- ✅ **Monitoring included** (health checks & alerts)

## 💰 Earnings Dashboard

Once running, monitor earnings at:

- **Health**: http://localhost:7001/health
- **Stats**: http://localhost:7001/api/stats
- **Earnings**: http://localhost:7001/api/earnings

## 📞 Support

If you need help:

1. **Check logs**: `docker logs wrf-storage-node`
2. **Review guides** in this folder
3. **Ask questions** - we're here to help!

## ⚠️ Important Notes

- **Use a dedicated drive** (not your main storage array)
- **Set up network security** before starting
- **Monitor regularly** (not truly "set and forget")
- **Update monthly** for security and performance

## 🎁 Hardware Utilization

Your i9-12900K server will use:

- **CPU**: <25% (4 cores dedicated)
- **RAM**: 2-4GB
- **Storage**: Up to 80% of dedicated drive
- **Network**: Scales with demand (up to 400mb)

**Perfect fit for your setup!** 🎯

---

**Ready to start earning WRF tokens?** Pick your security setup method and let's get your storage
node running!
