output "builder_service_account" {
  value = google_service_account.builder.email
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "build_network" {
  value = google_compute_network.build.name
}

output "build_subnetwork" {
  value = google_compute_subnetwork.build.name
}

output "winrm_secret_id" {
  value = google_secret_manager_secret.winrm.secret_id
}

output "worker_public_ip" {
  value = try(google_compute_instance.worker[0].network_interface[0].access_config[0].nat_ip, null)
}

