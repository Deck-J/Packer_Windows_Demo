variable "project_id" {
  description = "GCP project used for the image build infrastructure."
  type        = string
}

variable "region" {
  description = "GCP region for the build network."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the temporary Packer builder VM."
  type        = string
  default     = "us-central1-a"
}

variable "github_repository" {
  description = "GitHub repository allowed to exchange OIDC tokens, in owner/name form."
  type        = string
}

variable "terraform_executor_service_account" {
  description = "Existing service account used by GitHub Actions for Terraform and Packer."
  type        = string
}

variable "network_name" {
  description = "Name of the dedicated build VPC."
  type        = string
  default     = "windows-image-build"
}

variable "subnet_cidr" {
  description = "CIDR range for the builder subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "golden_image" {
  description = "Optional Windows golden image name. Set this to create the demo worker VM."
  type        = string
  default     = ""
}

variable "app_release_url" {
  description = "Public GitHub Release asset URL for the worker application zip."
  type        = string
  default     = ""
}

