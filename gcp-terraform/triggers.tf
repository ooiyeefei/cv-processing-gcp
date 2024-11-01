# Processing DLQ topic
resource "google_pubsub_topic" "processing_dlq" {
  name = "tracking-service-dlq-topic"
}

resource "google_pubsub_subscription" "processing_dlq_subscription" {
  name  = "processing-dlq-subscription"
  topic = google_pubsub_topic.processing_dlq.id
}

# Eventarc for upload trigger
resource "google_eventarc_trigger" "eventarc_upload_trigger" {
  name            = "upload-workflow-trigger"
  service_account = google_service_account.tracking_service_sa.email
  project = var.project_id
  location = var.region
  destination {
    workflow = google_workflows_workflow.video_processing_workflow.id
  }

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.upload_bucket.name
  }

  depends_on = [
    google_workflows_workflow.video_processing_workflow
  ]
}

# Workflow to manage video processing
resource "google_workflows_workflow" "video_processing_workflow" {
  name          = "wait-10-tracking-service"
  region        = var.region
  description   = "Workflow to manage entire video processing pipeline"
  service_account = google_service_account.tracking_service_sa.email
  call_log_level = "LOG_ERRORS_ONLY"

  user_env_vars = {
    output_bucket = "${google_storage_bucket.tracking_bucket.name}",
    video_split_job_name = "${google_cloud_run_v2_job.video_split_job.name}",
    segment_duration = "3",
    tracking_job_name = "${google_cloud_run_v2_job.tracking_job.name}",
    video_merge_job_name = "${google_cloud_run_v2_job.video_merge_job.name}",
    bigquery_function_url = "${google_cloudfunctions2_function.bigquery_upload.url}"
  }

  source_contents = <<-EOF
  # Note: $$ is needed for Terraform or it will cause errors.
main:
  params: [event]
  steps:
    - init:
        assign:
          - project_id: $${sys.get_env("GOOGLE_CLOUD_PROJECT_ID")}
          - curr_obj_upload_time: $${event.data.timeCreated}
          - input_bucket_name: $${event.data.bucket}
          - output_bucket_name: $${sys.get_env("output_bucket")}
          - object_name: $${event.data.name}
          - video_split_job_name: $${sys.get_env("video_split_job_name")}
          - segment_duration: $${sys.get_env("segment_duration")}
          - tracking_job_name: $${sys.get_env("tracking_job_name")}
          - video_merge_job_name: $${sys.get_env("video_merge_job_name")}
          - job_location: asia-southeast1
          - bigquery_function_url: $${sys.get_env("bigquery_function_url")}
          - request_id: $${"req_" + text.replace_all(text.substring(event.data.etag, 0, 8), "/", "") + "_" + text.replace_all(text.replace_all(text.substring(event.data.timeCreated, 0, 19), "-", ""), ":", "")}

    - log_request_id:
        call: sys.log
        args:
          text: '$${"Generated request_id: " + request_id}'
          severity: INFO

    - wait_10_minutes:
        call: sys.sleep
        args:
          seconds: 600  # 5s for testing purpose, change to 10 minutes after

    - check_for_new_uploads:
        call: check_new_uploads
        args:
          input_bucket_name: $${input_bucket_name}
          curr_obj_upload_time: $${curr_obj_upload_time}
          object_name: $${object_name}
        result: new_object_count

    - decide:
        switch:
          - condition: '$${new_object_count > 0}'
            next: log_and_end
          - condition: '$${new_object_count == 0}'
            next: trigger_video_splitting

    - log_and_end:
        call: sys.log
        args:
          text: '$${"New uploads detected within 10 minutes: " + string(new_object_count)}'
          severity: "INFO"
        next: end

    - trigger_video_splitting:
        try:
          call: googleapis.run.v1.namespaces.jobs.run
          args:
            name: $${"namespaces/" + project_id + "/jobs/" + video_split_job_name}
            location: $${job_location}
            body:
              overrides:
                containerOverrides:
                  - env:
                      - name: INPUT_BUCKET
                        value: $${input_bucket_name}
                      - name: INPUT_VIDEO
                        value: $${object_name}
                      - name: REQUEST_ID
                        value: $${request_id}
          result: splitting_result
        except:
          as: e
          steps:
            - log_error_trigger_split:
                call: sys.log
                args:
                  text: '$${"Error in trigger_video_splitting: " + json.encode_to_string(e)}'
                  severity: ERROR
            - return_error_trigger_split:
                return: '$${"Error in trigger_video_splitting: " + json.encode_to_string(e)}'

    - log_splitting_result:
        call: sys.log
        args:
          text: '$${"Video splitting result: " + json.encode_to_string(splitting_result)}'
          severity: INFO
    
    - log_variables:
        call: sys.log
        args:
          text: '$${"output_bucket_name: " + string(output_bucket_name) + ", request_id: " + string(request_id)}'
          severity: INFO

    - list_bucket_contents:
        try:
          call: googleapis.storage.v1.objects.list
          args:
            bucket: tracking-service-bucket
            prefix: $${request_id + "/"}
          result: bucket_contents
        except:
          as: e
          steps:
            - log_list_error:
                call: sys.log
                args:
                  text: '$${"Error listing bucket contents: " + json.encode_to_string(e)}'
                  severity: ERROR
            - assign_empty_contents:
                assign:
                  - bucket_contents: {"items": []}

    - log_bucket_contents:
        try:
          call: sys.log
          args:
            text: '$${"Bucket contents: " + json.encode_to_string(bucket_contents)}'
            severity: INFO
        except:
          as: e
          steps:
            - log_encoding_error:
                call: sys.log
                args:
                  text: '$${"Error encoding bucket contents: " + json.encode_to_string(e)}'
                  severity: ERROR

    - log_manifest_path:
        try:
          call: sys.log
          args:
            text: '$${"Attempting to access manifest at: " + output_bucket_name + "/" + request_id + "/manifest.json"}'
            severity: INFO
        except:
          as: e
          steps:
            - log_path_error:
                call: sys.log
                args:
                  text: '$${"Error logging manifest path: " + json.encode_to_string(e)}'
                  severity: ERROR

    - get_manifest:
        try:
          call: googleapis.storage.v1.objects.get
          args:
            bucket: $${output_bucket_name}
            object: $${text.url_encode(request_id + "/manifest.json")}
            alt: "media"
          result: manifest_content
        except:
          as: e
          steps:
            - log_manifest_error:
                call: sys.log
                args:
                  text: '$${"Error getting manifest: " + json.encode_to_string(e)}'
                  severity: ERROR
            - return_error:
                return: "Failed to retrieve manifest"

    - log_manifest_content:
        call: sys.log
        args:
          text: '$${"Manifest content: " + json.encode_to_string(manifest_content)}'
          severity: INFO

    - init_tracking_jobs:
        assign:
          - tracking_job_results: []

    - parallel_inferencing:
        parallel:
          shared: [ tracking_job_results ]
          branches:
            - process_video_chunks:
                steps:
                    - trigger_tracking_jobs:
                        call: run_tracking_jobs
                        args:
                          project_id: $${project_id}
                          job_location: $${job_location}
                          tracking_job_name: $${tracking_job_name}
                          output_bucket_name: $${output_bucket_name}
                          request_id: $${request_id}
                          manifest: $${manifest_content}
                        result: tracking_job_results
            - check_tracking_jobs_status:
                steps:
                    - wait_for_tracking_jobs:
                        call: check_job_status
                        args:
                          job_results: $${tracking_job_results}
                          project_id: $${project_id}
                          job_location: $${job_location}
                          tracking_job_name: $${tracking_job_name}
                        result: all_jobs_completed

    - parallel_processing:
        parallel:
          branches:
            - video_merge:
                steps:
                    - trigger_video_merge:
                        call: googleapis.run.v1.namespaces.jobs.run
                        args:
                          name: $${"namespaces/" + project_id + "/jobs/" + video_merge_job_name}
                          location: $${job_location}
                          body:
                            overrides:
                              containerOverrides:
                                - env:
                                    - name: INPUT_BUCKET
                                      value: $${output_bucket_name}
                                    - name: REQUEST_ID
                                      value: $${request_id}
                        result: merge_job_result
                    - log_merge_result:
                        call: sys.log
                        args:
                          text: '$${"Video merge job result: " + json.encode_to_string(merge_job_result)}'
                          severity: INFO
            - write_to_bq:
                steps:
                    - call_bigquery_function:
                        call: http.post
                        args:
                          url: $${bigquery_function_url}
                          auth:
                            type: OIDC
                          body:
                            request_id: $${request_id}
                        result: bigquery_function_result
                    - log_bq_write_result:
                        call: sys.log
                        args:
                          text: '$${"BigQuery function result: " + json.encode_to_string(bigquery_function_result)}'
                          severity: INFO

    - complete:
        call: sys.log
        args:
            text: "Workflow completed successfully"
            severity: INFO
        next: return_success

    - return_success:
        return: "Workflow completed successfully"

check_new_uploads:
  params: [input_bucket_name, curr_obj_upload_time, object_name]
  steps:
    - list_objects:
        call: googleapis.storage.v1.objects.list
        args:
          bucket: $${input_bucket_name}
          prefix: ""
        result: objects_result

    - filter_new_objects:
        assign:
          - new_objects: []
          - index: 0

    - filter_loop:
        for:
          value: obj
          in: $${objects_result.items}
          steps:
            - parse_obj_time:
                assign:
                  - parsed_obj_time: $${time.parse(obj.timeCreated)}
                  - parsed_curr_time: $${time.parse(curr_obj_upload_time)}
            - check_object:
                switch:
                  - condition: $${parsed_obj_time > parsed_curr_time AND obj.name != object_name}
                    assign:
                      - new_objects: $${list.concat(new_objects, [obj])}
            - increment_index:
                assign:
                  - index: $${index + 1}

    - count_new_objects:
        assign:
          - new_object_count: $${len(new_objects)}

    - return_result:
        return: $${new_object_count}

run_tracking_jobs:
  params: [project_id, job_location, tracking_job_name, output_bucket_name, request_id, manifest]
  steps:
    - init_tracking_jobs:
        assign:
          - tracking_job_results: []

    - run_jobs:
        parallel:
          shared: [ tracking_job_results ]
          for:
            value: chunk
            in: $${manifest.segments}
            steps:
              - run_tracking_job:
                  call: googleapis.run.v1.namespaces.jobs.run
                  args:
                    name: $${"namespaces/" + project_id + "/jobs/" + tracking_job_name}
                    location: $${job_location}
                    body:
                      overrides:
                        containerOverrides:
                          - env:
                              - name: INPUT_BUCKET
                                value: $${output_bucket_name}
                              - name: INPUT_VIDEO
                                value: $${request_id + "/split_chunks/" + chunk.segment_file}
                              - name: INPUT_METADATA
                                value: $${text.replace_all(chunk.segment_file, ".mp4", ".json")}
                              - name: REQUEST_ID
                                value: $${request_id}
                  result: job_result
              - create_job_info:
                  assign:
                    - job_info:
                        name: $${job_result.metadata.name}
                        execution_id: $${job_result.metadata.name}
              - add_to_jobs:
                  assign:
                    - tracking_job_results: '$${list.concat(tracking_job_results, [job_info])}'

    - return_results:
        return: $${tracking_job_results}

check_job_status:
  params: [job_results, project_id, job_location, tracking_job_name]
  steps:
    - init:
        assign:
          - all_completed: false
          - sleep_duration: 10
    - check_status_loop:
        steps:
          - check_jobs:
              call: check_individual_jobs
              args:
                job_results: $${job_results}
                job_location: $${job_location}
                job_name: $${tracking_job_name}
                project_id: $${project_id}
              result: job_statuses
          - log_job_statuses:
              call: sys.log
              args:
                text: '$${"Job statuses: " + json.encode_to_string(job_statuses)}'
                severity: INFO
          - check_if_all_completed:
              assign:
                - completed_count: 0
          - count_completed:
              for:
                value: status_array
                in: $${job_statuses}
                steps:
                  - increment_if_succeeded:
                      switch:
                        - condition: $${status_array[0] == "SUCCEEDED"}
                          assign:
                            - completed_count: $${completed_count + 1}
          - update_all_completed:
              assign:
                - all_completed: $${completed_count == len(job_results)}
          - log_completion:
              call: sys.log
              args:
                text: '$${"Completed count: " + string(completed_count) + ", Total jobs: " + string(len(job_results)) + ", All completed: " + string(all_completed)}'
                severity: INFO
          - sleep_if_not_completed:
              switch:
                - condition: $${not all_completed}
                  steps:
                    - sleep:
                        call: sys.sleep
                        args:
                          seconds: $${sleep_duration}
                    - increase_sleep:
                        assign:
                          - sleep_duration: $${math.min(sleep_duration * 2, 300)}
                  next: check_status_loop
    - return_result:
        return: $${all_completed}

check_individual_jobs:
  params: [job_results, project_id, job_location, job_name]
  steps:
    - log_job_results:
        call: sys.log
        args:
          text: '$${"Job results structure: " + json.encode_to_string(job_results)}'
          severity: INFO
    - init:
        assign:
          - statuses: []
    - check_jobs:
        for:
          value: job_result
          in: $${job_results}
          steps:
            - extract_execution_id:
                assign:
                  - execution_id: $${job_result[0].execution_id}
            - log_execution_id:
                call: sys.log
                args:
                  text: '$${"Extracted execution ID: " + execution_id}'
                  severity: INFO
            - get_job_status:
                try:
                  call: http.get
                  args:
                    url: $${"https://run.googleapis.com/v2/projects/" + project_id + "/locations/" + job_location + "/jobs/" + job_name + "/executions/" + execution_id}
                    auth:
                      type: OAuth2
                  result: job_status
                except:
                  as: e
                  steps:
                    - log_error:
                        call: sys.log
                        args:
                          text: '$${"Error getting job status: " + json.encode_to_string(e)}'
                          severity: ERROR
                    - assign_error_status:
                        assign:
                          - job_status: '{"status": {"conditions": [{"status": "Unknown", "type": "Ready"}]}}'
            - log_job_status:
                call: sys.log
                args:
                  text: '$${"Job status for " + job_result[0].name + ": " + json.encode_to_string(job_status)}'
                  severity: INFO
            - find_completed_condition:
                assign:
                  - completed_condition: null
            - determine_status:
                assign:
                  - current_status: "UNKNOWN" 
            - loop_conditions:
                for:
                  value: condition
                  in: $${job_status.body.conditions}
                  steps:
                    - check_condition:
                        switch:
                          - condition: $${condition.type == "Completed"}
                            steps:
                            - set_status:
                                switch:
                                    - condition: $${condition.state == "CONDITION_SUCCEEDED"}
                                      assign:
                                        - current_status: "SUCCEEDED"
                                    - condition: $${true}
                                      assign:
                                        - current_status: "FAILED"
            - add_status:
                assign:
                - statuses: $${list.concat(statuses, [current_status])}
    - return_statuses:
        return: $${statuses}
EOF

depends_on = [
    google_cloud_run_v2_job.tracking_job
  ]
}