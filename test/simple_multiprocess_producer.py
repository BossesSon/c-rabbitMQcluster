#!/usr/bin/env python3
"""
SIMPLE RABBITMQ LOAD TEST PRODUCER
Rewritten from scratch for maximum simplicity and reliability.

This producer:
- Uses classic durable queues (simple, compatible)
- Detects when RabbitMQ blocks connections (memory/disk alarms)
- Uses publisher confirms for reliability
- Has proper rate limiting per worker
- Handles errors gracefully with clear messages
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
MESSAGE_SIZE_BYTES = int(os.getenv('MESSAGE_SIZE_KB', '10')) * 1024
MESSAGES_PER_SECOND = int(os.getenv('MESSAGES_PER_SECOND', '1000'))
TEST_DURATION_SECONDS = int(os.getenv('TEST_DURATION_SECONDS', '60'))
PRODUCER_WORKERS = int(os.getenv('PRODUCER_WORKERS', '4'))
CONNECTIONS_PER_WORKER = int(os.getenv('PRODUCER_CONNECTIONS_PER_WORKER', '5'))


# ============================================================================
# WORKER FUNCTION - Each runs in separate process
# ============================================================================

def producer_worker(worker_id, stop_flag):
    """
    Producer worker process - creates own connection and sends messages.

    Args:
        worker_id: Unique ID for this worker (0, 1, 2, ...)
        stop_flag: Shared flag to signal graceful shutdown
    """

    # Statistics
    messages_sent = 0
    messages_confirmed = 0
    messages_rejected = 0
    connection_blocked_count = 0
    is_currently_blocked = False

    # Track time blocked
    blocked_start_time = None
    total_blocked_time = 0.0

    connection = None
    channel = None

    try:
        print(f"[Worker {worker_id}] Starting...")

        # Calculate this worker's target rate
        worker_target_rate = MESSAGES_PER_SECOND / PRODUCER_WORKERS / CONNECTIONS_PER_WORKER
        delay_per_message = 1.0 / worker_target_rate if worker_target_rate > 0 else 0

        print(f"[Worker {worker_id}] Target: {worker_target_rate:.1f} msg/s per connection")
        print(f"[Worker {worker_id}] Delay: {delay_per_message:.6f}s per message")

        # Create message payload (reuse for efficiency)
        message_body = 'X' * MESSAGE_SIZE_BYTES

        # === CONNECT TO RABBITMQ ===

        # Round-robin host selection
        host = RABBITMQ_HOSTS[worker_id % len(RABBITMQ_HOSTS)]

        print(f"[Worker {worker_id}] Connecting to {host}:{RABBITMQ_PORT}...")

        credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
        parameters = pika.ConnectionParameters(
            host=host,
            port=RABBITMQ_PORT,
            credentials=credentials,
            heartbeat=600,
            blocked_connection_timeout=300
        )

        connection = pika.BlockingConnection(parameters)

        # === CONNECTION BLOCKING CALLBACKS ===
        # These detect when RabbitMQ triggers memory/disk alarms

        def on_connection_blocked(connection, reason):
            nonlocal is_currently_blocked, blocked_start_time, connection_blocked_count
            is_currently_blocked = True
            blocked_start_time = time.time()
            connection_blocked_count += 1
            timestamp = datetime.now().strftime('%H:%M:%S')
            print(f"\n[Worker {worker_id}] ⚠️  BLOCKED at {timestamp}")
            print(f"[Worker {worker_id}]    Reason: {reason}")
            print(f"[Worker {worker_id}]    RabbitMQ has triggered a memory or disk alarm")
            print(f"[Worker {worker_id}]    Messages will not be accepted until alarm clears\n")

        def on_connection_unblocked(connection):
            nonlocal is_currently_blocked, blocked_start_time, total_blocked_time
            if is_currently_blocked and blocked_start_time:
                blocked_duration = time.time() - blocked_start_time
                total_blocked_time += blocked_duration
                timestamp = datetime.now().strftime('%H:%M:%S')
                print(f"\n[Worker {worker_id}] ✓ UNBLOCKED at {timestamp}")
                print(f"[Worker {worker_id}]    Was blocked for {blocked_duration:.1f}s")
                print(f"[Worker {worker_id}]    Total blocked time: {total_blocked_time:.1f}s\n")
            is_currently_blocked = False
            blocked_start_time = None

        connection.add_on_connection_blocked_callback(on_connection_blocked)
        connection.add_on_connection_unblocked_callback(on_connection_unblocked)

        # === CREATE CHANNEL ===

        channel = connection.channel()

        # Enable publisher confirms for reliability
        # This makes basic_publish() return True/False for each message
        channel.confirm_delivery()

        # Declare queue (classic durable queue - simple and reliable)
        channel.queue_declare(queue=QUEUE_NAME, durable=True)

        print(f"[Worker {worker_id}] ✓ Connected successfully")
        print(f"[Worker {worker_id}] ✓ Queue '{QUEUE_NAME}' ready")

        # === SEND MESSAGES ===

        start_time = time.time()
        last_report_time = start_time

        print(f"[Worker {worker_id}] Starting message loop...\n")

        while not stop_flag.value:
            # Check test duration
            elapsed = time.time() - start_time
            if elapsed >= TEST_DURATION_SECONDS:
                break

            # Don't send if currently blocked (connection callback will show warnings)
            if is_currently_blocked:
                time.sleep(0.1)  # Wait for unblock
                continue

            try:
                # Publish message with publisher confirms
                success = channel.basic_publish(
                    exchange='',
                    routing_key=QUEUE_NAME,
                    body=message_body,
                    properties=pika.BasicProperties(
                        delivery_mode=2,  # Persistent
                    ),
                    mandatory=True  # Raise exception if can't route
                )

                messages_sent += 1

                if success:
                    messages_confirmed += 1
                else:
                    messages_rejected += 1
                    print(f"[Worker {worker_id}] ❌ Message #{messages_sent} was REJECTED by RabbitMQ")

                # Progress reports
                if messages_sent == 1:
                    print(f"[Worker {worker_id}] ✓ First message sent successfully")

                if messages_sent % 1000 == 0:
                    current_time = time.time()
                    elapsed_since_report = current_time - last_report_time
                    current_rate = 1000 / elapsed_since_report if elapsed_since_report > 0 else 0
                    print(f"[Worker {worker_id}] Milestone: {messages_sent:,} sent "
                          f"({messages_confirmed:,} confirmed, {messages_rejected} rejected) "
                          f"- Rate: {current_rate:.0f} msg/s")
                    last_report_time = current_time

            except Exception as e:
                print(f"[Worker {worker_id}] ❌ Error publishing: {type(e).__name__}: {e}")
                # Don't flood logs on repeated errors
                time.sleep(0.1)

            # Rate limiting
            if delay_per_message > 0:
                time.sleep(delay_per_message)

        # === FINAL STATISTICS ===

        total_time = time.time() - start_time
        active_time = total_time - total_blocked_time
        avg_rate = messages_confirmed / active_time if active_time > 0 else 0

        print(f"\n[Worker {worker_id}] === FINAL STATISTICS ===")
        print(f"[Worker {worker_id}] Messages sent:      {messages_sent:,}")
        print(f"[Worker {worker_id}] Messages confirmed: {messages_confirmed:,}")
        print(f"[Worker {worker_id}] Messages rejected:  {messages_rejected}")
        print(f"[Worker {worker_id}] Total time:         {total_time:.1f}s")
        print(f"[Worker {worker_id}] Blocked time:       {total_blocked_time:.1f}s ({total_blocked_time/total_time*100:.1f}%)")
        print(f"[Worker {worker_id}] Active time:        {active_time:.1f}s")
        print(f"[Worker {worker_id}] Average rate:       {avg_rate:.0f} msg/s")
        print(f"[Worker {worker_id}] Blocked count:      {connection_blocked_count}")

    except KeyboardInterrupt:
        print(f"\n[Worker {worker_id}] Interrupted by user")

    except Exception as e:
        print(f"\n[Worker {worker_id}] ❌ FATAL ERROR: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

    finally:
        # Clean up
        if channel and not channel.is_closed:
            try:
                channel.close()
            except:
                pass

        if connection and not connection.is_closed:
            try:
                connection.close()
            except:
                pass

        print(f"[Worker {worker_id}] Shut down cleanly")


# ============================================================================
# MAIN FUNCTION - Spawns worker processes
# ============================================================================

def main():
    """Main function - spawns worker processes and manages them."""

    print("=" * 80)
    print("SIMPLE RABBITMQ LOAD TEST PRODUCER")
    print("=" * 80)
    print(f"Configuration:")
    print(f"  RabbitMQ Hosts:    {', '.join(RABBITMQ_HOSTS)}")
    print(f"  Queue Name:        {QUEUE_NAME}")
    print(f"  Target Rate:       {MESSAGES_PER_SECOND:,} msg/s")
    print(f"  Message Size:      {MESSAGE_SIZE_BYTES:,} bytes ({MESSAGE_SIZE_BYTES/1024:.1f} KB)")
    print(f"  Test Duration:     {TEST_DURATION_SECONDS}s")
    print(f"  Worker Processes:  {PRODUCER_WORKERS}")
    print(f"  Connections/Worker: {CONNECTIONS_PER_WORKER}")
    print(f"  Total Connections: {PRODUCER_WORKERS * CONNECTIONS_PER_WORKER}")
    print("=" * 80)
    print()

    # Shared stop flag
    stop_flag = Value('i', 0)

    # Signal handler for graceful shutdown
    def signal_handler(signum, frame):
        print("\n\n🛑 Stopping all workers (Ctrl+C detected)...\n")
        stop_flag.value = 1

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Spawn worker processes
    workers = []
    print(f"Starting {PRODUCER_WORKERS} worker processes...\n")

    for worker_id in range(PRODUCER_WORKERS):
        process = Process(target=producer_worker, args=(worker_id, stop_flag))
        process.start()
        workers.append(process)
        print(f"  Worker {worker_id} started (PID: {process.pid})")
        time.sleep(0.1)  # Stagger startup

    print(f"\n✓ All workers started\n")
    print(f"Test will run for {TEST_DURATION_SECONDS} seconds...")
    print("Press Ctrl+C to stop early\n")
    print("=" * 80)
    print()

    # Wait for all workers to finish
    try:
        for worker in workers:
            worker.join()
    except KeyboardInterrupt:
        print("\nWaiting for workers to shut down...")
        stop_flag.value = 1
        for worker in workers:
            worker.join(timeout=5)
            if worker.is_alive():
                worker.terminate()

    print("\n" + "=" * 80)
    print("PRODUCER TEST COMPLETE")
    print("=" * 80)
    print("(See individual worker statistics above)")
    print()


if __name__ == '__main__':
    main()
