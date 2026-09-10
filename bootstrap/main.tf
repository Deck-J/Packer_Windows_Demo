resource "google_project_service" "services" {
  for_each = toset([
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id
}

resource "google_kms_key_ring" "terraform_state" {
  name     = "terraform-state"
  location = var.region
  project  = var.project_id

  depends_on = [google_project_service.services]
}

resource "google_kms_crypto_key" "terraform_state" {
  name            = "terraform-state"
  key_ring        = google_kms_key_ring.terraform_state.id
  rotation_period = "7776000s"
}

resource "google_kms_crypto_key_iam_member" "storage_agent" {
  crypto_key_id = google_kms_crypto_key.terraform_state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@gs-project-accounts.iam.gserviceaccount.com"
}

resource "google_storage_bucket" "terraform_state" {
  name                        = var.state_bucket_name
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.terraform_state.id
  }

  depends_on = [google_kms_crypto_key_iam_member.storage_agent]
}

resource "google_storage_bucket_iam_member" "state_access" {
  for_each = var.state_access_members

  bucket = google_storage_bucket.terraform_state.name
  role   = "roles/storage.objectAdmin"
  member = each.value
}
