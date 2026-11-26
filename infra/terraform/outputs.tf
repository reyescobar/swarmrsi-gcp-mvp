# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0

output "gke_cluster_name" {
  value = google_container_cluster.primary.name
}

output "alloydb_private_ip" {
  value = google_alloydb_instance.primary.ip_address
}

output "artifact_registry_local" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.local_images.repository_id}"
}

output "artifact_registry_ghcr_mirror" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.ghcr_mirror.repository_id}"
}

output "buckets" {
  value = { for k, b in google_storage_bucket.ubla : k => b.name }
}

output "sandbox_mode_active" {
  value = var.enable_baremetal_microvm ? "microvm (c3-highcpu-192-metal + gVisor fallback)" : "gvisor (c3-standard-8 Day-1 zero-quota mode)"
}
