#!/usr/bin/env python3
"""
SIMPLE RABBITMQ LOAD TEST CONSUMER
Rewritten from scratch for maximum simplicity and reliability.

This consumer:
- Uses basic_consume (push model - RECOMMENDED by RabbitMQ)
- Manual acknowledgments for reliability
- Batch acking for better performance
- Matches producer's queue declaration (classic durable)
- Clear progress reporting
- Each worker process has its own connection (pika requirement)
"""

import pika
import time
import os
import sys
import signal
from multiprocessing import Process, Value
from datetime import datetime

# Force unbuffered output for real-time logging
sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)
sys.stderr = os.fdopen(sys.stderr.fileno(), 'w', buffering=1)

# ============================================================================
# CONFIGURATION FROM ENVIRONMENT
# ============================================================================

# RabbitMQ connection details
RABBITMQ_HOSTS = os.getenv('RABBITMQ_HOSTS', 'localhost').split(',')
RABBITMQ_PORT = int(os.getenv('RABBITMQ_PORT', '5672'))
RABBITMQ_USER = os.getenv('RABBITMQ_ADMIN_USER', 'guest')
RABBITMQ_PASSWORD = os.getenv('RABBITMQ_ADMIN_PASSWORD', 'guest')
QUEUE_NAME = os.getenv('TEST_QUEUE_NAME', 'simple_load_test_queue')

# Test parameters
TEST_DURATION_SECONDS = int(os.getenv('TEST_DURATION_SECONDS', '60'))
CONSUMER_WORKERS = int(os.getenv('CONSUMER_WORKERS', '4'))
CONSUMER_CONNECTIONS_PER_WORKER = int(os.getenv('CONSUMER_CONNECTIONS_PER_WORKER', '5'))
PREFETCH_COUNT = int(os.getenv('CONSUMER_PREFETCH_COUNT', '100'))

# Batch acking for better performance (ack every N messages)
BATCH_ACK_SIZE = 100


# ============================================================================
# WORKER FUNCTION - Each runs in separate process
# ============================================================================

