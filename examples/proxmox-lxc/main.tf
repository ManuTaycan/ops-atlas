# Sanitized reconstruction of the successful single-container case.
# Read README.md before using this against an existing container or state.
# Credentials and the API endpoint come from PROXMOX_VE_* environment variables.
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.120.0"
    }
  }
}

provider "proxmox" {}

variable "node_name" {
  description = "Existing Proxmox node. Use the exact, case-sensitive name."
  type        = string
}

variable "container_id" {
  description = "Cluster-unique ID. For adoption, use the existing managed ID."
  type        = number

  validation {
    condition     = var.container_id >= 100 && var.container_id <= 999999999 && floor(var.container_id) == var.container_id
    error_message = "Use an integer container ID between 100 and 999999999."
  }
}

variable "hostname" {
  description = "Hostname assigned inside the container."
  type        = string
}

variable "bridge" {
  description = "Existing bridge on node_name; it must also be allowed by the token ACL."
  type        = string
}

variable "datastore_id" {
  description = "Existing datastore supporting container root filesystems."
  type        = string
}

variable "template_file_id" {
  description = "Exact downloaded Debian template volume ID, including storage:vztmpl/filename."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the PUBLIC .pub key on the machine running tofu. Never pass the private key."
  type        = string
}

resource "proxmox_virtual_environment_container" "nginx" {
  node_name = var.node_name
  vm_id     = var.container_id

  description   = "Homelab IaC - Nginx Test"
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 256
  }

  # Retained from the successful case after its systemd warning.
  # Review the isolation implications; this is not a Docker installation.
  features {
    nesting = true
  }

  disk {
    datastore_id = var.datastore_id
    size         = 8
  }

  network_interface {
    name   = "eth0"
    bridge = var.bridge
  }

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      keys = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian"
  }
}

output "container_id" {
  description = "Managed container ID; not evidence of guest networking or Nginx health."
  value       = proxmox_virtual_environment_container.nginx.vm_id
}
