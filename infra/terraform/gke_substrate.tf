# GKE Standard 1.37+ Private Cluster + Dual Agent Substrate Pools (BOM-01 & BOM-02)
resource "google_container_cluster" "primary" {
  name                     = "${var.name_prefix}-gke"
  location                 = var.zone
  network                  = google_compute_network.vpc.id
  subnetwork               = google_compute_subnetwork.gke_subnet.id
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  # Agent Substrate v1.0.1 requires GKE Standard >= 1.37 + Dataplane V2 (Cilium eBPF)
  min_master_version = "1.37"
  datapath_provider  = "ADVANCED_DATAPATH"

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.32/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.authorized_cidr
      display_name = "admin-access"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.enabled]
}

# Pool A: Always-available Control Plane + gVisor Dev/Fallback Sandbox Pool (zero special quota)
resource "google_container_node_pool" "system_and_gvisor" {
  name       = "system-and-gvisor"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = 2

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = "c3-standard-8"
    disk_type       = "pd-balanced"
    disk_size_gb    = 150
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool = "system-gvisor"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# Pool B: x86 Bare-Metal KVM Pool for Cloud Hypervisor MicroVMs + Cold Harbor Docker Gate (BOM-02)
# Autoscaled 0..1 so idle cost outside campaign windows is $0.00/hr!
resource "google_container_node_pool" "microvm_metal" {
  count    = var.enable_baremetal_microvm ? 1 : 0
  name     = "microvm-metal"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count  = 0
    max_node_count  = 1
    location_policy = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = false # Prevent mid-campaign eviction during active benchmark windows
  }

  node_config {
    machine_type    = var.baremetal_machine_type
    disk_type       = "hyperdisk-balanced"
    disk_size_gb    = 500
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Bare metal exposes native /dev/kvm without nested virt and lacks Shielded vTPM
    advanced_machine_features {
      enable_nested_virtualization = false
    }

    shielded_instance_config {
      enable_secure_boot          = false
      enable_integrity_monitoring = false
    }

    labels = {
      "pool"                                                   = "microvm-metal"
      "clusterautoscaler-nodetemplate-resources.ate.dev/kvm"   = "4096"
    }

    taint {
      key    = "ate.dev/sandboxClass"
      value  = "microvm"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