def consumer_worker(worker_id, stop_flag):
    """
    Consumer worker process - creates own connection and consumes messages.

    Args:
        worker_id: Unique ID for this worker (0, 1, 2, ...)
        stop_flag: Shared flag to signal graceful shutdown
    """

    # Statistics
    messages_received = 0
    messages_acked = 0
    bytes_received = 0
    errors = 0

    # For batch acking
    last_delivery_tag = None
    messages_since_last_ack = 0

    connection = None
    channel = None

    try:
        # Calculate total workers (each creates 1 connection)
        TOTAL_WORKERS = CONSUMER_WORKERS * CONSUMER_CONNECTIONS_PER_WORKER

        # Only first worker prints startup info (reduce log spam)
        if worker_id == 0:
            print(f"[Consumer] Starting {TOTAL_WORKERS} connections...")

        # === CONNECT TO RABBITMQ ===

        # Round-robin host selection
        host = RABBITMQ_HOSTS[worker_id % len(RABBITMQ_HOSTS)]

        credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
        parameters = pika.ConnectionParameters(
            host=host,
            port=RABBITMQ_PORT,
            credentials=credentials,
            heartbeat=600,
            blocked_connection_timeout=300
        )

        connection = pika.BlockingConnection(parameters)
        channel = connection.channel()

        # Set QoS (prefetch count)
        # This tells RabbitMQ: "Send me up to N messages before I ack"
        channel.basic_qos(prefetch_count=PREFETCH_COUNT)

        # Declare queue (must match producer)
        channel.queue_declare(queue=QUEUE_NAME, durable=True)

        if worker_id == 0:
            print(f"[Consumer] Connected to RabbitMQ, prefetch: {PREFETCH_COUNT}")

        # === MESSAGE CALLBACK ===

        start_time = time.time()
        last_report_time = start_time

        def on_message(ch, method, properties, body):
            """Callback function called for each message"""
            nonlocal messages_received, messages_acked, bytes_received
            nonlocal last_delivery_tag, messages_since_last_ack
            nonlocal last_report_time, errors

            try:
                messages_received += 1
                bytes_received += len(body)
                last_delivery_tag = method.delivery_tag
                messages_since_last_ack += 1

                # Batch acknowledgment (ack every BATCH_ACK_SIZE messages)
                if messages_since_last_ack >= BATCH_ACK_SIZE:
                    ch.basic_ack(delivery_tag=last_delivery_tag, multiple=True)
                    messages_acked += messages_since_last_ack
                    messages_since_last_ack = 0

                # Progress reports - only from worker 0, every 5000 messages
                if worker_id == 0 and messages_received % 5000 == 0:
                    current_time = time.time()
                    elapsed_total = current_time - start_time
                    overall_rate = messages_received / elapsed_total if elapsed_total > 0 else 0
                    print(f"[Consumer] Progress: {messages_received * TOTAL_WORKERS:,} total received "
                          f"(~{overall_rate * TOTAL_WORKERS:.0f} msg/s)")
                    last_report_time = current_time

            except Exception as e:
                errors += 1
                print(f"[Consumer {worker_id}] ❌ Error processing message: {type(e).__name__}: {e}")

        # === START CONSUMING ===

        channel.basic_consume(
            queue=QUEUE_NAME,
            on_message_callback=on_message,
            auto_ack=False  # Manual acks for reliability
        )

        while not stop_flag.value:
            # Check test duration
            elapsed = time.time() - start_time
            if elapsed >= TEST_DURATION_SECONDS:
                break

            # Process messages for 1 second, then check stop flag
            try:
                connection.process_data_events(time_limit=1.0)
            except Exception as e:
                print(f"[Consumer {worker_id}] ❌ Error in event loop: {type(e).__name__}: {e}")
                time.sleep(0.1)

        # === ACK REMAINING MESSAGES ===

        if messages_since_last_ack > 0 and last_delivery_tag:
            try:
                channel.basic_ack(delivery_tag=last_delivery_tag, multiple=True)
                messages_acked += messages_since_last_ack
            except Exception as e:
                if worker_id == 0:
                    print(f"[Consumer] ❌ Error acking final messages: {e}")

        # === FINAL STATISTICS ===

        total_time = time.time() - start_time
        avg_rate = messages_received / total_time if total_time > 0 else 0
        mb_received = bytes_received / 1024 / 1024

        # Only worker 0 prints summary
        if worker_id == 0:
            total_msgs_estimate = messages_received * TOTAL_WORKERS
            overall_rate = avg_rate * TOTAL_WORKERS
            total_mb = mb_received * TOTAL_WORKERS
            print(f"\n[Consumer] === SUMMARY ===")
            print(f"[Consumer] Total received (all connections): ~{total_msgs_estimate:,}")
            print(f"[Consumer] Total acked: ~{messages_acked * TOTAL_WORKERS:,}")
            print(f"[Consumer] Average rate: {overall_rate:.0f} msg/s")
            print(f"[Consumer] Data received: {total_mb:.1f} MB")
            print(f"[Consumer] Test duration: {total_time:.1f}s")
            if errors > 0:
                print(f"[Consumer] Errors: {errors}")
            print(f"[Consumer] ==================")

    except KeyboardInterrupt:
        if worker_id == 0:
            print(f"\n[Consumer] Interrupted by user")

    except Exception as e:
        print(f"\n[Consumer {worker_id}] ❌ FATAL ERROR: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

    finally:
        # Clean up
        if channel and not channel.is_closed:
            try:
                # Cancel consumption
                channel.cancel()
            except:
                pass

            try:
                channel.close()
            except:
                pass

        if connection and not connection.is_closed:
            try:
                connection.close()
            except:
                pass

        # Only first worker prints shutdown message
        if worker_id == 0:
            print(f"[Consumer] Shutting down...")


# ============================================================================
# MAIN FUNCTION - Spawns worker processes
# ============================================================================

def main():
    """Main function - spawns worker processes and manages them."""

    # Shared stop flag
    stop_flag = Value('i', 0)

    # Signal handler for graceful shutdown
    def signal_handler(signum, frame):
        print("\n\n[Consumer] Stopping (Ctrl+C detected)...")
        stop_flag.value = 1

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Spawn worker processes
    # Total workers = CONSUMER_WORKERS * CONSUMER_CONNECTIONS_PER_WORKER
    # (each process creates 1 connection)
    TOTAL_WORKERS = CONSUMER_WORKERS * CONSUMER_CONNECTIONS_PER_WORKER
    workers = []

    for worker_id in range(TOTAL_WORKERS):
        process = Process(target=consumer_worker, args=(worker_id, stop_flag))
        process.start()
        workers.append(process)
        time.sleep(0.05)  # Stagger startup (shorter delay with more workers)

    print(f"\n✓ {TOTAL_WORKERS} consumer connections started\n")
    print(f"Test will run for {TEST_DURATION_SECONDS} seconds...")
    print("Press Ctrl+C to stop early\n")
    print("=" * 80)
    print()

    # Wait for all workers to finish
    try:
        for worker in workers:
            worker.join()
    except KeyboardInterrupt:
        print("\nWaiting for consumers to shut down...")
        stop_flag.value = 1
        for worker in workers:
            worker.join(timeout=5)
            if worker.is_alive():
                worker.terminate()

    print("\n" + "=" * 80)
    print("CONSUMER TEST COMPLETE")
    print("=" * 80)
    print("(See individual worker statistics above)")
    print()


if __name__ == '__main__':
    main()
