import os
import json
import subprocess
from google.cloud import storage

# Environment variables
INPUT_BUCKET = os.environ.get('INPUT_BUCKET')
REQUEST_ID = os.environ.get('REQUEST_ID')
OUTPUT_BUCKET = os.environ.get('OUTPUT_BUCKET', INPUT_BUCKET)

# GCS client
storage_client = storage.Client()


def download_blob(bucket_name, source_blob_name, destination_file_name):
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(source_blob_name)
    blob.download_to_filename(destination_file_name)


def upload_blob(bucket_name, source_file_name, destination_blob_name):
    bucket = storage_client.bucket(bucket_name)
    blob = bucket.blob(destination_blob_name)
    blob.upload_from_filename(source_file_name)


def create_videolist(manifest_data, temp_dir):
    videolist_path = os.path.join(temp_dir, 'videolist.txt')

    # Extract 'segments' from the manifest
    segments = manifest_data.get('segments', [])

    video_files = [
        segment['segment_file'] for segment in segments
        if segment['segment_file'].endswith('.mp4')
    ]
    video_files.sort()  # Ensure correct order

    with open(videolist_path, 'w') as f:
        for video_file in video_files:
            f.write(f"file '{video_file}'\n")

    return videolist_path


def merge_videos():
    print(f"Starting video merge process for request ID: {REQUEST_ID}")

    # Download and read manifest.json
    manifest_path = f'/tmp/manifest.json'
    download_blob(INPUT_BUCKET, f"{REQUEST_ID}/manifest.json", manifest_path)
    with open(manifest_path, 'r') as f:
        manifest_data = json.load(f)

    # Download video chunks
    temp_dir = f'/tmp/{REQUEST_ID}_chunks'
    os.makedirs(temp_dir, exist_ok=True)

    segments = manifest_data.get('segments', [])
    for segment in segments:
        if segment['segment_file'].endswith('.mp4'):
            source_path = f"{REQUEST_ID}/processed_chunks/{segment['segment_file']}"
            dest_path = os.path.join(temp_dir, segment['segment_file'])
            download_blob(INPUT_BUCKET, source_path, dest_path)
            if not os.path.exists(dest_path):
                print(f"Input file not found: {dest_path}")
                return

    # Create videolist.txt
    videolist_path = create_videolist(manifest_data, temp_dir)
    print(f"Created videolist at {videolist_path}")

    # Merge videos
    output_path = f'/tmp/merged_{REQUEST_ID}.mp4'
    ffmpeg_command = [
        'ffmpeg', '-f', 'concat', '-safe', '0', '-i', videolist_path, '-c:v',
        'libx264', '-c:a', 'copy', '-avoid_negative_ts', 'make_zero',
        '-movflags', '+faststart', output_path
    ]

    try:
        result = subprocess.run(ffmpeg_command,
                                check=True,
                                capture_output=True,
                                text=True)
        print("Video merge completed successfully")
        print(f"FFmpeg stdout: {result.stdout}")
        print(f"FFmpeg stderr: {result.stderr}")
    except subprocess.CalledProcessError as e:
        print(f"Error during video merge: {e}")
        print(f"FFmpeg stdout: {e.stdout}")
        print(f"FFmpeg stderr output: {e.stderr}")
        return

    # Upload merged video to GCS
    upload_blob(OUTPUT_BUCKET, output_path, f"{REQUEST_ID}/merged_video.mp4")
    print(
        f"Merged video uploaded to {OUTPUT_BUCKET}/{REQUEST_ID}/merged_video.mp4"
    )

    # Clean up temporary files
    os.remove(videolist_path)
    os.remove(output_path)
    for file in os.listdir(temp_dir):
        os.remove(os.path.join(temp_dir, file))
    os.rmdir(temp_dir)


if __name__ == "__main__":
    merge_videos()
