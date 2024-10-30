# Enable necessary default APIs
resource "google_project_service" "gcp_services" {
  for_each = toset(var.gcp_service_list)
  project  = var.project_id
  service  = each.key

  disable_on_destroy = false
}

resource "google_project_iam_audit_config" "all-services" {
  project = var.project_id
  service = "allServices"
  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# Artifact Registry Repositories
resource "google_artifact_registry_repository" "video_split_job_repo" {
  repository_id = "video-split-job"
  format = "DOCKER"
  project = var.project_id
  location      = var.region

  depends_on = [google_project_service.gcp_services["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository" "video_merge_job_repo" {
  repository_id = "video-merge-job"
  format = "DOCKER"
  project = var.project_id
  location      = var.region

  depends_on = [google_project_service.gcp_services["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository" "tracking_job_repo" {
  repository_id = "tracking-job"
  format = "DOCKER"
  project = var.project_id
  location      = var.region

  depends_on = [google_project_service.gcp_services["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository" "yolo_repo" {
  repository_id = "yolo"
  format = "DOCKER"
  project = var.project_id
  location = var.region

  depends_on = [google_project_service.gcp_services["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository" "bytetrack_repo" {
  repository_id = "bytetrack"
  format = "DOCKER"
  project = var.project_id
  location = var.region

  depends_on = [google_project_service.gcp_services["artifactregistry.googleapis.com"]]
}

# Cloud Storage Bucket
resource "google_storage_bucket" "tracking_bucket" {
  name     = "${var.storage_bucket_name}-${var.project_id}"
  location = var.region
  project = var.project_id

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy = true
}

resource "google_storage_bucket" "upload_bucket" {
  name     = "${var.upload_bucket_name}-${var.project_id}"
  location = var.region
  project = var.project_id

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy = true
}

# Cloud Run Job - Video Split
resource "google_cloud_run_v2_job" "video_split_job" {
  provider = google-beta
  project = var.project_id
  name     = "video-split-job"
  location = var.region

  template {
    template {
        containers {
          image = "${var.region}-docker.pkg.dev/${var.project_id}/video-split-job/video-split-job-image:latest"

          resources {
            limits = {
              cpu    = "4"
              memory = "2Gi"
            }
          }

          env {
            name  = "INPUT_BUCKET"
            value = google_storage_bucket.upload_bucket.name
          }
          env {
            name  = "OUTPUT_BUCKET"
            value = google_storage_bucket.tracking_bucket.name
          }
        }
        vpc_access {
          network_interfaces {
            network    = google_compute_network.vpc_network.name
            subnetwork = google_compute_subnetwork.nodes_subnetwork.name
          }
        }
        service_account = google_service_account.tracking_service_sa.email
    }
  }

  depends_on = [
    google_artifact_registry_repository.video_split_job_repo
  ]
}

# Cloud Run Job - Tracking
resource "google_cloud_run_v2_job" "tracking_job" {
  provider = google-beta
  project = var.project_id
  name     = "tracking-job"
  location = var.region

  template {
    template {
        containers {
          image = "${var.region}-docker.pkg.dev/${var.project_id}/tracking-job/tracking-job-image:latest"

          resources {
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
          }

          env {
            name  = "YOLO_SERVICE_ENDPOINT"
            value = "http://${kubernetes_service.yolo_service.status[0].load_balancer[0].ingress[0].ip}"
          }
          env {
            name  = "BYTETRACK_SERVICE_ENDPOINT"
            value = "http://${kubernetes_service.bytetrack_service.status[0].load_balancer[0].ingress[0].ip}"
          }
          env {
            name  = "GCS_BUCKET_NAME"
            value = google_storage_bucket.tracking_bucket.name
          }
          env {
            name  = "INPUT_BUCKET"
            value = google_storage_bucket.upload_bucket.name
          }
        }
        vpc_access {
          network_interfaces {
            network    = google_compute_network.vpc_network.name
            subnetwork = google_compute_subnetwork.nodes_subnetwork.name
          }
        }
        service_account = google_service_account.tracking_service_sa.email
    }
  }

  depends_on = [
    google_container_cluster.gke_cluster,
    kubernetes_service.yolo_service,
    kubernetes_service.bytetrack_service,
    google_artifact_registry_repository.tracking_job_repo
  ]
}

# Cloud Run Job - Video Merge
resource "google_cloud_run_v2_job" "video_merge_job" {
  provider = google-beta
  project = var.project_id
  name     = "video-merge-job"
  location = var.region

  template {
    template {
        containers {
          image = "${var.region}-docker.pkg.dev/${var.project_id}/video-merge-job/video-merge-job-image:latest"

          resources {
            limits = {
              cpu    = "4"
              memory = "2Gi"
            }
          }

          env {
            name  = "INPUT_BUCKET"
            value = google_storage_bucket.upload_bucket.name
          }
          env {
            name  = "OUTPUT_BUCKET"
            value = google_storage_bucket.tracking_bucket.name
          }
        }
        vpc_access {
          network_interfaces {
            network    = google_compute_network.vpc_network.name
            subnetwork = google_compute_subnetwork.nodes_subnetwork.name
          }
        }
        service_account = google_service_account.tracking_service_sa.email
    }
  }

  depends_on = [
    google_artifact_registry_repository.video_split_job_repo
  ]
}