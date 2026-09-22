# AKS, sized and configured for a $100 credit.
#
# THE COST MODEL — the thing to understand before you apply this:
#
#   Control plane (Free tier)  $0.00/hr   Microsoft runs the API server,
#                                         etcd and scheduler for free. The
#                                         Standard tier ($0.10/hr) buys a
#                                         financially-backed 99.95% SLA and
#                                         scale past 1000 nodes. A portfolio
#                                         needs neither.
#   2x Standard_B2ms nodes    ~$0.192/hr  2 vCPU / 8 GB each, West Europe.
#   Standard Load Balancer    ~$0.025/hr  Created by the first Service of
#                                         type LoadBalancer.
#   2x 32 GB managed disks     ~$0.004/hr OS disks.
#                             ----------
#   TOTAL                     ~$0.22/hr  ->  ~$0.90 for a 4-hour demo session
#                                            ~$160/month if you leave it up
#
# That last number is the whole reason this lives in its own environment with
# its own state: `terraform destroy` here removes the expensive half of the
# platform without touching the registry and storage you want to keep.
#
# Verify current prices before you rely on these numbers:
#   az vm list-prices --location westeurope --size Standard_B2ms  (or the
#   Azure pricing calculator). Cloud prices move.

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name

  # Free tier: no charge for the managed control plane, no uptime SLA.
  sku_tier = "Free"

  # Pinning the version means a cluster you recreate in three weeks is the same
  # cluster. Leaving it unset gives you whatever AKS defaults to that day, which
  # is how a demo that worked last month stops working.
  kubernetes_version = var.kubernetes_version

  default_node_pool {
    name       = "system"
    node_count = var.node_count
    vm_size    = var.vm_size

    # 32 GB is the smallest disk that comfortably holds the node image plus a
    # few container images. Smaller disks also get less IOPS on Azure, which
    # shows up as slow image pulls.
    os_disk_size_gb = 32
    os_disk_type    = "Managed"

    # Autoscaling off: with a fixed 2-node pool you know exactly what you are
    # paying per hour. Autoscaling is the right answer in production and the
    # wrong one when the goal is a predictable bill.
    auto_scaling_enabled = false

    # Kubernetes will not schedule to a node it thinks is full. Setting the
    # max pods low on small nodes avoids scheduling more pods than the node's
    # memory can actually serve.
    max_pods = 50

    tags = var.tags
  }

  # A system-assigned managed identity means no service principal secret to
  # create, store, rotate, or leak. Azure creates the identity with the cluster
  # and deletes it with the cluster.
  identity {
    type = "SystemAssigned"
  }

  network_profile {
    # kubenet over azure CNI: kubenet allocates pod IPs from an overlay rather
    # than from the VNet, so it does not consume subnet address space and does
    # not need a pre-sized subnet. Azure CNI is the production answer when pods
    # must be routable from the VNet; nothing here needs that.
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  # Local (certificate) admin accounts disabled would be the hardened choice,
  # but it requires Entra ID integration to then get a kubeconfig at all. For a
  # single-operator portfolio cluster, local accounts with a short-lived cluster
  # are the pragmatic trade. Say that out loud rather than pretending otherwise.
  local_account_disabled = false

  tags = var.tags

  lifecycle {
    # Node count drifts if anything ever scales the pool. Ignoring it stops
    # Terraform from fighting the change on the next plan.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# Let the cluster pull from ACR without a registry password.
#
# HOW THIS WORKS: AKS has a second identity, the kubelet identity, which is
# what actually pulls images. Granting it AcrPull on the registry means
# `imagePullSecrets` is never needed. When someone asks how you handle registry
# credentials in Kubernetes, "I don't — the kubelet identity has AcrPull" is
# the answer you want to be able to give.
resource "azurerm_role_assignment" "acr_pull" {
  count = var.acr_id == "" ? 0 : 1

  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = var.acr_id
  skip_service_principal_aad_check = true
}

# Let the cluster read the data lake, same idea: identity instead of keys.
resource "azurerm_role_assignment" "storage_contributor" {
  count = var.storage_account_id == "" ? 0 : 1

  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  role_definition_name = "Storage Blob Data Contributor"
  scope                = var.storage_account_id
}
