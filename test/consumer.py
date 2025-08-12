#!/usr/bin/env python3
"""
RabbitMQ Test Consumer
Consumes messages with manual acknowledgments and reports throughput
"""

import os
import sys
import time
import pika
import json
import signal
from datetime import datetime

class Consumer:
    def __init__(self):
        self.connection = None
        self.channel = None
        self.queue_name = 'test_queue'
        self.message_count = 0
        self.start_time = time.time()
        self.running = True
        
        # Set up signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        print(f"\n🛑 Received signal {signum}, shutting down gracefully...")
        self.running = False
        if self.channel:
            self.channel.stop_consuming()
    
    def get_connection(self):
        """Create RabbitMQ connection with retry logic"""
        host = os.getenv('RABBITMQ_HOST', 'localhost')
        port = int(os.getenv('RABBITMQ_PORT', '5672'))
        username = os.getenv('RABBITMQ_USERNAME', 'guest')
        password = os.getenv('RABBITMQ_PASSWORD', 'guest')
        vhost = os.getenv('RABBITMQ_VHOST', '/')
        
        credentials = pika.PlainCredentials(username, password)
        parameters = pika.ConnectionParameters(
            host=host,
            port=port,
            virtual_host=vhost,
            credentials=credentials,
            heartbeat=60,
            blocked_connection_timeout=300
        )
        
        max_retries = 10
        retry_delay = 2
        
        for attempt in range(max_retries):
            try:
                print(f"Connecting to RabbitMQ at {host}:{port} (attempt {attempt + 1}/{max_retries})")
                self.connection = pika.BlockingConnection(parameters)
                self.channel = self.connection.channel()
                print("✅ Connected to RabbitMQ!")
                return True
                
            except pika.exceptions.AMQPConnectionError as e:
                if attempt < max_retries - 1:
                    print(f"❌ Connection failed: {e}")
                    print(f"Retrying in {retry_delay} seconds...")
                    time.sleep(retry_delay)
                    retry_delay = min(retry_delay * 1.5, 30)  # Exponential backoff with cap
                else:
                    print(f"❌ Failed to connect after {max_retries} attempts: {e}")
                    return False
    
    def message_callback(self, channel, method, properties, body):
        """Process received message"""
        try:
            # Parse message
            message_data = json.loads(body.decode('utf-8'))
            self.message_count += 1
            
            # Calculate throughput
            elapsed = time.time() - self.start_time
            rate = self.message_count / elapsed if elapsed > 0 else 0
            
            print(f"📬 Message {self.message_count}: ID={message_data.get('id', 'N/A')}, "
                  f"Content='{message_data.get('content', 'N/A')}', "
                  f"Rate={rate:.2f} msg/sec")
            
            # Simulate some processing time
            processing_time = float(os.getenv('PROCESSING_TIME', '0.1'))
            if processing_time > 0:
                time.sleep(processing_time)
            
            # Acknowledge message (this ensures it won't be redelivered)
            channel.basic_ack(delivery_tag=method.delivery_tag)
            
            # Print throughput stats every 10 messages
            if self.message_count % 10 == 0:
                print(f"📊 Processed {self.message_count} messages in {elapsed:.1f}s "
                      f"(avg: {rate:.2f} msg/sec)")
            
        except json.JSONDecodeError as e:
            print(f"❌ Failed to parse message JSON: {e}")
            # Reject and don't requeue malformed messages
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
        except Exception as e:
            print(f"❌ Error processing message: {e}")
            # Reject and requeue for retry
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
    
    def run(self):
        """Main consumer loop"""
        try:
            # Connect to RabbitMQ
            if not self.get_connection():
                sys.exit(1)
            
            # Declare the same queue (idempotent)
            self.channel.queue_declare(
                queue=self.queue_name,
                durable=True,
                arguments={
                    'x-queue-type': 'quorum',
                    'x-quorum-initial-group-size': 3
                }
            )
            
            # Set quality of service (prefetch count)
            # This ensures fair dispatch and prevents overwhelming the consumer
            prefetch_count = int(os.getenv('PREFETCH_COUNT', '10'))
            self.channel.basic_qos(prefetch_count=prefetch_count)
            
            # Set up consumer
            self.channel.basic_consume(
                queue=self.queue_name,
                on_message_callback=self.message_callback
            )
            
            print(f"🎧 Consumer started, waiting for messages from queue: {self.queue_name}")
            print(f"📈 Prefetch count: {prefetch_count}")
            print("💡 Press CTRL+C to stop\n")
            
            # Start consuming
            while self.running:
                try:
                    self.connection.process_data_events(time_limit=1)
                except pika.exceptions.AMQPConnectionError:
                    print("❌ Connection lost, attempting to reconnect...")
                    if not self.get_connection():
                        print("❌ Failed to reconnect, exiting")
                        break
                    # Re-setup consumer after reconnection
                    self.channel.queue_declare(
                        queue=self.queue_name,
                        durable=True,
                        arguments={
                            'x-queue-type': 'quorum',
                            'x-quorum-initial-group-size': 3
                        }
                    )
                    self.channel.basic_qos(prefetch_count=prefetch_count)
                    self.channel.basic_consume(
                        queue=self.queue_name,
                        on_message_callback=self.message_callback
                    )
                    print("✅ Reconnected and resumed consuming")
        
        except KeyboardInterrupt:
            print("\n🛑 Consumer interrupted by user")
        except Exception as e:
            print(f"❌ Consumer error: {e}")
        finally:
            self.cleanup()
    
    def cleanup(self):
        """Clean up connections"""
        try:
            if self.channel and not self.channel.is_closed:
                self.channel.stop_consuming()
            if self.connection and not self.connection.is_closed:
                self.connection.close()
            
            # Print final statistics
            if self.message_count > 0:
                elapsed = time.time() - self.start_time
                rate = self.message_count / elapsed if elapsed > 0 else 0
                print(f"\n📊 Final Stats:")
                print(f"   Messages processed: {self.message_count}")
                print(f"   Total time: {elapsed:.1f} seconds")
                print(f"   Average rate: {rate:.2f} messages/second")
            
            print("🔌 Consumer stopped and connection closed")
        except Exception as e:
            print(f"⚠️  Error during cleanup: {e}")

def main():
    """Main entry point"""
    consumer = Consumer()
    consumer.run()

if __name__ == '__main__':
    main()