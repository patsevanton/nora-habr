resource "yandex_iam_service_account" "sa_k8s_editor" {
  folder_id = local.folder_id
  name      = "sa-k8s-editor"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_k8s_editor_permissions" {
  folder_id = local.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa_k8s_editor.id}"
}

resource "time_sleep" "wait_sa" {
  create_duration = "20s"
  depends_on = [
    yandex_iam_service_account.sa_k8s_editor,
    yandex_resourcemanager_folder_iam_member.sa_k8s_editor_permissions
  ]
}

resource "yandex_kubernetes_cluster" "sentry" {
  name       = "sentry"
  folder_id  = local.folder_id
  network_id = local.network_id

  master {
    version = "1.33"
    zonal {
      zone      = local.subnet_a_zone
      subnet_id = local.subnet_a_id
    }
    public_ip = true
  }

  service_account_id      = yandex_iam_service_account.sa_k8s_editor.id
  node_service_account_id = yandex_iam_service_account.sa_k8s_editor.id
  release_channel         = "STABLE"
  depends_on              = [time_sleep.wait_sa]
}

resource "yandex_kubernetes_node_group" "k8s_node_group_a" {
  description = "Node group for Managed Kubernetes cluster in zone A"
  name        = "k8s-node-group-a"
  cluster_id  = yandex_kubernetes_cluster.sentry.id
  version     = "1.33"

  scale_policy {
    auto_scale {
      min     = 1
      max     = 3
      initial = 1
    }
  }

  allocation_policy {
    location { zone = local.subnet_a_zone }
  }

  instance_template {
    platform_id = "standard-v2"

    network_interface {
      nat = true
      subnet_ids = [local.subnet_a_id]
    }

    resources {
      memory = 16
      cores  = 4
    }

    boot_disk {
      type = "network-hdd"
      size = 65
    }

    scheduling_policy {
      preemptible = true
    }
  }
}

provider "helm" {
  kubernetes = {
    host                   = yandex_kubernetes_cluster.sentry.master[0].external_v4_endpoint
    cluster_ca_certificate = yandex_kubernetes_cluster.sentry.master[0].cluster_ca_certificate
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["k8s", "create-token"]
      command     = "yc"
    }
  }
}

resource "helm_release" "traefik" {
  name             = "traefik"
  chart            = "traefik"
  repository       = "https://traefik.github.io/charts"
  version          = "34.2.0"
  namespace        = "traefik"
  create_namespace = true

  depends_on = [
    yandex_kubernetes_cluster.sentry,
    yandex_kubernetes_node_group.k8s_node_group_a
  ]

  values = [
    yamlencode({
      service = {
        type = "LoadBalancer"
        spec = {
          loadBalancerIP = local.ingress_ip
        }
      }
    })
  ]
}

output "k8s_cluster_credentials" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.sentry.id} --external --force"
}

output "ingress_public_ip" {
  value = local.ingress_ip
}
