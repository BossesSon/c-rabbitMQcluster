#!/usr/bin/env python3
"""
SIMPLE MULTIPROCESS PRODUCER FOR RABBITMQ LOAD TESTING

PURPOSE:
This script sends messages to RabbitMQ as fast as possible to test the
cluster's capacity. It uses multiple processes and connections to achieve
high throughput (100,000+ messages per second).

FOR BEGINNERS:
- A "process" is like running multiple copies of this program at once
- A "connection" is a network link to RabbitMQ (like a phone line)
- More processes + connections = higher throughput (like more checkout lanes at a store)

HOW IT WORKS:
1. Main process reads configuration
2. Spawns multiple worker processes (uses multiple CPU cores)
3. Each worker creates multiple connections to RabbitMQ
4. Workers send messages at a controlled rate
5. Statistics are collected and reported back to main process
"""

import pika
import time
import os
import sys
import json
import signal
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
RABBITMQ_HOSTS = os.getenv('RABBITMQ_HOSTS', 'localhost').split(',')  # List of RabbitMQ servers
RABBITMQ_PORT = int(os.getenv('RABBITMQ_PORT', '5672'))
RABBITMQ_USER = os.getenv('RABBITMQ_ADMIN_USER', 'guest')
RABBITMQ_PASSWORD = os.getenv('RABBITMQ_ADMIN_PASSWORD', 'guest')
QUEUE_NAME = os.getenv('TEST_QUEUE_NAME', 'simple_load_test_queue')

# Test parameters
MESSAGE_SIZE_BYTES = int(os.getenv('MESSAGE_SIZE_KB', '10')) * 1024  # Convert KB to bytes
MESSAGES_PER_SECOND = int(os.getenv('MESSAGES_PER_SECOND', '10000'))
TEST_DURATION_SECONDS = int(os.getenv('TEST_DURATION_SECONDS', '60'))
PRODUCER_WORKERS = int(os.getenv('PRODUCER_WORKERS', '4'))
CONNECTIONS_PER_WORKER = int(os.getenv('PRODUCER_CONNECTIONS_PER_WORKER', '5'))

# Flag to stop all workers gracefully (when Ctrl+C is pressed)
STOP_FLAG = None


# ============================================================================
# WORKER PROCESS FUNCTION
# ============================================================================

