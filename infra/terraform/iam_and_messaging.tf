# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0

# Least-Privilege IAM + Workload Identity + Cloud Tasks + Pub/Sub + Verifier Job (BOM-07..BOM-09)

# 1. Dedicated GKE Node Service Account (avoids empty default compute SA permissions)
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.name_prefix}-gke-nodes"
  display_name = "SwarmRSI GKE Node Pool SA"
  depends_on   = [google_project_service.enabled]
}

resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset([
    "roles/container.defaultNodeServiceAccount",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Allow atelet DaemonSet (ate-system/atelet) to read/write microVM snapshots & assets
resource "google_storage_bucket_iam_member" "atelet_snapshots" {
  for_each = toset(["snapshots", "snapshots_assets"])
  bucket   = google_storage_bucket.ubla[each.value].name
  role     = "roles/storage.objectAdmin"
  member   = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/ate-system/sa/atelet"
}

# 2. Trusted Control Plane & Keyless Model Broker Service Account (NEVER granted sealed_evals access!)
resource "google_service_account" "broker" {
  account_id   = "${var.name_prefix}-broker"
  display_name = "SwarmRSI Keyless Broker, Orchestrator & Gemma Observer SA"
  depends_on   = [google_project_service.enabled]
}

resource "google_project_iam_member" "broker_roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/alloydb.client",
    "roles/cloudtasks.enqueuer",
    "roles/pubsub.publisher",
    "roles/pubsub.subscriber",
    "roles/run.invoker",
    "roles/secretmanager.secretAccessor",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.broker.email}"
}

resource "google_storage_bucket_iam_member" "broker_cas_rw" {
  bucket = google_storage_bucket.ubla["cas_artifacts"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.broker.email}"
}

# Bind GKE KSA ns/harness/sa/broker -> GSA broker via Workload Identity
resource "google_service_account_iam_member" "broker_wif" {
  service_account_id = google_service_account.broker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[harness/broker]"
}

# 3. Air-Gapped 4-Gate Verifier Service Account (SOLE principal able to read sealed_evals!)
resource "google_service_account" "verifier" {
  account_id   = "${var.name_prefix}-verifier"
  display_name = "SwarmRSI Air-Gapped 4-Gate Verifier SA"
  depends_on   = [google_project_service.enabled]
}

resource "google_project_iam_member" "verifier_roles" {
  for_each = toset([
    "roles/alloydb.client",
    "roles/pubsub.publisher",
    "roles/secretmanager.secretAccessor",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.verifier.email}"
}

resource "google_storage_bucket_iam_member" "verifier_sealed_ro" {
  bucket = google_storage_bucket.ubla["sealed_evals"].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.verifier.email}"
}

resource "google_storage_bucket_iam_member" "verifier_cas_ro" {
  bucket = google_storage_bucket.ubla["cas_artifacts"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.verifier.email}"
}

# 4. Slot-Matched Cloud Tasks Queue & Global-Halt Pub/Sub Bus (BOM-08)
resource "google_cloud_tasks_queue" "swarm_trials" {
  name     = "${var.name_prefix}-trials"
  location = var.region

  rate_limits {
    max_concurrent_dispatches = var.worker_concurrency
    max_dispatches_per_second = 5
  }

  retry_config {
    max_attempts = 3
    min_backoff  = "10s"
    max_backoff  = "120s"
  }

  depends_on = [google_project_service.enabled]
}

resource "google_pubsub_topic" "trial_events" {
  name       = "${var.name_prefix}-trial-events"
  depends_on = [google_project_service.enabled]
}

resource "google_pubsub_topic" "global_halt" {
  name       = "${var.name_prefix}-global-halt"
  depends_on = [google_project_service.enabled]
}

resource "google_pubsub_subscription" "broker_global_halt" {
  name                 = "${var.name_prefix}-broker-global-halt"
  topic                = google_pubsub_topic.global_halt.id
  ack_deadline_seconds = 10
}

# 5. Deterministic 4-Gate Verifier Cloud Run v2 Job (Zero LLM access, private VPC egress to AlloyDB)
resource "google_cloud_run_v2_job" "verifier" {
  name                = "${var.name_prefix}-verifier"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.verifier.email
      max_retries     = 0
      timeout         = "900s"

      vpc_access {
        network_interfaces {
          network    = google_compute_network.vpc.name
          subnetwork = google_compute_subnetwork.gke_subnet.name
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.local_images.repository_id}/verifier:latest"

        resources {
          limits = {
            cpu    = "4"
            memory = "8Gi"
          }
        }

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "ALLOYDB_HOST"
          value = google_alloydb_instance.primary.ip_address
        }
        env {
          name  = "CAS_BUCKET"
          value = google_storage_bucket.ubla["cas_artifacts"].name
        }
        env {
          name  = "SEALED_EVALS_BUCKET"
          value = google_storage_bucket.ubla["sealed_evals"].name
        }
        env {
          name  = "GLOBAL_HALT_TOPIC"
          value = google_pubsub_topic.global_halt.name
        }
        env {
          name = "ALLOYDB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.alloydb_admin_pw.secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].template[0].containers[0].image]
  }
}
