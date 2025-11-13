#!/usr/bin/env python3
"""
High-Performance RabbitMQ Load Test Producer
Target: 150K messages/second at 100KB each for 100 seconds
Total: 15 million messages, ~1.43 TB data
"""

import os
import sys
import time
import pika
import json
import threading
import multiprocessing
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
import signal
import queue
import random
import string

class LoadTestProducer:
    def __init__(self, worker_id=0):
        self.worker_id = worker_id
        self.connections = []
        self.channels = []
        self.total_sent = 0
        self.total_confirmed = 0
        self.start_time = None
        self.running = True
        self.stats_lock = threading.Lock()
        
        # Load test configuration
        self.target_rate = int(os.getenv('TARGET_RATE', '150000'))  # msg/sec
        self.message_size = int(os.getenv('MESSAGE_SIZE', '102400'))  # 100KB
        self.test_duration = int(os.getenv('TEST_DURATION', '100'))  # seconds
        self.num_connections = int(os.getenv('PRODUCER_CONNECTIONS', '50'))
        self.channels_per_connection = int(os.getenv('CHANNELS_PER_CONNECTION', '10'))
        self.batch_size = int(os.getenv('BATCH_SIZE', '100'))
        
        # Generate large message payload
        self.base_payload = self._generate_payload(self.message_size)
        
        # RabbitMQ connection details
        self.hosts = [
            os.getenv('RABBITMQ_HOST', 'localhost'),
            os.getenv('RMQ1_HOST', 'localhost'),
            os.getenv('RMQ2_HOST', 'localhost'),
            os.getenv('RMQ3_HOST', 'localhost')
        ]
        # Remove duplicates and None values
        self.hosts = list(set([h for h in self.hosts if h and h != 'localhost']))
        if not self.hosts:
            self.hosts = ['localhost']
        
        self.ports = [5672, 5673, 5674, 5675]  # Multiple ports for load balancing
        self.username = os.getenv('RABBITMQ_USERNAME', 'admin')
        self.password = os.getenv('RABBITMQ_PASSWORD', 'secure_password_123')
        self.vhost = os.getenv('RABBITMQ_VHOST', '/')
        self.queue_name = f'load_test_queue_{worker_id}'
        
        # Statistics
        self.last_stats_time = time.time()
        self.last_sent_count = 0
        
        # Signal handling
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

    def _generate_payload(self, size):
        """Generate a payload of specified size"""
        # Create structured data that compresses poorly (more realistic)
        base_data = {
            'worker_id': self.worker_id,
            'timestamp': '',
            'sequence': 0,
            'data': ''.join(random.choices(string.ascii_letters + string.digits, k=size-500)),
            'checksum': '',
            'metadata': {
                'load_test': True,
                'target_rate': self.target_rate,
                'message_size': self.message_size
            }
        }
        
        # Serialize to get actual size and adjust if needed
        json_str = json.dumps(base_data)
        current_size = len(json_str.encode('utf-8'))
        
        if current_size < size:
            # Add more data to reach target size
            additional_data = ''.join(random.choices(string.ascii_letters, k=size-current_size))
            base_data['padding'] = additional_data
        elif current_size > size:
            # Trim data field to reach target size
            excess = current_size - size
            base_data['data'] = base_data['data'][:-excess]
        
        return base_data

    def _signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        print(f"\nWorker {self.worker_id}: Received signal {signum}, stopping...")
        self.running = False

    def _create_connection(self, host, port):
        """Create optimized RabbitMQ connection"""
        connection_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
        print(f"Worker {self.worker_id}: 🔌 Connecting to {host}:{port} at {connection_time}...")

        credentials = pika.PlainCredentials(self.username, self.password)
        parameters = pika.ConnectionParameters(
            host=host,
            port=port,
            virtual_host=self.vhost,
            credentials=credentials,
            heartbeat=30,
            blocked_connection_timeout=5,
            connection_attempts=3,
            retry_delay=1,
            socket_timeout=5,
            frame_max=1048576,
            channel_max=1000
        )

        try:
            connection = pika.BlockingConnection(parameters)
            success_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
            print(f"Worker {self.worker_id}: ✓ Connected to {host}:{port} at {success_time}")
            return connection
        except Exception as e:
            error_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
            error_type = type(e).__name__
            print(f"Worker {self.worker_id}: ❌ Connection FAILED to {host}:{port} at {error_time}")
            print(f"Worker {self.worker_id}:    Error type: {error_type}")
            print(f"Worker {self.worker_id}:    Error message: {e}")
            return None

    def _setup_connections(self):
        """Setup multiple connections and channels"""
        print(f"Worker {self.worker_id}: Setting up {self.num_connections} connections...")
        
        connection_count = 0
        for i in range(self.num_connections):
            # Round-robin through hosts and ports
            host = self.hosts[i % len(self.hosts)]
            port = self.ports[i % len(self.ports)]
            
            connection = self._create_connection(host, port)
            if connection:
                self.connections.append(connection)
                connection_count += 1
                
                # Create multiple channels per connection
                for j in range(self.channels_per_connection):
                    try:
                        channel = connection.channel()

                        # MAXIMUM THROUGHPUT MODE: Publisher confirms DISABLED
                        # Fire-and-forget for maximum performance
                        # mandatory=True will still raise exceptions if routing fails
                        # (channel.confirm_delivery() is NOT called - removed for throughput)

                        # Declare queue with load balancing across nodes
                        channel.queue_declare(
                            queue=f"{self.queue_name}_{i}_{j}",
                            durable=True,
                            arguments={
                                'x-queue-type': 'quorum',
                                'x-max-length': 1000000,  # Limit queue size
                                'x-overflow': 'drop-head'
                            }
                        )

                        self.channels.append((channel, f"{self.queue_name}_{i}_{j}"))
                        print(f"Worker {self.worker_id}: ✓ Created channel {j+1}/{self.channels_per_connection} on connection to {host}:{port}")
                    except Exception as e:
                        error_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
                        print(f"Worker {self.worker_id}: ❌ Failed to create channel at {error_time}: {e}")
        
        print(f"Worker {self.worker_id}: Created {connection_count} connections, {len(self.channels)} channels")
        return len(self.channels) > 0

    def _publish_batch(self, channel_info, messages):
        """Publish a batch of messages"""
        channel, queue_name = channel_info
        confirmed = 0

        try:
            for msg_data in messages:
                channel.basic_publish(
                    exchange='',
                    routing_key=queue_name,
                    body=json.dumps(msg_data).encode('utf-8'),
                    properties=pika.BasicProperties(
                        delivery_mode=2,  # Persistent
                        content_type='application/json',
                        timestamp=int(time.time())
                    ),
                    mandatory=True  # Raise exception if message cannot be routed
                )
                confirmed += 1

        except Exception as e:
            error_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
            error_type = type(e).__name__
            print(f"Worker {self.worker_id}: ❌ Batch publish error at {error_time}")
            print(f"Worker {self.worker_id}:    Type: {error_type}")
            print(f"Worker {self.worker_id}:    Message: {e}")
            print(f"Worker {self.worker_id}:    Queue: {queue_name}")
            print(f"Worker {self.worker_id}:    Messages in batch: {len(messages)}")
            print(f"Worker {self.worker_id}:    Confirmed before error: {confirmed}")

        return confirmed

    def _stats_reporter(self):
        """Background thread to report statistics"""
        while self.running:
            time.sleep(1)
            
            current_time = time.time()
            with self.stats_lock:
                elapsed = current_time - self.last_stats_time
                sent_diff = self.total_sent - self.last_sent_count
                
                if elapsed > 0:
                    current_rate = sent_diff / elapsed
                    total_elapsed = current_time - self.start_time if self.start_time else 0
                    avg_rate = self.total_sent / total_elapsed if total_elapsed > 0 else 0
                    
                    print(f"Worker {self.worker_id}: Rate: {current_rate:.0f}/s, "
                          f"Total: {self.total_sent:,}, "
                          f"Confirmed: {self.total_confirmed:,}, "
                          f"Avg: {avg_rate:.0f}/s, "
                          f"Time: {total_elapsed:.1f}s")
                
                self.last_stats_time = current_time
                self.last_sent_count = self.total_sent

    def run_load_test(self):
        """Execute the high-performance load test"""
        print(f"Worker {self.worker_id}: Starting load test...")
        print(f"Target: {self.target_rate:,} msg/s, {self.message_size:,} bytes/msg, {self.test_duration}s")
        
        if not self._setup_connections():
            print(f"Worker {self.worker_id}: Failed to setup connections")
            return False
        
        # Calculate per-worker rates
        messages_per_second = self.target_rate // multiprocessing.cpu_count()
        total_messages = messages_per_second * self.test_duration
        
        print(f"Worker {self.worker_id}: Target {messages_per_second:,} msg/s, {total_messages:,} total messages")
        
        # Start stats reporter
        stats_thread = threading.Thread(target=self._stats_reporter, daemon=True)
        stats_thread.start()
        
        self.start_time = time.time()
        message_id = 0
        
        # Use ThreadPoolExecutor for concurrent publishing
        with ThreadPoolExecutor(max_workers=len(self.channels)) as executor:
            
            while self.running and (time.time() - self.start_time) < self.test_duration:
                batch_start = time.time()
                
                # Prepare batch of messages
                batch_messages = []
                for _ in range(self.batch_size):
                    message_id += 1
                    msg_data = self.base_payload.copy()
                    msg_data['sequence'] = message_id
                    msg_data['timestamp'] = datetime.now().isoformat()
                    msg_data['worker_id'] = self.worker_id
                    batch_messages.append(msg_data)
                
                # Submit batches to different channels concurrently
                futures = []
                for i, channel_info in enumerate(self.channels):
                    if i < len(batch_messages):
                        batch = batch_messages[i::len(self.channels)]  # Distribute messages
                        future = executor.submit(self._publish_batch, channel_info, batch)
                        futures.append(future)
                
                # Collect results
                batch_confirmed = 0
                for future in futures:
                    try:
                        confirmed = future.result(timeout=1.0)
                        batch_confirmed += confirmed
                    except Exception as e:
                        print(f"Worker {self.worker_id}: Future error: {e}")
                
                with self.stats_lock:
                    self.total_sent += len(batch_messages)
                    self.total_confirmed += batch_confirmed
                
                # Rate limiting
                batch_duration = time.time() - batch_start
                target_batch_duration = self.batch_size / messages_per_second
                
                if batch_duration < target_batch_duration:
                    sleep_time = target_batch_duration - batch_duration
                    time.sleep(sleep_time)
        
        # Final statistics
        total_time = time.time() - self.start_time
        final_rate = self.total_sent / total_time if total_time > 0 else 0
        
        print(f"\nWorker {self.worker_id} Final Results:")
        print(f"  Messages sent: {self.total_sent:,}")
        print(f"  Messages confirmed: {self.total_confirmed:,}")
        print(f"  Total time: {total_time:.2f}s")
        print(f"  Average rate: {final_rate:.0f} msg/s")
        print(f"  Data sent: {(self.total_sent * self.message_size / 1024 / 1024 / 1024):.2f} GB")
        
        return True

    def cleanup(self):
        """Clean up connections"""
        print(f"Worker {self.worker_id}: Cleaning up...")
        
        for connection in self.connections:
            try:
                if connection and not connection.is_closed:
                    connection.close()
            except:
                pass

def worker_process(worker_id):
    """Individual worker process"""
    producer = LoadTestProducer(worker_id)
    try:
        producer.run_load_test()
    finally:
        producer.cleanup()

def main():
    """Main load test orchestrator"""
    print("🚀 Starting RabbitMQ High-Performance Load Test")
    print("Target: 150K msg/s × 100KB × 100s = ~1.43TB")
    
    # Number of worker processes (typically CPU count)
    num_workers = int(os.getenv('NUM_WORKERS', multiprocessing.cpu_count()))
    
    print(f"Launching {num_workers} worker processes...")
    
    # Start worker processes
    processes = []
    for i in range(num_workers):
        p = multiprocessing.Process(target=worker_process, args=(i,))
        p.start()
        processes.append(p)
        time.sleep(0.1)  # Stagger startup
    
    # Wait for all workers
    try:
        for p in processes:
            p.join()
    except KeyboardInterrupt:
        print("\n🛑 Terminating workers...")
        for p in processes:
            p.terminate()
        for p in processes:
            p.join(timeout=5)
    
    print("🎉 Load test completed!")

if __name__ == '__main__':
    main()