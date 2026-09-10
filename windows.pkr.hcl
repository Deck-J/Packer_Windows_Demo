packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

variable "project_id" {
  type = string
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "builder_service_account" {
  type = string
}

variable "winrm_password" {
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  type      = string
  sensitive = true
}

variable "ssh_private_key_file" {
  type      = string
  sensitive = true
}

variable "image_family" {
  type    = string
  default = "windows-2022"
}

source "googlecompute" "windows_2022" {
  project_id              = var.project_id
  zone                    = var.zone
  source_image_family     = var.image_family
  source_image_project_id = ["windows-cloud"]

  image_name        = "windows-server-2022-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  image_family      = "windows-server-2022-golden"
  image_description = "Windows Server 2022 build runner image"

  network    = var.network
  subnetwork = var.subnetwork
  tags       = ["packer-windows-builder"]

  service_account_email = var.builder_service_account
  use_iap               = true

  winrm_username = "packer"
  winrm_password = var.winrm_password
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_port     = 5986

  disk_size = 80
  disk_type = "pd-balanced"
  shutdown_timeout = "10m"

  metadata = {
    windows-startup-script-ps1 = templatefile("scripts/install-openssh.ps1.tftpl", {
      ssh_public_key = var.ssh_public_key
    })
  }
}

source "googlecompute" "windows_2022_ssh" {
  project_id              = var.project_id
  zone                    = var.zone
  source_image_family     = var.image_family
  source_image_project_id = ["windows-cloud"]

  image_name        = "windows-server-2022-ssh-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  image_family      = "windows-server-2022-ssh-golden"
  image_description = "Windows Server 2022 build runner image provisioned over SSH"

  network    = var.network
  subnetwork = var.subnetwork
  tags       = ["packer-windows-builder"]

  service_account_email = var.builder_service_account
  use_iap               = true

  ssh_username          = "packer"
  ssh_private_key_file  = var.ssh_private_key_file
  ssh_port              = 22
  ssh_timeout           = "15m"

  metadata = {
    windows-startup-script-ps1 = templatefile("scripts/install-openssh.ps1.tftpl", {
      ssh_public_key = var.ssh_public_key
    })
  }

  disk_size       = 80
  disk_type       = "pd-balanced"
  shutdown_timeout = "10m"
}

build {
  name    = "windows-server-2022"
  sources = [
    "source.googlecompute.windows_2022",
    "source.googlecompute.windows_2022_ssh",
  ]

  post-processor "manifest" {
    output = "packer-manifest.json"
  }

  provisioner "powershell" {
    script = "scripts/provision-windows.ps1"
  }

  provisioner "windows-restart" {
    restart_check_command = "powershell -command \"Write-Output 'ready'\""
  }

  provisioner "powershell" {
    script = "scripts/self-test-windows.ps1"
  }
}
