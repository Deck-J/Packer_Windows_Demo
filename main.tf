resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "secretmanager.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "build" {
  name                    = var.network_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.services]
}

resource "google_compute_subnetwork" "build" {
  name          = "${var.network_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.build.id
}

resource "google_compute_firewall" "iap_winrm" {
  name    = "${var.network_name}-iap-winrm"
  network = google_compute_network.build.name

  # Packer reaches the temporary builder through Cloud IAP, not a public
  # WinRM endpoint. IAP TCP forwarding uses this documented source range.
  allow {
    protocol = "tcp"
    ports    = ["5986"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["packer-windows-builder"]
}

resource "google_compute_firewall" "iap_ssh" {
  name    = "${var.network_name}-iap-ssh"
  network = google_compute_network.build.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["packer-windows-builder", "windows-demo-worker"]
}

resource "google_compute_firewall" "worker_http" {
  count   = var.golden_image != "" && var.app_release_url != "" ? 1 : 0
  name    = "${var.network_name}-worker-http"
  network = google_compute_network.build.name

  # Demo-only public application endpoint. Restrict source_ranges before use
  # outside a disposable demonstration project.
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["windows-demo-worker"]
}

resource "google_compute_instance" "worker" {
  count        = var.golden_image != "" && var.app_release_url != "" ? 1 : 0
  name         = "windows-demo-worker"
  machine_type = "e2-medium"
  zone         = var.zone
  tags         = ["windows-demo-worker"]

  boot_disk {
    initialize_params {
      image = var.golden_image
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.build.id
    access_config {}
  }

  metadata = {
    windows-startup-script-ps1 = templatefile("${path.module}/scripts/deploy-worker.ps1.tftpl", {
      release_url    = var.app_release_url
      ssh_public_key = var.worker_ssh_public_key
    })
  }

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

resource "google_service_account" "builder" {
  account_id   = "windows-image-builder"
  display_name = "Windows image builder"
}

resource "google_project_iam_member" "builder_compute" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "builder_service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "builder_iap" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "terraform_executor_iap" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${var.terraform_executor_service_account}"
}

resource "google_project_iam_member" "builder_image_admin" {
  project = var.project_id
  role    = "roles/compute.imageAdmin"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "random_password" "winrm" {
  length           = 32
  special          = true
  override_special = "!@#$%"
}

resource "google_secret_manager_secret" "winrm" {
  secret_id = "packer-winrm-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "winrm" {
  secret      = google_secret_manager_secret.winrm.id
  secret_data = random_password.winrm.result
}

resource "google_secret_manager_secret_iam_member" "builder_access" {
  secret_id = google_secret_manager_secret.winrm.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_secret_manager_secret_iam_member" "terraform_executor_access" {
  secret_id = google_secret_manager_secret.winrm.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.terraform_executor_service_account}"
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for the Windows image pipeline"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_federation" {
  service_account_id = google_service_account.builder.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
