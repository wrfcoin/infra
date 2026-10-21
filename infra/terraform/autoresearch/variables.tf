variable "proxmox_api_url" {
  description = "Proxmox API URL (e.g. https://<proxmox-host>:8006/api2/json)"
  type        = string
}

variable "proxmox_user" {
  description = "Proxmox API user (e.g. root@pam)"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox API password"
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node name to deploy the LXC container on"
  type        = string
  default     = "pve"
}

variable "ct_id" {
  description = "Proxmox container ID for the autoresearch LXC"
  type        = number
  default     = 101
}

variable "memory" {
  description = "Memory (MB) allocated to the autoresearch container"
  type        = number
  default     = 2048
}

variable "cores" {
  description = "CPU cores allocated to the autoresearch container"
  type        = number
  default     = 2
}

variable "ostemplate" {
  description = "Proxmox LXC OS template to use"
  type        = string
  default     = "local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
}

variable "ssh_host" {
  description = "IP or hostname of the autoresearch container (after provisioning)"
  type        = string
}

variable "ssh_user" {
  description = "SSH user for the autoresearch container"
  type        = string
  default     = "root"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key used to connect to the autoresearch container"
  type        = string
}
