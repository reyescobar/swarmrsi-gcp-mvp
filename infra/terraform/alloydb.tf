# Unified AlloyDB for PostgreSQL 17 + AlloyDB AI (BOM-05)
resource "random_password" "alloydb_admin" {
  length  = 24
  special = false
}

resource "random_password" "sandbox_ro" {
  length  = 24
  special = false
}

resource "google_secret_manager_secret" "alloydb_admin_pw" {
  secret_id = "${var.name_prefix}-alloydb-admin-pw"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "alloydb_admin_pw_v1" {
  secret      = google_secret_manager_secret.alloydb_admin_pw.id
  secret_data = random_password.alloydb_admin.result
}

resource "google_secret_manager_secret" "sandbox_ro_pw" {
  secret_id = "${var.name_prefix}-sandbox-ro-pw"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "sandbox_ro_pw_v1" {
  secret      = google_secret_manager_secret.sandbox_ro_pw.id
  secret_data = random_password.sandbox_ro.result
}

resource "google_alloydb_cluster" "main" {
  cluster_id       = "${var.name_prefix}-pg17"
  location         = var.region
  database_version = "POSTGRES_17"

  network_config {
    network = google_compute_network.vpc.id
  }

  initial_user {
    user     = "postgres"
    password = random_password.alloydb_admin.result
  }

  depends_on = [google_service_networking_connection.psa_connection]
}

resource "google_alloydb_instance" "primary" {
  cluster           = google_alloydb_cluster.main.name
  instance_id       = "${var.name_prefix}-primary"
  instance_type     = "PRIMARY"
  availability_type = var.enable_alloydb_ha ? "REGIONAL" : "ZONAL"
  gce_zone          = var.enable_alloydb_ha ? null : var.zone

  machine_config {
    cpu_count = var.alloydb_cpu_count
  }

  database_flags = {
    "google_ml_integration.enable_model_support" = "on"
    "scann.enable_preview_features"              = "off"
  }
}

# Allow AlloyDB service agent to invoke Vertex AI gemini-embedding-001 inside SQL
resource "google_project_iam_member" "alloydb_vertex_ai" {
  project    = var.project_id
  role       = "roles/aiplatform.user"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
  depends_on = [google_alloydb_instance.primary]
}
