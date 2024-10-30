# Service Account for Tracking Service
resource "google_service_account" "tracking_service_sa" {
  account_id   = "tracking-service-sa"
  display_name = "Tracking Service SA"
}

# Grant necessary permissions to the Tracking Service SA
resource "google_project_iam_member" "tracking_service_sa_roles" {
  for_each = toset([
    "roles/artifactregistry.createOnPushWriter",
    "roles/bigquery.admin",
    "roles/cloudbuild.builds.builder",
    "roles/cloudfunctions.invoker",
    "roles/run.invoker",
    "roles/run.admin",
    "roles/cloudtasks.enqueuer",
    "roles/eventarc.eventReceiver",
    "roles/logging.logWriter",
    "roles/iam.serviceAccountTokenCreator",
    "roles/storage.objectAdmin",
    "roles/workflows.invoker",
    "roles/pubsub.publisher"    
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.tracking_service_sa.email}"
}

resource "google_storage_bucket_iam_member" "tracking_service_sa_storage_object_creator" {
  bucket = google_storage_bucket.tracking_bucket.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.tracking_service_sa.email}"
}

resource "google_storage_bucket_iam_member" "tracking_service_sa_storage_object_viewer" {
  bucket = google_storage_bucket.tracking_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.tracking_service_sa.email}"
}

resource "google_storage_bucket_iam_member" "tracking_sa_upload_bucket_storage_object_creator" {
  bucket = google_storage_bucket.upload_bucket.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.tracking_service_sa.email}"
}

resource "google_storage_bucket_iam_member" "tracking_sa_upload_bucket_storage_object_viewer" {
  bucket = google_storage_bucket.upload_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.tracking_service_sa.email}"
}

resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.project.number}@gs-project-accounts.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "pubsub_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "pubsub_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}