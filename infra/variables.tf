variable "project_id" { type = string }

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone_a" {
  type    = string
  default = "us-central1-a"
}

variable "zone_b" {
  type    = string
  default = "us-central1-b"
}

variable "image" {
  type        = string
  description = "Full image self-link or name, e.g. projects/p/global/images/winbuild-app-1-4-0-abc1234. Pin the version, not the family, so a run cannot pick up a different image."
  default     = ""
}

variable "image_family" {
  type    = string
  default = "winbuild-app"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "node_service_account" { type = string }

variable "app_version" { type = string }

variable "package_url" {
  type        = string
  description = "gs:// URL of the exact .nupkg staged for this run"
}

variable "package_sha256" { type = string }

variable "ttl" {
  type        = string
  default     = "2h"
  description = "Reaper TTL label. '2h' for ephemeral test runs; 'none' for a persistent environment."
}

variable "run_id" {
  type        = string
  description = "Labels every resource; the label sweep and the janitor use it"
}

variable "dynatrace_tenant" {
  type        = string
  default     = ""
  description = "Dynatrace environment id, e.g. abc12345. Empty disables agent installation."
}

variable "dynatrace_host_group" {
  type        = string
  default     = ""
  description = "OneAgent host group, e.g. winbuild-test. Empty means the default group."
}

variable "dynatrace_token_secret" {
  type        = string
  default     = ""
  description = "Secret Manager secret holding a Dynatrace PaaS token. The node service account reads it; the token is never in metadata, the image or the repo."
}

variable "dynatrace_dry_run" {
  type        = bool
  default     = false
  description = "Prove metadata and Secret Manager access without downloading or installing the agent. For testing the plumbing without a tenant."
}

variable "otel_endpoint" {
  type        = string
  default     = ""
  description = "OTLP endpoint the app exports to, e.g. http://collector:4317 or https://otlp.example/v1/otlp. Empty disables export."
}

variable "network_name" {
  type    = string
  default = "wb-net"
}

variable "subnet_name" {
  type    = string
  default = "wb-subnet"
}

variable "subnet_cidr" {
  type    = string
  default = "10.42.0.0/24"
}
