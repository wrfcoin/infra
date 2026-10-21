terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 2.9"
    }
  }
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

provider "proxmox" {
  pm_api_url      = var.proxmox_api_url
  pm_user         = var.proxmox_user
  pm_password     = var.proxmox_password
  pm_tls_insecure = true  # Set to false and supply pm_tls_insecure=false + a CA cert in production
}

# ---------------------------------------------------------------------------
# LXC container — autoresearch
# ---------------------------------------------------------------------------

resource "proxmox_lxc" "autoresearch" {
  target_node  = var.target_node
  vmid         = var.ct_id
  hostname     = "autoresearch"
  ostemplate   = var.ostemplate
  memory       = var.memory
  cores        = var.cores
  unprivileged = true
  start        = true
  onboot       = true

  rootfs {
    storage = "local-lvm"
    size    = "20G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "dhcp"
  }
}

# ---------------------------------------------------------------------------
# Provisioner — install Docker + start compose services via SSH
# Runs after the LXC container starts (triggers on container create/replace).
# ---------------------------------------------------------------------------

resource "null_resource" "autoresearch_provision" {
  depends_on = [proxmox_lxc.autoresearch]

  # Re-run if the container or compose file changes
  triggers = {
    container_id   = proxmox_lxc.autoresearch.id
    compose_sha256 = sha256(join("", [
      filesha256("${path.module}/docker-compose.autoresearch.yml"),
      filesha256("${path.module}/docker-compose.autoresearch.rocm.yml"),
    ]))
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
  }

  # Copy the provision script and compose files, then run them
  provisioner "file" {
    source      = "${path.module}/docker-compose.autoresearch.yml"
    destination = "/opt/autoresearch/docker-compose.yml"
  }

  provisioner "file" {
    source      = "${path.module}/docker-compose.autoresearch.rocm.yml"
    destination = "/opt/autoresearch/docker-compose.rocm.yml"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p /opt/autoresearch",
      # Install Docker if not already present
      "command -v docker >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y ca-certificates curl && install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc && . /etc/os-release && echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable\" > /etc/apt/sources.list.d/docker.list && apt-get update -qq && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin)",
      # Start services
      "cd /opt/autoresearch && docker compose up -d",
      "echo 'autoresearch provisioning complete'",
    ]
  }
}
