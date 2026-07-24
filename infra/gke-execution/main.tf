resource "google_service_account" "nodes" {
  account_id   = substr(replace("${var.name}-nodes", "_", "-"), 0, 30)
  display_name = "Ore Heaphound GKE nodes"
}

resource "google_project_iam_member" "node_baseline" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  name     = var.name
  location = var.region

  network    = var.network
  subnetwork = var.subnetwork

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = true
  enable_shielded_nodes    = true
  networking_mode          = "VPC_NATIVE"

  release_channel { channel = "REGULAR" }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    gcp_filestore_csi_driver_config {
      enabled = true
    }
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_cidrs
      content {
        cidr_block   = cidr_blocks.key
        display_name = cidr_blocks.value
      }
    }
  }

  cluster_autoscaling {
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
  }

  resource_labels = var.tags
}

locals {
  node_pools = merge({
    system = {
      machine_type = "e2-standard-4"
      workload     = "system"
      capacity     = "on-demand"
      spot         = false
      min          = 2
      max          = 6
      gpu_type     = ""
    }
    scan_spot = {
      machine_type = "c3-standard-8"
      workload     = "scan"
      capacity     = "spot"
      spot         = true
      min          = 0
      max          = 100
      gpu_type     = ""
    }
    llm_spot = {
      machine_type = "n1-standard-8"
      workload     = "llm"
      capacity     = "spot"
      spot         = true
      min          = 0
      max          = 20
      gpu_type     = "nvidia-tesla-t4"
    }
    }, var.enable_on_demand_fallback ? {
    scan_fallback = {
      machine_type = "c3-standard-8"
      workload     = "scan"
      capacity     = "on-demand"
      spot         = false
      min          = 0
      max          = 20
      gpu_type     = ""
    }
    llm_fallback = {
      machine_type = "n1-standard-8"
      workload     = "llm"
      capacity     = "on-demand"
      spot         = false
      min          = 0
      max          = 4
      gpu_type     = "nvidia-tesla-t4"
    }
  } : {})
}

resource "google_container_node_pool" "pool" {
  for_each = local.node_pools

  name       = replace(each.key, "_", "-")
  cluster    = google_container_cluster.this.name
  location   = google_container_cluster.this.location
  node_count = each.value.min

  autoscaling {
    min_node_count = each.value.min
    max_node_count = each.value.max
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = each.value.machine_type
    spot            = each.value.spot
    service_account = google_service_account.nodes.email
    disk_type       = "pd-balanced"
    disk_size_gb    = each.value.workload == "llm" ? 200 : 100

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels = {
      "rapticore.io/workload" = each.value.workload
      "rapticore.io/capacity" = each.value.capacity
    }
    dynamic "taint" {
      for_each = each.value.workload == "system" ? [] : [each.value.workload]
      content {
        key    = "rapticore.io/workload"
        value  = taint.value
        effect = "NO_SCHEDULE"
      }
    }
    dynamic "guest_accelerator" {
      for_each = each.value.gpu_type == "" ? [] : [each.value.gpu_type]
      content {
        type  = guest_accelerator.value
        count = 1
        gpu_driver_installation_config {
          gpu_driver_version = "LATEST"
        }
      }
    }
    workload_metadata_config { mode = "GKE_METADATA" }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    metadata = { disable-legacy-endpoints = "true" }
    tags     = ["ore-heaphound"]
  }

  lifecycle {
    ignore_changes = [node_count]
  }

  depends_on = [google_project_iam_member.node_baseline]
}

resource "google_service_account" "worker" {
  account_id   = substr(replace("${var.name}-worker", "_", "-"), 0, 30)
  display_name = "Ore Heaphound remote worker"
}

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.worker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.kubernetes_service_account_name}]"
}

resource "google_storage_bucket_iam_member" "source_reader" {
  for_each = var.source_bucket_names
  bucket   = each.value
  role     = "roles/storage.objectViewer"
  member   = "serviceAccount:${google_service_account.worker.email}"
}

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.18.2"
  wait             = true

  depends_on = [google_container_node_pool.pool]
}
