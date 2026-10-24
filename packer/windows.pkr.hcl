# Packer: the Windows image the pipeline deploys.
#
# Run by Cloud Build (`cloudbuild/image.yaml`), which supplies the project, zone, service account and a
# per-build WinRM password. The image is the artefact every node boots from; the application package in
# GitHub Packages is what runs on it, and the baked copy exists only so a freshly built image can be
# smoke-tested on its own.
#
# Security shape:
#   * WinRM is reached over an **IAP tunnel** (`use_iap = true`), never over the internet. No firewall rule
#     opens 5985/5986/3389 to 0.0.0.0/0, and the builder gets its external IP only for egress.
#   * The WinRM password is a build-time variable (generated per build by Cloud Build), never committed.
#   * The builder's service account is `sa-winbuild-builder`, which can write objects and logs and nothing else.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
  }
}

variable "project_id" { type = string }
variable "zone" {
  type    = string
  default = "us-central1-a"
}
variable "network" {
  type    = string
  default = "wb-net"
}
variable "subnetwork" {
  type    = string
  default = "wb-subnet"
}
variable "service_account_email" { type = string }
variable "ssh_private_key_file" {
  type        = string
  sensitive   = true
  description = "Path to the ephemeral private key generated per build (never committed, never logged)"
}
variable "ssh_public_key" {
  type        = string
  sensitive   = true
  description = "The matching public key, injected through instance metadata"
}
variable "ssh_username" {
  type    = string
  default = "packer"
}
variable "image_version" {
  type        = string
  description = "e.g. 1.4.0-abc1234; becomes winbuild-app-<image_version>"
}
variable "source_url" {
  type        = string
  description = "gs:// URL of the source archive for this commit (empty = skip the baked smoke-test copy)"
  default     = ""
}
variable "custom_dir" {
  type        = string
  default     = "../custom"
  description = "Folder holding the build contract: run.ps1, build.config.json and any scripts it needs"
}
variable "debug_keep_vm" {
  type        = bool
  default     = false
  description = "Leave the build machine running, with an RDP account reachable only through IAP, for troubleshooting"
}
variable "debug_user" {
  type    = string
  default = "packer-debug"
}
variable "debug_password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "app_version" {
  type        = string
  description = "Assembly version baked into the smoke-test copy"
}
variable "vs_edition" {
  type        = string
  default     = "buildtools"
  description = "buildtools (default, licensed for agents) | community | professional | enterprise. Some project types only build with the full IDE."
}
variable "vs_workloads" {
  type        = string
  default     = ""
  description = "Comma-separated VS workload/component IDs. Empty = desktop C++/.NET build tools + Windows 11 SDK."
}
variable "vs_disable_out_of_proc_build" {
  type        = bool
  default     = false
  description = "Run DisableOutOfProcBuild.exe so devenv builds in-proc. Needed for .vdproj installer projects, SSDT/SSRS, VSTO/Office add-ins and some legacy project types. Requires the full IDE."
}
variable "vs_extra_vsix_urls" {
  type        = string
  default     = ""
  description = "Comma-separated .vsix URLs installed into the IDE (e.g. Microsoft Visual Studio Installer Projects, needed for .vdproj). Requires the full IDE. Pin the version in the URL."
}
variable "dotnet_channel" {
  type    = string
  default = "8.0"
}

