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
        print(f"[Consumer {worker_id}] Starting...")

        # === CONNECT TO RABBITMQ ===

        # Round-robin host selection
        host = RABBITMQ_HOSTS[worker_id % len(RABBITMQ_HOSTS)]

        print(f"[Consumer {worker_id}] Connecting to {host}:{RABBITMQ_PORT}...")

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

        print(f"[Consumer {worker_id}] ✓ Connected successfully")
        print(f"[Consumer {worker_id}] ✓ Queue '{QUEUE_NAME}' ready")
        print(f"[Consumer {worker_id}] ✓ Prefetch count: {PREFETCH_COUNT}")

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

                # Progress reports
                if messages_received == 1:
                    print(f"[Consumer {worker_id}] ✓ First message received")

                if messages_received % 1000 == 0:
                    current_time = time.time()
                    elapsed_since_report = current_time - last_report_time
                    current_rate = 1000 / elapsed_since_report if elapsed_since_report > 0 else 0
                    mb_received = bytes_received / 1024 / 1024
                    print(f"[Consumer {worker_id}] Milestone: {messages_received:,} received, "
                          f"{messages_acked:,} acked - Rate: {current_rate:.0f} msg/s - "
                          f"Data: {mb_received:.1f} MB")
                    last_report_time = current_time

            except Exception as e:
                errors += 1
                print(f"[Consumer {worker_id}] ❌ Error processing message: {type(e).__name__}: {e}")

        # === START CONSUMING ===

        print(f"[Consumer {worker_id}] Starting consumption...\n")

        channel.basic_consume(
            queue=QUEUE_NAME,
            on_message_callback=on_message,
            auto_ack=False  # Manual acks for reliability
        )

        # Consume with timeout checks
        print(f"[Consumer {worker_id}] Consuming messages for {TEST_DURATION_SECONDS} seconds...\n")

        while not stop_flag.value:
            # Check test duration
            elapsed = time.time() - start_time
            if elapsed >= TEST_DURATION_SECONDS:
                print(f"[Consumer {worker_id}] Test duration reached, stopping...")
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
                print(f"[Consumer {worker_id}] ✓ Acked final {messages_since_last_ack} messages")
            except Exception as e:
                print(f"[Consumer {worker_id}] ❌ Error acking final messages: {e}")

        # === FINAL STATISTICS ===

        total_time = time.time() - start_time
        avg_rate = messages_received / total_time if total_time > 0 else 0
        mb_received = bytes_received / 1024 / 1024

        print(f"\n[Consumer {worker_id}] === FINAL STATISTICS ===")
        print(f"[Consumer {worker_id}] Messages received: {messages_received:,}")
        print(f"[Consumer {worker_id}] Messages acked:    {messages_acked:,}")
        print(f"[Consumer {worker_id}] Data received:     {mb_received:.2f} MB")
        print(f"[Consumer {worker_id}] Total time:        {total_time:.1f}s")
        print(f"[Consumer {worker_id}] Average rate:      {avg_rate:.0f} msg/s")
        print(f"[Consumer {worker_id}] Errors:            {errors}")

    except KeyboardInterrupt:
        print(f"\n[Consumer {worker_id}] Interrupted by user")

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

        print(f"[Consumer {worker_id}] Shut down cleanly")


# ============================================================================
# MAIN FUNCTION - Spawns worker processes
# ============================================================================

def main():
    """Main function - spawns worker processes and manages them."""

    print("=" * 80)
    print("SIMPLE RABBITMQ LOAD TEST CONSUMER")
    print("=" * 80)
    print(f"Configuration:")
    print(f"  RabbitMQ Hosts:    {', '.join(RABBITMQ_HOSTS)}")
    print(f"  Queue Name:        {QUEUE_NAME}")
    print(f"  Test Duration:     {TEST_DURATION_SECONDS}s")
    print(f"  Worker Processes:  {CONSUMER_WORKERS}")
    print(f"  Prefetch Count:    {PREFETCH_COUNT}")
    print(f"  Batch Ack Size:    {BATCH_ACK_SIZE}")
    print("=" * 80)
    print()

    # Shared stop flag
    stop_flag = Value('i', 0)

    # Signal handler for graceful shutdown
    def signal_handler(signum, frame):
        print("\n\n🛑 Stopping all consumers (Ctrl+C detected)...\n")
        stop_flag.value = 1

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Spawn worker processes
    workers = []
    print(f"Starting {CONSUMER_WORKERS} worker processes...\n")

    for worker_id in range(CONSUMER_WORKERS):
        process = Process(target=consumer_worker, args=(worker_id, stop_flag))
        process.start()
        workers.append(process)
        print(f"  Consumer {worker_id} started (PID: {process.pid})")
        time.sleep(0.1)  # Stagger startup

    print(f"\n✓ All consumers started\n")
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
