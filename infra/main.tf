locals {
  labels = {
    owner   = "winbuild-ci"
    run     = var.run_id
    version = replace(var.app_version, ".", "-")
    ttl     = var.ttl
  }
  image_self_link = var.image != "" ? var.image : "projects/${var.project_id}/global/images/family/${var.image_family}"
}

# --- network -----------------------------------------------------------------
resource "google_compute_network" "wb" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "wb" {
  name          = var.subnet_name
  network       = google_compute_network.wb.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# The only ingress the app gets: Google's load-balancer proxy and health-check ranges.
resource "google_compute_firewall" "lb" {
  name          = "${var.run_id}-fw-lb"
  network       = google_compute_network.wb.name
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["wb-node"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# Nodes have no external IP at all, so "reachable through the LB" is a structural property.
resource "google_compute_instance_template" "node" {
  name_prefix  = "${var.run_id}-node-"
  machine_type = var.machine_type
  region       = var.region
  labels       = local.labels
  tags         = ["wb-node"]

  disk {
    source_image = local.image_self_link
    disk_size_gb = 50
    disk_type    = "pd-balanced"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = google_compute_network.wb.id
    subnetwork = google_compute_subnetwork.wb.id
    # no access_config block: no external IP
  }

  service_account {
    email  = var.node_service_account
    scopes = ["cloud-platform"]
  }

  metadata = {
    windows-startup-script-ps1 = file("${path.module}/../image/node-startup.ps1")
    app-version                = var.app_version
    package-url                = var.package_url
    package-sha256             = var.package_sha256
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_instance_group_manager" "nodes" {
  name               = "${var.run_id}-mig"
  region             = var.region
  base_instance_name = "${var.run_id}-node"
  target_size        = var.node_count

  version {
    instance_template = google_compute_instance_template.node.id
  }

  distribution_policy_zones = [var.zone_a, var.zone_b]

  named_port {
    name = "http"
    port = 80
  }

  # The MIG replaces an unhealthy node on its own; the LB test then has something to test.
  auto_healing_policies {
    health_check      = google_compute_region_health_check.app.id
    initial_delay_sec = 600
  }

  update_policy {
    type                         = "OPPORTUNISTIC"
    minimal_action               = "REPLACE"
    max_surge_fixed              = 1
    max_unavailable_fixed        = 0
    instance_redistribution_type = "NONE"
  }
}

# --- load balancer -----------------------------------------------------------
resource "google_compute_region_health_check" "app" {
  name   = "${var.run_id}-hc"
  region = var.region

  http_health_check {
    port         = 80
    request_path = "/healthz"
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_region_backend_service" "app" {
  name                  = "${var.run_id}-bs"
  region                = var.region
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_region_health_check.app.id]
  timeout_sec           = 30
  session_affinity      = "NONE" # so both nodes actually receive traffic

  backend {
    group           = google_compute_region_instance_group_manager.nodes.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_region_url_map" "app" {
  name            = "${var.run_id}-um"
  region          = var.region
  default_service = google_compute_region_backend_service.app.id
}

resource "google_compute_region_target_http_proxy" "app" {
  name    = "${var.run_id}-px"
  region  = var.region
  url_map = google_compute_region_url_map.app.id
}

resource "google_compute_address" "lb" {
  name         = "${var.run_id}-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = local.labels
}

resource "google_compute_forwarding_rule" "app" {
  name                  = "${var.run_id}-fr"
  region                = var.region
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
  ip_address            = google_compute_address.lb.address
  target                = google_compute_region_target_http_proxy.app.id
  port_range            = "80"
  labels                = local.labels
}
