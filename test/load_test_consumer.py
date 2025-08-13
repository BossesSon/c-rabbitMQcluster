#!/usr/bin/env python3
"""
High-Performance RabbitMQ Load Test Consumer
Designed to consume 150K messages/second at 100KB each
"""

import os
import sys
import time
import pika
import json
import threading
import multiprocessing
from datetime import datetime
import signal
import queue
from concurrent.futures import ThreadPoolExecutor

class LoadTestConsumer:
    def __init__(self, worker_id=0):
        self.worker_id = worker_id
        self.connections = []
        self.channels = []
        self.total_received = 0
        self.total_processed = 0
        self.total_bytes = 0
        self.start_time = None
        self.running = True
        self.stats_lock = threading.Lock()
        
        # Performance configuration
        self.num_connections = int(os.getenv('CONSUMER_CONNECTIONS', '20'))
        self.channels_per_connection = int(os.getenv('CHANNELS_PER_CONNECTION', '5'))
        self.prefetch_count = int(os.getenv('PREFETCH_COUNT', '1000'))
        self.processing_delay = float(os.getenv('PROCESSING_DELAY', '0.001'))  # 1ms
        self.batch_ack_size = int(os.getenv('BATCH_ACK_SIZE', '100'))
        
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
        
        self.ports = [5672, 5673, 5674, 5675]
        self.username = os.getenv('RABBITMQ_USERNAME', 'admin')
        self.password = os.getenv('RABBITMQ_PASSWORD', 'secure_password_123')
        self.vhost = os.getenv('RABBITMQ_VHOST', '/')
        
        # Queue pattern for consumption
        self.queue_pattern = os.getenv('QUEUE_PATTERN', 'load_test_queue_*')
        
        # Statistics
        self.last_stats_time = time.time()
        self.last_received_count = 0
        
        # Batch acknowledgment tracking
        self.pending_acks = {}
        self.ack_lock = threading.Lock()
        
        # Signal handling
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

    def _signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        print(f"\nWorker {self.worker_id}: Received signal {signum}, stopping...")
        self.running = False
        
        # Stop all channels
        for channel_info in self.channels:
            try:
                channel_info['channel'].stop_consuming()
            except:
                pass

    def _create_connection(self, host, port):
        """Create optimized RabbitMQ connection"""
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
            return connection
        except Exception as e:
            print(f"Worker {self.worker_id}: Failed to connect to {host}:{port} - {e}")
            return None

    def _get_queue_list(self):
        """Get list of queues to consume from"""
        # For this load test, we'll discover queues dynamically
        # In production, you might want to get this from management API
        queues = []
        
        # Generate queue names based on producer pattern
        num_producers = int(os.getenv('NUM_WORKERS', multiprocessing.cpu_count()))
        connections_per_producer = int(os.getenv('PRODUCER_CONNECTIONS', '50'))
        channels_per_connection = int(os.getenv('CHANNELS_PER_CONNECTION', '10'))
        
        for producer_id in range(num_producers):
            for conn_id in range(connections_per_producer):
                for chan_id in range(channels_per_connection):
                    queue_name = f"load_test_queue_{producer_id}_{conn_id}_{chan_id}"
                    queues.append(queue_name)
        
        return queues

    def _setup_connections(self):
        """Setup multiple connections and channels"""
        print(f"Worker {self.worker_id}: Setting up {self.num_connections} connections...")
        
        # Get available queues
        available_queues = self._get_queue_list()
        print(f"Worker {self.worker_id}: Found {len(available_queues)} potential queues")
        
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
                        channel.basic_qos(prefetch_count=self.prefetch_count)
                        
                        # Assign queues to this channel (round-robin)
                        channel_queues = []
                        start_idx = (i * self.channels_per_connection + j) * 10
                        for k in range(start_idx, min(start_idx + 10, len(available_queues))):
                            if k < len(available_queues):
                                queue_name = available_queues[k]
                                try:
                                    # Declare queue (should already exist)
                                    channel.queue_declare(
                                        queue=queue_name,
                                        durable=True,
                                        passive=True  # Don't create, just verify it exists
                                    )
                                    channel_queues.append(queue_name)
                                except Exception as e:
                                    # Queue doesn't exist, skip it
                                    pass
                        
                        if channel_queues:
                            channel_info = {
                                'channel': channel,
                                'queues': channel_queues,
                                'connection_id': i,
                                'channel_id': j
                            }
                            self.channels.append(channel_info)
                            self.pending_acks[f"{i}_{j}"] = []
                        else:
                            channel.close()
                            
                    except Exception as e:
                        print(f"Worker {self.worker_id}: Failed to create channel: {e}")
        
        print(f"Worker {self.worker_id}: Created {connection_count} connections, {len(self.channels)} channels")
        return len(self.channels) > 0

    def _process_message(self, channel, method, properties, body, channel_key):
        """Process individual message with high performance"""
        try:
            # Parse message
            message_data = json.loads(body.decode('utf-8'))
            
            # Simulate minimal processing
            if self.processing_delay > 0:
                time.sleep(self.processing_delay)
            
            # Update statistics
            with self.stats_lock:
                self.total_received += 1
                self.total_bytes += len(body)
            
            # Batch acknowledgment for performance
            with self.ack_lock:
                self.pending_acks[channel_key].append(method.delivery_tag)
                
                # Batch acknowledge when we reach batch size
                if len(self.pending_acks[channel_key]) >= self.batch_ack_size:
                    # Acknowledge all pending messages up to the latest delivery tag
                    latest_tag = max(self.pending_acks[channel_key])
                    channel.basic_ack(delivery_tag=latest_tag, multiple=True)
                    
                    with self.stats_lock:
                        self.total_processed += len(self.pending_acks[channel_key])
                    
                    self.pending_acks[channel_key].clear()
                    
        except json.JSONDecodeError as e:
            print(f"Worker {self.worker_id}: JSON decode error: {e}")
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
        except Exception as e:
            print(f"Worker {self.worker_id}: Processing error: {e}")
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

    def _create_callback(self, channel_key):
        """Create callback function for specific channel"""
        def callback(channel, method, properties, body):
            self._process_message(channel, method, properties, body, channel_key)
        return callback

    def _stats_reporter(self):
        """Background thread to report statistics"""
        while self.running:
            time.sleep(1)
            
            current_time = time.time()
            with self.stats_lock:
                elapsed = current_time - self.last_stats_time
                received_diff = self.total_received - self.last_received_count
                
                if elapsed > 0:
                    current_rate = received_diff / elapsed
                    total_elapsed = current_time - self.start_time if self.start_time else 0
                    avg_rate = self.total_received / total_elapsed if total_elapsed > 0 else 0
                    throughput_mbps = (received_diff * 100 * 1024) / (elapsed * 1024 * 1024)  # Assuming 100KB avg
                    
                    print(f"Worker {self.worker_id}: Rate: {current_rate:.0f}/s, "
                          f"Total: {self.total_received:,}, "
                          f"Processed: {self.total_processed:,}, "
                          f"Throughput: {throughput_mbps:.1f} MB/s, "
                          f"Avg: {avg_rate:.0f}/s, "
                          f"Time: {total_elapsed:.1f}s")
                
                self.last_stats_time = current_time
                self.last_received_count = self.total_received

    def _batch_ack_processor(self):
        """Background thread to handle batch acknowledgments"""
        while self.running:
            time.sleep(0.1)  # Check every 100ms
            
            with self.ack_lock:
                for channel_key, pending_tags in self.pending_acks.items():
                    if pending_tags:
                        # Find the corresponding channel
                        channel_info = None
                        for ch_info in self.channels:
                            ch_key = f"{ch_info['connection_id']}_{ch_info['channel_id']}"
                            if ch_key == channel_key:
                                channel_info = ch_info
                                break
                        
                        if channel_info and len(pending_tags) > 0:
                            try:
                                # Acknowledge all pending messages
                                latest_tag = max(pending_tags)
                                channel_info['channel'].basic_ack(delivery_tag=latest_tag, multiple=True)
                                
                                with self.stats_lock:
                                    self.total_processed += len(pending_tags)
                                
                                pending_tags.clear()
                            except Exception as e:
                                print(f"Worker {self.worker_id}: Batch ack error: {e}")

    def run_consumer(self):
        """Execute the high-performance consumer"""
        print(f"Worker {self.worker_id}: Starting high-performance consumer...")
        
        if not self._setup_connections():
            print(f"Worker {self.worker_id}: Failed to setup connections")
            return False
        
        # Start background threads
        stats_thread = threading.Thread(target=self._stats_reporter, daemon=True)
        stats_thread.start()
        
        batch_ack_thread = threading.Thread(target=self._batch_ack_processor, daemon=True)
        batch_ack_thread.start()
        
        print(f"Worker {self.worker_id}: Starting consumption on {len(self.channels)} channels...")
        
        # Setup consumers on all channels
        for channel_info in self.channels:
            channel = channel_info['channel']
            channel_key = f"{channel_info['connection_id']}_{channel_info['channel_id']}"
            callback = self._create_callback(channel_key)
            
            # Consume from all queues assigned to this channel
            for queue_name in channel_info['queues']:
                try:
                    channel.basic_consume(
                        queue=queue_name,
                        on_message_callback=callback,
                        auto_ack=False  # Manual ack for reliability
                    )
                except Exception as e:
                    print(f"Worker {self.worker_id}: Failed to consume from {queue_name}: {e}")
        
        self.start_time = time.time()
        print(f"Worker {self.worker_id}: Consumer started, processing messages...")
        
        # Main consumption loop
        try:
            while self.running:
                for channel_info in self.channels:
                    if self.running:
                        try:
                            # Process events with short timeout for responsiveness
                            channel_info['channel'].connection.process_data_events(time_limit=0.1)
                        except Exception as e:
                            print(f"Worker {self.worker_id}: Channel error: {e}")
                            # Try to recover
                            break
                    else:
                        break
                        
        except KeyboardInterrupt:
            print(f"\nWorker {self.worker_id}: Interrupted by user")
        except Exception as e:
            print(f"Worker {self.worker_id}: Consumer error: {e}")
        finally:
            self._final_cleanup()
        
        return True

    def _final_cleanup(self):
        """Final cleanup and statistics"""
        print(f"Worker {self.worker_id}: Performing final cleanup...")
        
        # Acknowledge any remaining messages
        with self.ack_lock:
            for channel_key, pending_tags in self.pending_acks.items():
                if pending_tags:
                    # Find corresponding channel
                    for ch_info in self.channels:
                        ch_key = f"{ch_info['connection_id']}_{ch_info['channel_id']}"
                        if ch_key == channel_key:
                            try:
                                latest_tag = max(pending_tags)
                                ch_info['channel'].basic_ack(delivery_tag=latest_tag, multiple=True)
                                with self.stats_lock:
                                    self.total_processed += len(pending_tags)
                            except:
                                pass
                            break
        
        # Close all connections
        for connection in self.connections:
            try:
                if connection and not connection.is_closed:
                    connection.close()
            except:
                pass
        
        # Final statistics
        if self.start_time:
            total_time = time.time() - self.start_time
            final_rate = self.total_received / total_time if total_time > 0 else 0
            throughput_gbps = (self.total_bytes / total_time) / (1024 * 1024 * 1024) if total_time > 0 else 0
            
            print(f"\nWorker {self.worker_id} Final Results:")
            print(f"  Messages received: {self.total_received:,}")
            print(f"  Messages processed: {self.total_processed:,}")
            print(f"  Total bytes: {self.total_bytes / 1024 / 1024 / 1024:.2f} GB")
            print(f"  Total time: {total_time:.2f}s")
            print(f"  Average rate: {final_rate:.0f} msg/s")
            print(f"  Throughput: {throughput_gbps:.2f} GB/s")

def worker_process(worker_id):
    """Individual worker process"""
    consumer = LoadTestConsumer(worker_id)
    try:
        consumer.run_consumer()
    except Exception as e:
        print(f"Worker {worker_id} error: {e}")
    finally:
        print(f"Worker {worker_id} finished")

def main():
    """Main consumer orchestrator"""
    print("🎧 Starting RabbitMQ High-Performance Load Test Consumer")
    print("Target: Handle 150K msg/s × 100KB messages")
    
    # Number of worker processes
    num_workers = int(os.getenv('CONSUMER_WORKERS', multiprocessing.cpu_count()))
    
    print(f"Launching {num_workers} consumer worker processes...")
    
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
        print("\n🛑 Terminating consumers...")
        for p in processes:
            p.terminate()
        for p in processes:
            p.join(timeout=5)
    
    print("🎉 Consumer load test completed!")

if __name__ == '__main__':
    main()