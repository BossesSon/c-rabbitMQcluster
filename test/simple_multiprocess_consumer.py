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
from multiprocessing import Process, Queue, Value
from datetime import datetime

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
    1. Creates multiple connections to RabbitMQ
    2. Receives messages from the queue
    3. Acknowledges messages (tells RabbitMQ they were processed)
    4. Reports statistics back to main process

    Args:
        worker_id: Unique ID for this worker (0, 1, 2, etc.)
        stats_queue: Queue to send statistics back to main process
        stop_flag: Shared flag that tells worker when to stop
    """

    # Statistics counters
    messages_received = 0
    bytes_received = 0
    errors = 0

    # Start time for this worker
    start_time = time.time()
    last_report_time = start_time

    # List to hold all connections and channels
    connections = []
    channels = []

    try:
        # ==================================================================
        # STEP 1: Connect to RabbitMQ (create multiple connections)
        # ==================================================================

        # Create multiple connections for higher throughput
        for conn_id in range(CONNECTIONS_PER_WORKER):
            # Choose which RabbitMQ server to connect to (spread the load)
            host = RABBITMQ_HOSTS[conn_id % len(RABBITMQ_HOSTS)]

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
            connection = pika.BlockingConnection(parameters)
            channel = connection.channel()

            # Set Quality of Service (QoS) - controls prefetch
            # This tells RabbitMQ: "Send me up to PREFETCH_COUNT messages before I ack"
            # Higher prefetch = better throughput, but more messages at risk if consumer crashes
            channel.basic_qos(prefetch_count=PREFETCH_COUNT)

            # Declare the queue (ensures it exists)
            channel.queue_declare(queue=QUEUE_NAME, durable=True)

            connections.append(connection)
            channels.append(channel)

        print(f"[Consumer Worker {worker_id}] Connected with {len(channels)} connections to RabbitMQ")

        # ==================================================================
        # STEP 2: Consume messages
        # ==================================================================

        # We'll use a simple polling approach (repeatedly call basic_get)
        # This is simpler than callbacks and works well for high throughput

        current_channel_index = 0  # Round-robin through channels

        while not stop_flag.value:
            # Check if test duration exceeded
            elapsed = time.time() - start_time
            if elapsed >= TEST_DURATION_SECONDS:
                break

            # Select channel to use (round-robin for load balancing)
            channel = channels[current_channel_index]
            current_channel_index = (current_channel_index + 1) % len(channels)

            try:
                # Try to get a message from the queue
                # auto_ack=False means we'll manually acknowledge (more reliable)
                method_frame, properties, body = channel.basic_get(queue=QUEUE_NAME, auto_ack=False)

                if method_frame:
                    # We received a message!
                    messages_received += 1
                    bytes_received += len(body)

                    # Acknowledge the message (tells RabbitMQ we processed it successfully)
                    channel.basic_ack(delivery_tag=method_frame.delivery_tag)

                else:
                    # Queue is empty, wait a tiny bit before trying again
                    time.sleep(0.001)

            except Exception as e:
                errors += 1
                # Try to reconnect if connection lost
                try:
                    connections[current_channel_index].close()
                except:
                    pass

                # Reconnect
                try:
                    host = RABBITMQ_HOSTS[current_channel_index % len(RABBITMQ_HOSTS)]
                    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
                    parameters = pika.ConnectionParameters(host=host, port=RABBITMQ_PORT, credentials=credentials)
                    connections[current_channel_index] = pika.BlockingConnection(parameters)
                    channels[current_channel_index] = connections[current_channel_index].channel()
                    channels[current_channel_index].basic_qos(prefetch_count=PREFETCH_COUNT)
                except Exception as reconnect_error:
                    print(f"[Consumer Worker {worker_id}] Reconnection failed: {reconnect_error}")

            # Report statistics every second
            if time.time() - last_report_time >= 1.0:
                stats_queue.put({
                    'worker_id': worker_id,
                    'messages_received': messages_received,
                    'bytes_received': bytes_received,
                    'errors': errors
                })
                last_report_time = time.time()

    except Exception as e:
        print(f"[Consumer Worker {worker_id}] Error: {e}")

    finally:
        # ==================================================================
        # STEP 3: Clean up (close all connections)
        # ==================================================================

        for connection in connections:
            try:
                connection.close()
            except:
                pass

        # Send final statistics
        stats_queue.put({
            'worker_id': worker_id,
            'messages_received': messages_received,
            'bytes_received': bytes_received,
            'errors': errors,
            'final': True
        })

        print(f"[Consumer Worker {worker_id}] Finished: {messages_received} messages received, {errors} errors")


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
