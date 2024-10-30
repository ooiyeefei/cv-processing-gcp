# Cloud Function
resource "google_cloudfunctions2_function" "bigquery_upload" {
  name        = "bigquery-upload"
  location    = var.region
  description = "Function to upload data to BigQuery"

  build_config {
    runtime     = "python311"
    entry_point = "write_to_bigquery"
    source {
      storage_source {
        bucket = google_storage_bucket.bq_upload_function_bucket.name
        object = google_storage_bucket_object.function_code.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = 60
    service_account_email = google_service_account.tracking_service_sa.email
    environment_variables = {
      GCS_BUCKET_NAME = google_storage_bucket.tracking_bucket.name
      PROJECT_ID      = var.project_id
      DATASET_ID      = google_bigquery_dataset.tracking_results.dataset_id
      TABLE_ID        = google_bigquery_table.tracking_results_table.table_id
    }
  }

  depends_on = [
    google_project_service.gcp_services["cloudfunctions.googleapis.com"],
    google_storage_bucket.tracking_bucket,
    google_bigquery_table.tracking_results_table,
    google_storage_bucket.bq_upload_function_bucket
    ]
}

resource "google_storage_bucket" "bq_upload_function_bucket" {
  name                        = "gcf-source-${var.project_id}-${var.region}" # Every bucket name must be globally unique
  location                    = var.region
  uniform_bucket_level_access = true
}

data "archive_file" "bq_upload_function_code" {
  type        = "zip"
  source_dir  = "${path.module}/app/bigquery"
  output_path = "${path.module}/bigquery-upload-function.zip"
}

# Upload function code to bucket
resource "google_storage_bucket_object" "function_code" {
  name   = "bigquery-upload-function.zip"
  bucket = google_storage_bucket.bq_upload_function_bucket.name
  source = data.archive_file.bq_upload_function_code.output_path
  depends_on = [data.archive_file.bq_upload_function_code]
}

# BigQuery Dataset
resource "google_bigquery_dataset" "tracking_results" {
  dataset_id  = "tracking_results"
  project     = var.project_id
  location    = var.region
  description = "Dataset for tracking results"
}

# BigQuery Table
resource "google_bigquery_table" "tracking_results_table" {
  dataset_id = google_bigquery_dataset.tracking_results.dataset_id
  table_id   = "tracking_results_table"
  project    = var.project_id
  deletion_protection = false

  schema = jsonencode([
    {name: "track_id", type: "INTEGER", mode: "NULLABLE"},
    {name: "frame_id", type: "INTEGER", mode: "NULLABLE"},
    {name: "class_name", type: "STRING", mode: "NULLABLE"},
    {name: "class_id", type: "INTEGER", mode: "NULLABLE"},
    {name: "confidence", type: "FLOAT", mode: "NULLABLE"},
    {name: "timestamp", type: "FLOAT", mode: "NULLABLE"},
    {name: "request_id", type: "STRING", mode: "NULLABLE"},
    {name: "box", type: "RECORD", mode: "NULLABLE", fields: [
      {name: "x1", type: "INTEGER", mode: "NULLABLE"},
      {name: "y1", type: "INTEGER", mode: "NULLABLE"},
      {name: "x2", type: "INTEGER", mode: "NULLABLE"},
      {name: "y2", type: "INTEGER", mode: "NULLABLE"}
    ]}
  ])
}