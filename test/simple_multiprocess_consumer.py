#!/usr/bin/env python3
"""
SIMPLE MULTIPROCESS CONSUMER FOR RABBITMQ LOAD TESTING

PURPOSE:
This script receives messages from RabbitMQ as fast as possible to test the
consumer's capacity. It uses multiple processes and connections to achieve
high throughput (100,000+ messages per second).

FOR BEGINNERS:
- A "consumer" receives and processes messages from RabbitMQ
- "Acknowledgment" (ack) tells RabbitMQ "I received the message successfully"
- "Prefetch" controls how many messages to receive before acknowledging
- More processes + connections = higher throughput

HOW IT WORKS:
1. Main process reads configuration
2. Spawns multiple worker processes
3. Each worker creates multiple connections to RabbitMQ
4. Workers receive messages and acknowledge them
5. Statistics are collected and reported
"""

import pika
import time
import os
import sys
import traceback
from multiprocessing import Process, Queue, Value
from datetime import datetime

# Force unbuffered output
sys.stdout.flush()
sys.stderr.flush()

# ============================================================================
# GLOBAL VARIABLES (loaded from environment)
# ============================================================================

# These come from your simple_load_test.conf file
RABBITMQ_HOSTS = os.getenv('RABBITMQ_HOSTS', 'localhost').split(',')
RABBITMQ_PORT = int(os.getenv('RABBITMQ_PORT', '5672'))
RABBITMQ_USER = os.getenv('RABBITMQ_ADMIN_USER', 'guest')
RABBITMQ_PASSWORD = os.getenv('RABBITMQ_ADMIN_PASSWORD', 'guest')
QUEUE_NAME = os.getenv('TEST_QUEUE_NAME', 'simple_load_test_queue')

# Test parameters
TEST_DURATION_SECONDS = int(os.getenv('TEST_DURATION_SECONDS', '60'))
CONSUMER_WORKERS = int(os.getenv('CONSUMER_WORKERS', '4'))
CONNECTIONS_PER_WORKER = int(os.getenv('CONSUMER_CONNECTIONS_PER_WORKER', '5'))
PREFETCH_COUNT = int(os.getenv('CONSUMER_PREFETCH_COUNT', '200'))

# Flag to stop all workers gracefully
STOP_FLAG = None


# ============================================================================
# WORKER PROCESS FUNCTION
# ============================================================================

