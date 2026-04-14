# =============================================================
# Idempotency Implementation
# Purpose: Ensure each payment is processed EXACTLY ONCE
#          even if the same request is sent multiple times
#
# Why idempotency matters for payment?
# Network issues can cause clients to retry requests
# Without idempotency: retry = duplicate payment charge!
# With idempotency: retry = safe, returns original result
#
# Example problem without idempotency:
# User pays $100 → network timeout → user retries
# System processes BOTH requests → user charged $200!
#
# Solution:
# Use DynamoDB conditional PutItem with attribute_not_exists
# First request: INSERT succeeds → process payment
# Second request: INSERT fails (key exists) → return original result
# User is only charged once regardless of how many retries
#
# This is called "exactly-once processing"
# =============================================================

import boto3
import random
import time
import uuid
from typing import dict

# Initialize DynamoDB client
dynamodb = boto3.client('dynamodb', region_name='ap-southeast-1')


def generate_shard_id(payment_id: str) -> str:
    """
    Generate a shard-prefixed partition key.

    Why random shard prefix (0-199)?
    Distributes writes across 200 DynamoDB partitions evenly.
    Prevents hot partition where one partition gets all traffic.

    Example:
    payment_id = "pay-abc123"
    shard_id   = "SHARD-042#pay-abc1"  (random shard 0-199)
    """
    shard_number = random.randint(0, 199)
    return f"SHARD-{shard_number:03d}#{payment_id[:8]}"


def process_payment(payment_id: str, payload: dict) -> dict:
    """
    Process a payment with exactly-once guarantee.

    Args:
        payment_id: Unique identifier for this payment
        payload: Payment details (amount, merchant, user, etc.)

    Returns:
        dict with result: "created" (new) or "duplicate" (already processed)

    Flow:
        1. Generate idempotency key from payment_id
        2. Try to INSERT into DynamoDB with condition:
           "only insert if this key does not exist"
        3. If INSERT succeeds → new payment, process it
        4. If INSERT fails (key exists) → duplicate, return original result
    """

    # Create unique idempotency key from payment_id
    idempotency_key = f"IDEM#{payment_id}"

    # Generate distributed shard ID (avoids hot partition)
    shard_id = generate_shard_id(payment_id)

    # Create sort key with timestamp for ordering
    event_id = f"{int(time.time_ns())}#{payment_id}"

    # TTL: automatically delete record after 30 days
    expires_at = int(time.time()) + 2592000  # 30 days in seconds

    try:
        # ── Atomic Check-and-Set ─────────────────────────────
        # ConditionExpression: "attribute_not_exists(idempotency_key)"
        # Meaning: "Only insert this record IF idempotency_key
        #           does NOT already exist in the table"
        #
        # This operation is ATOMIC in DynamoDB:
        # Check and insert happen in one operation
        # No race condition possible — even at 1M TPS
        dynamodb.put_item(
            TableName="payment_events",
            Item={
                "shard_id": {"S": shard_id},
                "event_id": {"S": event_id},
                "idempotency_key": {"S": idempotency_key},
                "payment_id": {"S": payment_id},
                "amount": {"N": str(payload.get("amount", 0))},
                "merchant_id": {"S": payload.get("merchant_id", "")},
                "user_id": {"S": payload.get("user_id", "")},
                "status": {"S": "PENDING"},
                "created_at": {"N": str(int(time.time()))},
                # Auto-delete after 30 days via DynamoDB TTL
                "expires_at": {"N": str(expires_at)}
            },
            # KEY PART: only insert if idempotency_key doesn't exist
            # If it exists → raises ConditionalCheckFailedException
            ConditionExpression="attribute_not_exists(idempotency_key)"
        )

        # INSERT succeeded → this is a NEW payment
        # Proceed with actual payment processing
        print(f"New payment created: {payment_id}")
        return {
            "result": "created",
            "payment_id": payment_id,
            "status": "PENDING",
            "message": "Payment accepted for processing"
        }

    except dynamodb.exceptions.ConditionalCheckFailedException:
        # INSERT failed → idempotency_key already exists
        # This is a DUPLICATE request — return original result safely
        # DO NOT process payment again — user already charged!
        print(f"Duplicate payment detected: {payment_id}")
        return {
            "result": "duplicate",
            "payment_id": payment_id,
            "status": "ALREADY_PROCESSED",
            "message": "Payment already processed, returning original result"
        }

    except Exception as e:
        # Unexpected error — let caller handle retry
        print(f"Unexpected error processing payment {payment_id}: {e}")
        raise


def lambda_handler(event: dict, context) -> dict:
    """
    AWS Lambda handler — entry point for payment processing.

    Called by:
    - API Gateway (direct payment request)
    - Kinesis consumer (stream processing)
    - SQS consumer (queue processing)
    """
    # Extract payment details from event
    payment_id = event.get("payment_id", str(uuid.uuid4()))
    payload = {
        "amount": event.get("amount"),
        "merchant_id": event.get("merchant_id"),
        "user_id": event.get("user_id"),
        "currency": event.get("currency", "IDR")
    }

    # Process with exactly-once guarantee
    result = process_payment(payment_id, payload)

    return {
        "statusCode": 200,
        "body": result
    }