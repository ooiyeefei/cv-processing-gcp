output "output_bucket_name" {
  value = google_storage_bucket.tracking_bucket.name
}

output "upload_bucket_name" {
  value = google_storage_bucket.upload_bucket.name
}

output "yolo_repo_uri" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.yolo_repo.name}"
}

output "bytetrack_repo_uri" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.bytetrack_repo.name}"
}

output "tracking_job_repo_uri" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.tracking_job_repo.name}"
}