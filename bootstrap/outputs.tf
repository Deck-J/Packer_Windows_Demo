output "state_bucket_name" {
  value = google_storage_bucket.terraform_state.name
}

output "state_kms_key" {
  value = google_kms_crypto_key.terraform_state.id
}