def producer_worker(worker_id, stats_queue, stop_flag):
    """
    This function runs in a separate process. Each worker:
    1. Creates multiple connections to RabbitMQ
    2. Sends messages at its assigned rate
    3. Reports statistics back to the main process

    Args:
        worker_id: Unique ID for this worker (0, 1, 2, etc.)
        stats_queue: Queue to send statistics back to main process
        stop_flag: Shared flag that tells worker when to stop
    """

    # Statistics counters
    messages_sent = 0
    bytes_sent = 0
    errors = 0
    connections = []
    channels = []

    try:
        print(f"[Producer Worker {worker_id}] Starting initialization...")
        sys.stdout.flush()

        # Calculate how many messages THIS worker should send per second
        # Example: If total is 10,000 msg/s and 4 workers, each sends 2,500 msg/s
        worker_target_rate = MESSAGES_PER_SECOND / PRODUCER_WORKERS

        # Calculate delay between messages to achieve target rate
        # Example: 2,500 msg/s means 1 message every 0.0004 seconds
        messages_per_connection = worker_target_rate / CONNECTIONS_PER_WORKER
        delay_between_messages = 1.0 / messages_per_connection if messages_per_connection > 0 else 0

        print(f"[Producer Worker {worker_id}] Target rate: {worker_target_rate:.1f} msg/s, Delay: {delay_between_messages:.6f}s")
        sys.stdout.flush()

        # Create the message payload (random data of specified size)
        # We create it once and reuse it (more efficient than creating each time)
        print(f"[Producer Worker {worker_id}] Creating message body of {MESSAGE_SIZE_BYTES} bytes...")
        sys.stdout.flush()

        message_body = 'X' * MESSAGE_SIZE_BYTES

        print(f"[Producer Worker {worker_id}] Message body created successfully")
        sys.stdout.flush()

    except Exception as e:
        print(f"[Producer Worker {worker_id}] FATAL ERROR during initialization: {e}")
        print(f"[Producer Worker {worker_id}] Full traceback:")
        traceback.print_exc()
        sys.stdout.flush()
        sys.stderr.flush()
        return

    try:
        # ==================================================================
        # STEP 1: Connect to RabbitMQ (create multiple connections)
        # ==================================================================

        # Round-robin through RabbitMQ hosts for load balancing
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

            # Declare the queue (creates it if it doesn't exist)
            # durable=True means queue survives RabbitMQ restart
            channel.queue_declare(queue=QUEUE_NAME, durable=True)

            connections.append(connection)
            channels.append(channel)

        print(f"[Producer Worker {worker_id}] Connected with {len(channels)} connections to RabbitMQ")
        sys.stdout.flush()

        # ==================================================================
        # STEP 2: Send messages at controlled rate
        # ==================================================================

        start_time = time.time()
        last_report_time = start_time
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
                # Publish message to RabbitMQ
                channel.basic_publish(
                    exchange='',  # Default exchange (direct to queue)
                    routing_key=QUEUE_NAME,
                    body=message_body,
                    properties=pika.BasicProperties(
                        delivery_mode=2,  # Make message persistent (saved to disk)
                    )
                )

                messages_sent += 1
                bytes_sent += MESSAGE_SIZE_BYTES

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
                except Exception as reconnect_error:
                    print(f"[Producer Worker {worker_id}] Reconnection failed: {reconnect_error}")

            # Rate limiting: Sleep to maintain target messages per second
            if delay_between_messages > 0:
                time.sleep(delay_between_messages)

            # Report statistics every second
            if time.time() - last_report_time >= 1.0:
                stats_queue.put({
                    'worker_id': worker_id,
                    'messages_sent': messages_sent,
                    'bytes_sent': bytes_sent,
                    'errors': errors
                })
                last_report_time = time.time()

    except Exception as e:
        print(f"[Producer Worker {worker_id}] FATAL ERROR in main loop: {e}")
        print(f"[Producer Worker {worker_id}] Full traceback:")
        traceback.print_exc()
        sys.stdout.flush()
        sys.stderr.flush()

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
            'messages_sent': messages_sent,
            'bytes_sent': bytes_sent,
            'errors': errors,
            'final': True
        })

        print(f"[Producer Worker {worker_id}] Finished: {messages_sent} messages sent, {errors} errors")
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
    print("SIMPLE MULTIPROCESS PRODUCER - STARTING")
    print("=" * 80)
    print(f"Configuration:")
    print(f"  RabbitMQ Hosts: {RABBITMQ_HOSTS}")
    print(f"  Queue: {QUEUE_NAME}")
    print(f"  Target Rate: {MESSAGES_PER_SECOND:,} msg/s")
    print(f"  Message Size: {MESSAGE_SIZE_BYTES:,} bytes ({MESSAGE_SIZE_BYTES/1024:.1f} KB)")
    print(f"  Duration: {TEST_DURATION_SECONDS} seconds")
    print(f"  Worker Processes: {PRODUCER_WORKERS}")
    print(f"  Connections per Worker: {CONNECTIONS_PER_WORKER}")
    print(f"  Total Connections: {PRODUCER_WORKERS * CONNECTIONS_PER_WORKER}")
    print("=" * 80)

    # Create shared stop flag (all workers can see this)
    STOP_FLAG = Value('i', 0)  # 0 = keep running, 1 = stop

    # Queue for collecting statistics from workers
    stats_queue = Queue()

    # List of worker processes
    workers = []

    # Spawn worker processes
    print(f"\nStarting {PRODUCER_WORKERS} worker processes...")
    for worker_id in range(PRODUCER_WORKERS):
        process = Process(target=producer_worker, args=(worker_id, stats_queue, STOP_FLAG))
        process.start()
        workers.append(process)
        print(f"  Worker {worker_id} started (PID: {process.pid})")

    # Collect statistics
    total_messages = 0
    total_bytes = 0
    total_errors = 0
    start_time = time.time()

    print(f"\nTest running for {TEST_DURATION_SECONDS} seconds...")
    print("Press Ctrl+C to stop early\n")

    try:
        # Collect stats until all workers finish
        workers_finished = 0
        while workers_finished < PRODUCER_WORKERS:
            try:
                # Get stats from queue (timeout after 1 second)
                stats = stats_queue.get(timeout=1)

                if stats.get('final'):
                    workers_finished += 1

                # Update totals (these are cumulative from each worker)
                # We'll calculate rate in the final summary

            except:
                # Timeout - no stats received, continue waiting
                pass

    except KeyboardInterrupt:
        print("\n\nStopping producers (Ctrl+C detected)...")
        STOP_FLAG.value = 1

    # Wait for all workers to finish
    print("\nWaiting for workers to finish...")
    for worker in workers:
        worker.join(timeout=10)
        if worker.is_alive():
            worker.terminate()

    # Calculate final statistics from worker processes
    # Note: Workers already printed their individual stats
    elapsed_time = time.time() - start_time

    print("\n" + "=" * 80)
    print("PRODUCER TEST COMPLETE")
    print("=" * 80)
    print(f"Duration: {elapsed_time:.2f} seconds")
    print(f"(Workers have reported their individual statistics above)")
    print("=" * 80)


if __name__ == '__main__':
    main()