source "googlecompute" "windows" {
  project_id              = var.project_id
  zone                    = var.zone
  source_image_family     = "windows-2022"
  source_image_project_id = ["windows-cloud"]

  machine_type      = "e2-standard-4"
  disk_size         = 60
  disk_type         = "pd-balanced"
  image_name        = "winbuild-app-${replace(var.image_version, ".", "-")}"
  image_family      = "winbuild-app"
  image_description = "Windows Server 2022 + Visual Studio ${var.vs_edition} + .NET ${var.dotnet_channel} + IIS. Built ${timestamp()}."
  image_labels = {
    owner   = "winbuild-ci"
    source  = "packer"
    version = replace(var.image_version, ".", "-")
  }

  network    = var.network
  subnetwork = var.subnetwork
  tags       = ["wb-builder"]

  service_account_email = var.service_account_email
  scopes                = ["https://www.googleapis.com/auth/cloud-platform"]

  # Management plane over IAP only; the external IP is for egress (Microsoft/NuGet/activation).
  use_iap          = true
  omit_external_ip = false

  # SSH, not WinRM: key-based, no password to generate, hold or leak, and nothing listens on 5985.
  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_timeout            = "20m"
  ssh_handshake_attempts = 60

  # Install OpenSSH Server on first boot and authorise the build's ephemeral key. This runs before Packer
  # connects, so it depends on nothing of ours: the public key arrives in the `ssh-keys` metadata value.
  metadata = {
    ssh-keys                                        = "${var.ssh_username}:${var.ssh_public_key}"
    sysprep-specialize-script-ps1                   = <<-EOT
      $ErrorActionPreference = 'Stop'
      Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
      Set-Service -Name sshd -StartupType Automatic
      Start-Service sshd
      # PowerShell as the default shell, so provisioners behave as they do from a console.
      New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
        -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
      # Administrators authenticate against administrators_authorized_keys, not the per-user file.
      $keys = (Invoke-RestMethod -Uri 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-keys' `
               -Headers @{ 'Metadata-Flavor' = 'Google' })
      $pub = ($keys -split '\s+')[1..2] -join ' '
      $file = 'C:\ProgramData\ssh\administrators_authorized_keys'
      New-Item -ItemType Directory -Force -Path 'C:\ProgramData\ssh' | Out-Null
      Set-Content -Path $file -Value $pub -Encoding ascii
      icacls $file /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
      Restart-Service sshd
      New-NetFirewallRule -DisplayName 'IAP SSH' -Direction Inbound -Protocol TCP -LocalPort 22 `
        -RemoteAddress 35.235.240.0/20 -Action Allow -ErrorAction SilentlyContinue
    EOT
    enable-windows-license-in-google-compute-engine = "true"
  }

  # Captured image is sysprepped, so the instance is generalised before capture.
  skip_create_image = false
}

build {
  name    = "winbuild-app"
  sources = ["source.googlecompute.windows"]

  # 1. Scripts first, so the provisioning steps are the same files a human can read in the repo.
  provisioner "file" {
    source      = "scripts/"
    destination = "C:/packer/scripts"
  }

  # 2. The build contract: the custom folder and the source it compiles.
  provisioner "file" {
    source      = "${path.root}/../custom/"
    destination = "C:/packer/custom"
  }
  provisioner "file" {
    source      = "${path.root}/../src/"
    destination = "C:/packer/src"
  }

  # 2b. Toolchain: Build Tools, Windows SDK, .NET SDK, IIS + ASP.NET Core Hosting Bundle.
  provisioner "powershell" {
    environment_vars = [
      "VS_EDITION=${var.vs_edition}",
      "VS_WORKLOADS=${var.vs_workloads}",
      "VS_DISABLE_OUT_OF_PROC=${var.vs_disable_out_of_proc_build}",
      "VS_EXTRA_VSIX=${var.vs_extra_vsix_urls}",
      "DOTNET_CHANNEL=${var.dotnet_channel}",
    ]
    script = "scripts/install-toolchain.ps1"
  }

  # 3. Run the custom build entrypoint. This is where an application's own build goes: whatever
  #    custom/build.config.json lists is executed, and a non-zero exit fails the image build.
  provisioner "powershell" {
    environment_vars = ["APP_VERSION=${var.app_version}"]
    inline           = ["& 'C:\\packer\\custom\\run.ps1'"]
  }

  # 3b. Troubleshooting access, only when the pipeline asked for it.
  provisioner "powershell" {
    environment_vars = ["DEBUG_USER=${var.debug_user}", "DEBUG_PASSWORD=${var.debug_password}"]
    script           = "scripts/create-debug-user.ps1"
  }

  # 4. Bake a smoke-test copy of the app so the image can be validated without any package registry round trip.
  provisioner "powershell" {
    environment_vars = ["APP_VERSION=${var.app_version}", "SOURCE_URL=${var.source_url}"]
    script           = "scripts/bake-app.ps1"
  }

  # 5. Prove it serves before we capture an image that claims to serve.
  provisioner "powershell" {
    script = "scripts/smoke-test.ps1"
  }

  # 6. Sysprep so the captured image is a clean template, not a used machine.
  provisioner "powershell" {
    script = "scripts/sysprep.ps1"
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
