# 1. Three Uniform Bucket-Level Access (UBLA) GCS buckets (BOM-12)
locals {
  buckets = {
    snapshots        = "${var.project_id}-${var.name_prefix}-snapshots"
    snapshots_assets = "${var.project_id}-${var.name_prefix}-snapshots-assets"
    cas_artifacts    = "${var.project_id}-${var.name_prefix}-cas-artifacts"
    sealed_evals     = "${var.project_id}-${var.name_prefix}-sealed-evals"
  }
}

resource "google_storage_bucket" "ubla" {
  for_each                    = local.buckets
  name                        = each.value
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  versioning {
    enabled = each.key == "sealed_evals"
  }

  depends_on = [google_project_service.enabled]
}

# 2. Local Artifact Registry for control-plane, verifier, and digest-pinned pi-mono guest images
resource "google_artifact_registry_repository" "local_images" {
  location      = var.region
  repository_id = "${var.name_prefix}-local"
  description   = "SwarmRSI control plane, 4-gate verifier, and pi-mono/Harbor microVM images"
  format        = "DOCKER"
  depends_on    = [google_project_service.enabled]
}

# 3. Remote mirror for ghcr.io (Agent Substrate v1.0.1 images over Private Google Access)
resource "google_artifact_registry_repository" "ghcr_mirror" {
  location      = var.region
  repository_id = "${var.name_prefix}-ghcr-mirror"
  description   = "Artifact Registry remote mirror for ghcr.io/agent-substrate/substrate"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description                 = "GitHub Container Registry upstream"
    disable_upstream_validation = true

    docker_repository {
      custom_repository {
        uri = "https://ghcr.io"
      }
    }
  }

  depends_on = [google_project_service.enabled]
}

# 4. Remote mirror for Docker Hub (postgres:18-alpine & base runtime layers)
resource "google_artifact_registry_repository" "dockerhub_mirror" {
  location      = var.region
  repository_id = "${var.name_prefix}-dockerhub-mirror"
  description   = "Artifact Registry remote mirror for Docker Hub"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description                 = "Docker Hub upstream"
    disable_upstream_validation = true

    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.enabled]
}
