data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.gke_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.gke_cluster.master_auth[0].cluster_ca_certificate)
}

# VPC Network
resource "google_compute_network" "vpc_network" {
  name                    = "gke-vpc-network"
  auto_create_subnetworks = false

  depends_on = [google_project_service.gcp_services["compute.googleapis.com"]]
}

# Subnetworks
resource "google_compute_subnetwork" "nodes_subnetwork" {
  name          = "nodes-subnetwork"
  ip_cidr_range = "10.0.0.0/24"
  region        = "asia-southeast1"
  network       = google_compute_network.vpc_network.id

  depends_on = [google_project_service.gcp_services["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "pods_subnetwork" {
  name          = "pods-subnetwork"
  ip_cidr_range = "10.1.0.0/16"
  region        = "asia-southeast1"
  network       = google_compute_network.vpc_network.id

  depends_on = [google_project_service.gcp_services["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "services_subnetwork" {
  name          = "services-subnetwork"
  ip_cidr_range = "10.2.0.0/16"
  region        = "asia-southeast1"
  network       = google_compute_network.vpc_network.id

  depends_on = [google_project_service.gcp_services["compute.googleapis.com"]]
}

# GKE Cluster
resource "google_container_cluster" "gke_cluster" {
  name     = "yolo-bytetrack-cluster"
  location = "asia-southeast1"
  node_locations = ["asia-southeast1-c"]
  deletion_protection = false

  network    = google_compute_network.vpc_network.name
  subnetwork = google_compute_subnetwork.nodes_subnetwork.name

  enable_l4_ilb_subsetting = true
  remove_default_node_pool = true
  initial_node_count       = 1

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
  }
}

# Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "${google_container_cluster.gke_cluster.name}-pool"
  location   = google_container_cluster.gke_cluster.location
  cluster    = google_container_cluster.gke_cluster.name
  node_count = 1

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  autoscaling {
    min_node_count = 0
    max_node_count = 1
  }

  node_config {
    machine_type = "n2-standard-4"
    disk_size_gb = 50
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }
}


# Kubernetes Deployments
resource "kubernetes_deployment" "yolo_deployment" {
  metadata {
    name = "yolo"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "yolo"
      }
    }

    template {
      metadata {
        labels = {
          app = "yolo"
        }
      }

      spec {
        container {
          image = "${var.region}-docker.pkg.dev/${var.project_id}/yolo/yolo-image:latest"
          name  = "yolo"

          port {
            container_port = 5000
          }
        }
      }
    }
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

resource "kubernetes_deployment" "bytetrack_deployment" {
  metadata {
    name = "bytetrack"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "bytetrack"
      }
    }

    template {
      metadata {
        labels = {
          app = "bytetrack"
        }
      }

      spec {
        container {
          image = "${var.region}-docker.pkg.dev/${var.project_id}/bytetrack/bytetrack-image:latest"
          name  = "bytetrack"

          port {
            container_port = 5001
          }
        }
      }
    }
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

# Kubernetes Services
resource "kubernetes_service" "yolo_service" {
  metadata {
    name = "yolo-svc"
    annotations = {
      "networking.gke.io/load-balancer-type" = "Internal"
    }
  }

  spec {
    selector = {
      app = "yolo"
    }

    port {
      port        = 80
      target_port = 5000
    }

    type = "LoadBalancer"
    external_traffic_policy = "Cluster"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

resource "kubernetes_service" "bytetrack_service" {
  metadata {
    name = "bytetrack-svc"
    annotations = {
      "networking.gke.io/load-balancer-type" = "Internal"
    }
  }

  spec {
    selector = {
      app = "bytetrack"
    }

    port {
      port        = 80
      target_port = 5001
    }

    type = "LoadBalancer"
    external_traffic_policy = "Cluster"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}