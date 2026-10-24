output "lb_ip" {
  description = "The address the reachability test must be run against"
  value       = google_compute_address.lb.address
}

output "mig_name" { value = google_compute_region_instance_group_manager.nodes.name }

output "backend_service" { value = google_compute_region_backend_service.app.name }

output "image_used" { value = local.image_self_link }

output "node_count" { value = var.node_count }