def consumer_worker(worker_id, stats_queue, stop_flag):
    """
    This function runs in a separate process. Each worker:
    1. Creates a connection to RabbitMQ
    2. Uses basic_consume (push-based, RECOMMENDED by RabbitMQ)
    3. Receives messages via callback as they arrive
    4. Reports statistics back to main process

    Args:
        worker_id: Unique ID for this worker (0, 1, 2, etc.)
        stats_queue: Queue to send statistics back to main process
        stop_flag: Shared flag that tells worker when to stop
    """

    # Statistics counters (shared with callback via class)
    class Stats:
        def __init__(self):
            self.messages_received = 0
            self.bytes_received = 0
            self.errors = 0
            self.start_time = time.time()
            self.last_report_time = time.time()

    stats = Stats()

    # Callback function called by RabbitMQ when message arrives
    def on_message_callback(ch, method, properties, body):
        """
        This function is called automatically by RabbitMQ when a message arrives.
        This is the RECOMMENDED approach (basic_consume with callback).

        Args:
            ch: Channel
            method: Delivery method (contains delivery_tag for ack)
            properties: Message properties
            body: Message content
        """
        try:
            # Count the message
            stats.messages_received += 1
            stats.bytes_received += len(body)

            # Acknowledge the message (tell RabbitMQ we processed it)
            ch.basic_ack(delivery_tag=method.delivery_tag)

            # Report first few messages for debugging
            if stats.messages_received == 1:
                print(f"[Consumer Worker {worker_id}] SUCCESS! First message received")
                sys.stdout.flush()

            if stats.messages_received == 2:
                print(f"[Consumer Worker {worker_id}] SUCCESS! Second message received (consuming is working!)")
                sys.stdout.flush()

            # Progress report every 10 messages
            if stats.messages_received % 10 == 0:
                print(f"[Consumer Worker {worker_id}] Progress: {stats.messages_received} messages received")
                sys.stdout.flush()

            # Milestone every 1000 messages
            if stats.messages_received % 1000 == 0:
                print(f"[Consumer Worker {worker_id}] MILESTONE: {stats.messages_received} messages received")
                sys.stdout.flush()

            # Report statistics every second
            if time.time() - stats.last_report_time >= 1.0:
                stats_queue.put({
                    'worker_id': worker_id,
                    'messages_received': stats.messages_received,
                    'bytes_received': stats.bytes_received,
                    'errors': stats.errors
                })
                stats.last_report_time = time.time()

        except Exception as e:
            stats.errors += 1
            print(f"[Consumer Worker {worker_id}] ERROR in callback: {e}")
            traceback.print_exc()
            sys.stdout.flush()

    # Connection and channel
    connection = None
    channel = None

    try:
        # ==================================================================
        # STEP 1: Connect to RabbitMQ
        # ==================================================================

        print(f"[Consumer Worker {worker_id}] Starting initialization...")
        sys.stdout.flush()

        # Choose RabbitMQ server (round-robin)
        host = RABBITMQ_HOSTS[worker_id % len(RABBITMQ_HOSTS)]

        # Connection parameters
        credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
        parameters = pika.ConnectionParameters(
            host=host,
            port=RABBITMQ_PORT,
            credentials=credentials,
            heartbeat=600,  # Keep connection alive
            blocked_connection_timeout=300
        )

        # Establish connection
        print(f"[Consumer Worker {worker_id}] Connecting to {host}:{RABBITMQ_PORT}...")
        sys.stdout.flush()

        connection = pika.BlockingConnection(parameters)
        channel = connection.channel()

        # Set Quality of Service (QoS) - controls prefetch
        # This tells RabbitMQ: "Send me up to PREFETCH_COUNT messages before I ack"
        # Higher prefetch = better throughput, but more messages at risk if consumer crashes
        channel.basic_qos(prefetch_count=PREFETCH_COUNT)

        # Declare QUORUM queue (distributed across 3 nodes for HA)
        # Must match producer's queue declaration
        # Quorum queues write to disk first, preventing memory overflow
        channel.queue_declare(
            queue=QUEUE_NAME,
            durable=True,
            arguments={
                'x-queue-type': 'quorum',
                'x-quorum-initial-group-size': 3
            }
        )

        print(f"[Consumer Worker {worker_id}] Connected to RabbitMQ on {host}")
        sys.stdout.flush()

        # ==================================================================
        # STEP 2: Start consuming with basic_consume (RECOMMENDED)
        # ==================================================================

        print(f"[Consumer Worker {worker_id}] Starting basic_consume (push-based consumption)...")
        sys.stdout.flush()

        # Register the callback - RabbitMQ will PUSH messages to us
        # This is the RECOMMENDED approach (not basic_get polling)
        channel.basic_consume(
            queue=QUEUE_NAME,
            on_message_callback=on_message_callback,
            auto_ack=False  # Manual acknowledgment for reliability
        )

        print(f"[Consumer Worker {worker_id}] Consuming messages for {TEST_DURATION_SECONDS} seconds...")
        sys.stdout.flush()

        # Consume messages with timeout
        # We'll check stop_flag and timeout periodically
        while not stop_flag.value:
            # Check if test duration exceeded
            elapsed = time.time() - stats.start_time
            if elapsed >= TEST_DURATION_SECONDS:
                print(f"[Consumer Worker {worker_id}] Test duration reached. Stopping.")
                sys.stdout.flush()
                break

            # Process messages for a short time (allows checking stop_flag)
            connection.process_data_events(time_limit=1.0)

        print(f"[Consumer Worker {worker_id}] Stopping consumption...")
        sys.stdout.flush()

    except Exception as e:
        print(f"[Consumer Worker {worker_id}] FATAL ERROR in main loop: {e}")
        print(f"[Consumer Worker {worker_id}] Full traceback:")
        traceback.print_exc()
        sys.stdout.flush()
        sys.stderr.flush()

    finally:
        # ==================================================================
        # STEP 3: Clean up (close connection)
        # ==================================================================

        if connection:
            try:
                connection.close()
                print(f"[Consumer Worker {worker_id}] Connection closed")
                sys.stdout.flush()
            except Exception as e:
                print(f"[Consumer Worker {worker_id}] Error closing connection: {e}")
                sys.stdout.flush()

        # Send final statistics
        stats_queue.put({
            'worker_id': worker_id,
            'messages_received': stats.messages_received,
            'bytes_received': stats.bytes_received,
            'errors': stats.errors,
            'final': True
        })

        print(f"[Consumer Worker {worker_id}] Finished: {stats.messages_received} messages received, {stats.errors} errors")
        sys.stdout.flush()
        sys.stderr.flush()


