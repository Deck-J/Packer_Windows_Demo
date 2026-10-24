terraform {
  required_version = ">= 1.9.0"

  # Remote state, versioned bucket, native locking. The bucket is created by bootstrap/00-bootstrap.sh.
  backend "gcs" {
    bucket = "" # set with -backend-config="bucket=<state bucket>" in CI
    prefix = "winbuild"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone_a
}
