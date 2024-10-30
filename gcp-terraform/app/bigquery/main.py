# Deployed to Cloud function - function triggered by new output.json file uploaded and write to BigQuery
import os
import json
import traceback
import functions_framework
from google.cloud import bigquery
from google.cloud import storage
from google.cloud.exceptions import NotFound
import logging

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# GCS bucket name
GCS_BUCKET_NAME = os.environ.get('GCS_BUCKET_NAME',
                                 'yolo-tracking-service-bucket')

# BigQuery details
PROJECT_ID = os.environ.get('PROJECT_ID')
DATASET_ID = os.environ.get('DATASET_ID', 'tracking_results')
TABLE_ID = os.environ.get('TABLE_ID', 'tracking_results-table')

# Initialize clients
bq_client = bigquery.Client(project=PROJECT_ID)
storage_client = storage.Client()


def download_blob(bucket_name, source_blob_name, destination_file_name):
    try:
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(source_blob_name)
        blob.download_to_filename(destination_file_name)
        logger.info(f"Successfully downloaded blob: {source_blob_name}")
    except Exception as e:
        logger.error(f"Error downloading blob {source_blob_name}: {str(e)}")
        raise


@functions_framework.http
def write_to_bigquery(request):
    try:
        print(request)
        request_json = request.get_json()
        if not request_json or 'request_id' not in request_json:
            logger.error("No request_id provided in the request")
            return 'No request_id provided', 400

        request_id = request_json['request_id']
        logger.info(f"Processing request ID: {request_id}")

        # Download and read manifest.json
        manifest_path = f'/tmp/manifest.json'
        download_blob(GCS_BUCKET_NAME, f"{request_id}/manifest.json",
                      manifest_path)

        with open(manifest_path, 'r') as f:
            manifest_data = json.load(f)

        # Prepare rows for BigQuery insertion
        rows_to_insert = []
        for segment in manifest_data.get('segments', []):
            json_file = segment['segment_file'].replace('.mp4', '.json')
            json_path = f'/tmp/{json_file}'
            download_blob(GCS_BUCKET_NAME,
                          f"{request_id}/processed_chunks/{json_file}",
                          json_path)

            with open(json_path, 'r') as f:
                segment_data = json.load(f)

            for item in segment_data:
                try:
                    box_data = item.get('box', [{}])[0]  # Get the box object
                    row = {
                        'track_id': item.get('track_id'),
                        'frame_id': item.get('frame_id'),
                        'class_name': item.get('class_name'),
                        'class_id': item.get('class_id'),
                        'confidence': item.get('confidence'),
                        'box': {
                            'x1': box_data.get('x1'),
                            'y1': box_data.get('y1'),
                            'x2': box_data.get('x2'),
                            'y2': box_data.get('y2')
                        },
                        'timestamp': item.get('timestamp'),
                        'request_id': item.get('request_id')
                    }
                    # Handle the 'box' field
                    if row['box'] is None:
                        row['box'] = [
                            None, None, None, None
                        ]  # This will be inserted as [null, null, null, null] in JSON
                    rows_to_insert.append(row)

                except Exception as e:
                    logger.error(f"Error processing item: {item}")
                    logger.error(f"Error details: {str(e)}")

            os.remove(json_path)

        if not rows_to_insert:
            logger.warning("No valid data found in processed chunks")
            return

        # Continue with BigQuery insertion if there are valid rows
        # Define the table reference
        table_ref = bq_client.dataset(DATASET_ID).table(TABLE_ID)

        # Check if the table exists, if not create it
        try:
            bq_client.get_table(table_ref)
        except NotFound:
            schema = [
                bigquery.SchemaField("request_id", "STRING", mode="NULLABLE"),
                bigquery.SchemaField("track_id", "INTEGER", mode="NULLABLE"),
                bigquery.SchemaField("frame_id", "INTEGER", mode="NULLABLE"),
                bigquery.SchemaField("class_name", "STRING", mode="NULLABLE"),
                bigquery.SchemaField("class_id", "INTEGER", mode="NULLABLE"),
                bigquery.SchemaField("confidence", "FLOAT", mode="NULLABLE"),
                bigquery.SchemaField("timestamp", "FLOAT", mode="NULLABLE"),
                bigquery.SchemaField("box",
                                     "RECORD",
                                     mode="NULLABLE",
                                     fields=[
                                         bigquery.SchemaField("x1",
                                                              "INTEGER",
                                                              mode="NULLABLE"),
                                         bigquery.SchemaField("y1",
                                                              "INTEGER",
                                                              mode="NULLABLE"),
                                         bigquery.SchemaField("x2",
                                                              "INTEGER",
                                                              mode="NULLABLE"),
                                         bigquery.SchemaField("y2",
                                                              "INTEGER",
                                                              mode="NULLABLE")
                                     ])
            ]
            table = bigquery.Table(table_ref, schema=schema)
            bq_client.create_table(table)
            logger.info(f"Created table {DATASET_ID}.{TABLE_ID}")

        # Load the data
        job_config = bigquery.LoadJobConfig()
        job_config.source_format = bigquery.SourceFormat.NEWLINE_DELIMITED_JSON

        job_config.schema_update_options = [
            bigquery.SchemaUpdateOption.ALLOW_FIELD_ADDITION
        ]
        job_config.ignore_unknown_values = True

        try:
            load_job = bq_client.load_table_from_json(rows_to_insert,
                                                      table_ref,
                                                      job_config=job_config)
            # Wait for the job to complete
            load_job.result()
            logger.info(
                f"Loaded {load_job.output_rows} rows into: {DATASET_ID}.{TABLE_ID}"
            )
            return f"Successfully loaded {load_job.output_rows} rows", 200
        except Exception as e:
            logger.error(f"Error inserting data into BigQuery: {str(e)}")
            logger.error(f"Error details: {traceback.format_exc()}")
            return f"Error inserting data into BigQuery: {str(e)}", 500

    except Exception as e:
        logger.error(f"Unhandled exception: {str(e)}")
        logger.error(f"Traceback: {traceback.format_exc()}")
        return f"Internal Server Error: {str(e)}", 500
