variable "project_id" {
  description = "GCP project that owns the Terraform state bucket and KMS key."
  type        = string
}

variable "region" {
  description = "GCP location for the state bucket and KMS key ring."
  type        = string
  default     = "us-central1"
}

variable "state_bucket_name" {
  description = "Globally unique GCS bucket name for Terraform state."
  type        = string
}

variable "state_access_members" {
  description = "IAM members allowed to read and write Terraform state objects."
  type        = set(string)
  default     = []
}
