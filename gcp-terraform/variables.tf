data "google_project" "project" {
}

variable "project_id" {
  description = "Enter your Google Cloud project ID"
}

variable "region" {
  description = "The default region for resources"
  default     = "asia-southeast1"
}

variable "gcp_service_list" {
  description = "The list of APIs necessary for the project"
  type        = list(string)
  default = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "container.googleapis.com",
    "bigquery.googleapis.com",
    "storage-api.googleapis.com",
    "cloudtasks.googleapis.com",
    "eventarc.googleapis.com",
    "apigateway.googleapis.com",
    "apikeys.googleapis.com",
    "pubsub.googleapis.com",
    "servicecontrol.googleapis.com",
    "servicemanagement.googleapis.com",
    "workflows.googleapis.com",
    "workflowexecutions.googleapis.com",
    "compute.googleapis.com"
  ]
}

variable "storage_bucket_name" {
  description = "Name of the GCS bucket"
  default     = "yolo-tracking-service-bucket"
}

variable "upload_bucket_name" {
  description = "Name of the GCS bucket for video upload"
  default     = "upload-video-bucket"
}