# ============================================================================
# MAIN FUNCTION (coordinates all workers)
# ============================================================================

def main():
    """
    Main function that:
    1. Spawns multiple worker processes
    2. Collects statistics from all workers
    3. Prints summary at the end
    """

    global STOP_FLAG

    print("=" * 80)
    print("SIMPLE MULTIPROCESS CONSUMER - STARTING")
    print("=" * 80)
    print(f"Configuration:")
    print(f"  RabbitMQ Hosts: {RABBITMQ_HOSTS}")
    print(f"  Queue: {QUEUE_NAME}")
    print(f"  Duration: {TEST_DURATION_SECONDS} seconds")
    print(f"  Worker Processes: {CONSUMER_WORKERS}")
    print(f"  Connections per Worker: {CONNECTIONS_PER_WORKER}")
    print(f"  Total Connections: {CONSUMER_WORKERS * CONNECTIONS_PER_WORKER}")
    print(f"  Prefetch Count: {PREFETCH_COUNT}")
    print("=" * 80)

    # Create shared stop flag (all workers can see this)
    STOP_FLAG = Value('i', 0)  # 0 = keep running, 1 = stop

    # Queue for collecting statistics from workers
    stats_queue = Queue()

    # List of worker processes
    workers = []

    # Spawn worker processes
    print(f"\nStarting {CONSUMER_WORKERS} worker processes...")
    for worker_id in range(CONSUMER_WORKERS):
        process = Process(target=consumer_worker, args=(worker_id, stats_queue, STOP_FLAG))
        process.start()
        workers.append(process)
        print(f"  Worker {worker_id} started (PID: {process.pid})")

    # Start time
    start_time = time.time()

    print(f"\nConsuming messages for up to {TEST_DURATION_SECONDS} seconds...")
    print("Press Ctrl+C to stop early\n")

    try:
        # Collect stats until all workers finish
        workers_finished = 0
        while workers_finished < CONSUMER_WORKERS:
            try:
                # Get stats from queue (timeout after 1 second)
                stats = stats_queue.get(timeout=1)

                if stats.get('final'):
                    workers_finished += 1

            except:
                # Timeout - no stats received, continue waiting
                pass

    except KeyboardInterrupt:
        print("\n\nStopping consumers (Ctrl+C detected)...")
        STOP_FLAG.value = 1

    # Wait for all workers to finish
    print("\nWaiting for workers to finish...")
    for worker in workers:
        worker.join(timeout=10)
        if worker.is_alive():
            worker.terminate()

    # Calculate final statistics
    elapsed_time = time.time() - start_time

    print("\n" + "=" * 80)
    print("CONSUMER TEST COMPLETE")
    print("=" * 80)
    print(f"Duration: {elapsed_time:.2f} seconds")
    print(f"(Workers have reported their individual statistics above)")
    print("=" * 80)


if __name__ == '__main__':
    main()
