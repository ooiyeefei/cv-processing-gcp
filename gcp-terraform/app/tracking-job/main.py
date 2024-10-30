# Main tracking service with cloud hosting
import cv2
import requests
import json
import os
from datetime import datetime
import uuid
from google.cloud import storage

# Environment variables set by the Cloud Run job
INPUT_BUCKET = os.environ.get('INPUT_BUCKET')
INPUT_VIDEO = os.environ.get('INPUT_VIDEO')
INPUT_METADATA = os.environ.get('INPUT_METADATA')
REQUEST_ID = os.environ.get('REQUEST_ID')

# output bucket
GCS_BUCKET_NAME = os.environ.get('GCS_BUCKET_NAME')

# Service endpoints
YOLO_SERVICE_ENDPOINT = os.environ['YOLO_SERVICE_ENDPOINT']
BYTETRACK_SERVICE_ENDPOINT = os.environ['BYTETRACK_SERVICE_ENDPOINT']

# Temporary file paths
TEMP_INPUT_VIDEO = '/tmp/input.mp4'
TEMP_OUTPUT_VIDEO = '/tmp/output.mp4'
TEMP_OUTPUT_JSON = '/tmp/output.json'


def download_from_gcs(bucket_name, source_blob_name, destination_file_name):
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(source_blob_name)
    blob.download_to_filename(destination_file_name)
    print(f"Downloaded {source_blob_name} to {destination_file_name}")


def upload_to_gcs(bucket_name, source_file_name, destination_blob_name):
    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(destination_blob_name)
    blob.upload_from_filename(source_file_name)
    print(f"Uploaded {source_file_name} to {destination_blob_name}")


def read_metadata():
    with open('/tmp/metadata.json', 'r') as f:
        return json.load(f)


def annotate_video(input_video_path, final_results):
    """
    Annotate the input video with detection and tracking results.

    Args:
        input_video_url (str): URL of the input video
        final_results (list): List of detection and tracking results

    Returns:
        tuple: A message and status code
    """
    if not os.path.exists(input_video_path):
        raise Exception(f"Input video file not found: {input_video_path}")

    # Initialize video capture and writer
    cap = cv2.VideoCapture(input_video_path)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = int(cap.get(cv2.CAP_PROP_FPS))
    output_video = cv2.VideoWriter(TEMP_OUTPUT_VIDEO,
                                   cv2.VideoWriter_fourcc(*'mp4v'), fps,
                                   (width, height))

    # Group final_results by frame_id for efficient processing
    results_by_frame = {}
    for result in final_results:
        frame_id = result.get('frame_id')
        if frame_id not in results_by_frame:
            results_by_frame[frame_id] = []
        results_by_frame[frame_id].append(result)

    frame_count = 0
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break

        # Filter results for the current frame
        frame_results = [
            result for result in final_results
            if result.get('frame_id') == frame_count
        ]

        # Get the full shape of the frame
        height, width, channels = frame.shape

        # Process detection and tracking results for current frame
        frame_results = results_by_frame.get(frame_count, [])
        for final_result in frame_results:
            # Extract and validate result data
            track_id = final_result.get('track_id')
            if track_id is None:
                continue
            box = final_result.get('box')
            confidence = final_result.get('confidence')
            class_name = final_result.get('class_name')

            # Check if box is in the new format and not empty
            if box and isinstance(box, list) and len(box) > 0 and isinstance(
                    box[0], dict):
                # Extract coordinates from the new format
                x1 = box[0].get('x1')
                y1 = box[0].get('y1')
                x2 = box[0].get('x2')
                y2 = box[0].get('y2')
            else:
                # Handle case where box is not in the expected format
                print(f"Unexpected box format for track_id {track_id}: {box}")
                continue

            # Ensure all coordinates are integers and not None
            if all(coord is not None for coord in [x1, y1, x2, y2]):
                x1, y1, x2, y2 = map(int, [x1, y1, x2, y2])
            else:
                print(f"Invalid coordinates for track_id {track_id}: {box}")
                continue

            # Draw bounding boxes and labels on the frame
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
            label = f"#{track_id} {class_name} {confidence:.2f}"
            cv2.putText(frame, label, (x1, y1 - 10), cv2.FONT_HERSHEY_SIMPLEX,
                        0.5, (0, 0, 0), 2)

        # Write the annotated frame to output video
        output_video.write(frame)
        frame_count += 1

    # Release resources
    cap.release()
    output_video.release()

    return "Complete annotation", 200


def process_video():
    """
    Handle request triggered by Cloud Workflow
    """
    request_data = {
        "request_id": REQUEST_ID,
        "bucket_name": INPUT_BUCKET,
        "object_name": INPUT_VIDEO,
        "metadata_file": INPUT_METADATA
    }

    try:
        print(f"Processing video: {INPUT_VIDEO}")

        # Step 1: Send video to YOLO service for detection
        yolo_response = requests.post(f"{YOLO_SERVICE_ENDPOINT}/detect",
                                      json=request_data)
        yolo_response.raise_for_status()
        detection_results = yolo_response.json()

        # Step 2: Send YOLO results to Bytetrack service for tracking
        bytetrack_response = requests.post(
            f"{BYTETRACK_SERVICE_ENDPOINT}/track", json=detection_results)
        bytetrack_response.raise_for_status()
        final_results = bytetrack_response.json()

        # Save final results to JSON file
        with open(TEMP_OUTPUT_JSON, 'w') as f:
            json.dump(final_results, f, indent=2)

        # Download input video from GCS
        download_from_gcs(INPUT_BUCKET, INPUT_VIDEO, TEMP_INPUT_VIDEO)

        # Step 3: Annotate video with final results
        try:
            annotate_video(TEMP_INPUT_VIDEO, final_results)
            print(f"Request ID #{REQUEST_ID} Processing complete...\
Output to be uploaded to GCS bucket.")
        except Exception as e:
            print(f"Error in annotate_video: {str(e)}")
            return json.dumps({'error':
                               f'Error annotating video: {str(e)}'}), 500

        # 4th: Upload outputs to GCS
        output_video_path = INPUT_VIDEO.replace('split_chunks',
                                                'processed_chunks')
        output_json_path = output_video_path.rsplit('.', 1)[0] + '.json'

        upload_to_gcs(GCS_BUCKET_NAME, TEMP_OUTPUT_VIDEO, output_video_path)
        upload_to_gcs(GCS_BUCKET_NAME, TEMP_OUTPUT_JSON, output_json_path)

        print(
            f"Processing complete. Output video stored in GCS bucket: {GCS_BUCKET_NAME}/{output_video_path}/"
        )
        return f"Processing complete. Output json stored in GCS bucket: {GCS_BUCKET_NAME}/{output_json_path}/"

    except Exception as e:
        error_message = f"Error processing video: {str(e)}"
        print(error_message)
        return error_message

    finally:
        # Clean up temporary files
        if os.path.exists(TEMP_INPUT_VIDEO):
            os.remove(TEMP_INPUT_VIDEO)
        if os.path.exists(TEMP_OUTPUT_VIDEO):
            os.remove(TEMP_OUTPUT_VIDEO)
        if os.path.exists(TEMP_OUTPUT_JSON):
            os.remove(TEMP_OUTPUT_JSON)


if __name__ == "__main__":
    result = process_video()
    print(result)
