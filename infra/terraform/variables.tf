variable "project_id" {
  description = "Target Google Cloud Project ID."
  type        = string
}

variable "region" {
  description = "Primary GCP region (us-central1 recommended for C3 bare metal + AlloyDB)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Primary GCP zone (us-central1-c serves c3-highcpu-192-metal)."
  type        = string
  default     = "us-central1-c"
}

variable "name_prefix" {
  description = "Short resource prefix."
  type        = string
  default     = "swarmrsi"
}

variable "enable_baremetal_microvm" {
  description = "Provision x86 c3-highcpu-192-metal node pool (0..1 autoscaled) for KVM microVMs. Set false for instant Day-1 zero-quota boot on Agent Substrate gVisor."
  type        = bool
  default     = true
}

variable "baremetal_machine_type" {
  description = "x86 bare-metal shape with /dev/kvm for Agent Substrate Cloud Hypervisor microVMs."
  type        = string
  default     = "c3-highcpu-192-metal"
}

variable "enable_alloydb_ha" {
  description = "Set false for cost-efficient Zonal MVP (~$0.62/hr); set true for Regional HA (~$1.25/hr)."
  type        = bool
  default     = false
}

variable "alloydb_cpu_count" {
  description = "vCPU count for AlloyDB primary instance (2, 4, 8, 16...)."
  type        = number
  default     = 4
}

variable "worker_concurrency" {
  description = "Default parallel worker sandboxes per round (n=4 per SwarmRSI Table 5)."
  type        = number
  default     = 4
}

variable "worker_model" {
  description = "Pinned Vertex AI Gemini model ID for pi-mono workers (global endpoint)."
  type        = string
  default     = "gemini-3.5-flash"
}

variable "observer_model" {
  description = "Cross-family batch Observer model ID invoked strictly at round close."
  type        = string
  default     = "gemma-3-27b-it"
}

variable "authorized_cidr" {
  description = "Admin workstation / Cloud Shell CIDR allowed to reach GKE control plane."
  type        = string
  default     = "0.0.0.0/0"
}
