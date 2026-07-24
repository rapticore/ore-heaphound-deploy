resource "azurerm_user_assigned_identity" "worker" {
  name                = "${var.name}-worker"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name

  private_cluster_enabled           = true
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  local_account_disabled            = true
  sku_tier                          = "Standard"
  automatic_upgrade_channel         = "patch"
  node_os_upgrade_channel           = "NodeImage"

  default_node_pool {
    name                         = "system"
    vm_size                      = "Standard_D4ds_v5"
    vnet_subnet_id               = var.subnet_id
    auto_scaling_enabled         = true
    min_count                    = 2
    max_count                    = 6
    only_critical_addons_enabled = true
    node_labels = {
      "rapticore.io/workload" = "system"
      "rapticore.io/capacity" = "on-demand"
    }
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    outbound_type  = "loadBalancer"
  }

  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = false
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  tags = var.tags
}

locals {
  node_pools = merge({
    scanspot = {
      vm_size  = "Standard_D8ds_v5"
      workload = "scan"
      priority = "Spot"
      min      = 0
      max      = 100
      gpu      = false
    }
    llmspot = {
      vm_size  = "Standard_NC8as_T4_v3"
      workload = "llm"
      priority = "Spot"
      min      = 0
      max      = 20
      gpu      = true
    }
    }, var.enable_on_demand_fallback ? {
    scanfallback = {
      vm_size  = "Standard_D8ds_v5"
      workload = "scan"
      priority = "Regular"
      min      = 0
      max      = 20
      gpu      = false
    }
    llmfallback = {
      vm_size  = "Standard_NC8as_T4_v3"
      workload = "llm"
      priority = "Regular"
      min      = 0
      max      = 4
      gpu      = true
    }
  } : {})
}

resource "azurerm_kubernetes_cluster_node_pool" "pool" {
  for_each = local.node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.vm_size
  vnet_subnet_id        = var.subnet_id
  mode                  = "User"
  priority              = each.value.priority
  eviction_policy       = each.value.priority == "Spot" ? "Delete" : null
  spot_max_price        = each.value.priority == "Spot" ? -1 : null
  auto_scaling_enabled  = true
  min_count             = each.value.min
  max_count             = each.value.max
  os_disk_type          = "Managed"
  os_disk_size_gb       = each.value.gpu ? 200 : 100

  node_labels = {
    "rapticore.io/workload" = each.value.workload
    "rapticore.io/capacity" = each.value.priority == "Spot" ? "spot" : "on-demand"
  }
  node_taints = ["rapticore.io/workload=${each.value.workload}:NoSchedule"]

  tags = var.tags
}

resource "azurerm_federated_identity_credential" "worker" {
  name                = "${var.name}-worker"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.worker.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:${var.namespace}:${var.kubernetes_service_account_name}"
}

resource "azurerm_role_assignment" "source_reader" {
  for_each             = var.source_storage_scope_ids
  scope                = each.value
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.worker.principal_id
}
