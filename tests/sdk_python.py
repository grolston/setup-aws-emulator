"""Exercises the AWS SDK for Python (Boto3) against the emulator.

Relies only on the environment exported by the action; no endpoint or
credentials are configured in code.
"""

import os
import uuid

import boto3


def main() -> None:
    suffix = uuid.uuid4().hex[:8]

    identity = boto3.client("sts").get_caller_identity()
    assert identity["Account"] == "000000000000", identity

    s3 = boto3.client("s3")
    bucket = f"boto3-bucket-{suffix}"
    s3.create_bucket(Bucket=bucket)
    s3.put_object(Bucket=bucket, Key="hello.txt", Body=b"hello")
    body = s3.get_object(Bucket=bucket, Key="hello.txt")["Body"].read()
    assert body == b"hello", body

    sqs = boto3.client("sqs")
    queue_url = sqs.create_queue(QueueName=f"boto3-queue-{suffix}")["QueueUrl"]
    sqs.send_message(QueueUrl=queue_url, MessageBody="ping")
    messages = sqs.receive_message(QueueUrl=queue_url, WaitTimeSeconds=1)["Messages"]
    assert messages[0]["Body"] == "ping", messages

    print(f"Boto3 checks passed against {os.environ['AWS_ENDPOINT_URL']}.")


if __name__ == "__main__":
    main()
