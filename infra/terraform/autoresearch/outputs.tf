output "container_ip" {
  description = "IP address of the autoresearch LXC container (DHCP-assigned; available after provisioning)"
  value       = var.ssh_host
}

output "container_hostname" {
  description = "Hostname of the autoresearch LXC container"
  value       = proxmox_lxc.autoresearch.hostname
}

output "container_id" {
  description = "Proxmox VM/CT ID of the autoresearch container"
  value       = proxmox_lxc.autoresearch.vmid
}
