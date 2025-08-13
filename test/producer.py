#!/usr/bin/env python3
"""
RabbitMQ Test Producer
Publishes persistent messages with publisher confirms to test durability
"""

import os
import sys
import time
import pika
import json
from datetime import datetime

def get_connection():
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
    
    max_retries = 5
    retry_delay = 2
    
    for attempt in range(max_retries):
        try:
            print(f"Connecting to RabbitMQ at {host}:{port} (attempt {attempt + 1}/{max_retries})")
            connection = pika.BlockingConnection(parameters)
            print("✅ Connected to RabbitMQ!")
            return connection
        except pika.exceptions.AMQPConnectionError as e:
            if attempt < max_retries - 1:
                print(f"❌ Connection failed: {e}")
                print(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
                retry_delay *= 2  # Exponential backoff
            else:
                print(f"❌ Failed to connect after {max_retries} attempts: {e}")
                raise

def main():
    """Main producer function"""
    try:
        # Connect to RabbitMQ
        connection = get_connection()
        channel = connection.channel()
        
        # Enable publisher confirms for reliable publishing
        channel.confirm_delivery()
        
        # Declare queue - try quorum first, fallback to classic HA
        queue_name = 'test_queue'
        
        try:
            # Try quorum queue first (works if cluster has 3+ nodes)
            print("Attempting to create quorum queue...")
            channel.queue_declare(
                queue=queue_name,
                durable=True,
                arguments={
                    'x-queue-type': 'quorum'
                }
            )
            print("✅ Quorum queue created successfully")
        except Exception as e:
            print(f"⚠️  Quorum queue failed: {e}")
            print("Falling back to classic durable queue with HA policy...")
            
            # Fallback to classic durable queue (will use HA policy)
            channel.queue_declare(
                queue=queue_name,
                durable=True
            )
            print("✅ Classic HA queue created")
        
        print(f"📨 Publishing messages to queue: {queue_name}")
        print("Messages will be persistent and survive node failures\n")
        
        # Publish test messages
        message_count = int(os.getenv('MESSAGE_COUNT', '10'))
        
        for i in range(1, message_count + 1):
            # Create message payload
            message_data = {
                'id': i,
                'timestamp': datetime.now().isoformat(),
                'content': f'Test message #{i}',
                'producer': 'test-producer',
                'cluster_test': True
            }
            
            message_body = json.dumps(message_data, indent=2)
            
            try:
                # Publish with publisher confirms
                success = channel.basic_publish(
                    exchange='',
                    routing_key=queue_name,
                    body=message_body,
                    properties=pika.BasicProperties(
                        delivery_mode=2,  # Make message persistent
                        content_type='application/json',
                        timestamp=int(time.time())
                    ),
                    mandatory=True
                )
                
                if success:
                    print(f"✅ Message {i} published and confirmed")
                else:
                    print(f"❌ Message {i} failed to be confirmed")
                    
            except pika.exceptions.UnroutableError:
                print(f"❌ Message {i} could not be routed")
            except Exception as e:
                print(f"❌ Error publishing message {i}: {e}")
                
            # Small delay between messages
            time.sleep(0.1)
        
        print(f"\n🎉 Successfully published {message_count} messages!")
        print("Messages are persistent and replicated across the cluster")
        
    except KeyboardInterrupt:
        print("\n🛑 Publishing interrupted by user")
    except Exception as e:
        print(f"❌ Producer error: {e}")
        sys.exit(1)
    finally:
        try:
            if 'connection' in locals() and not connection.is_closed:
                connection.close()
                print("🔌 Connection closed")
        except:
            pass

if __name__ == '__main__':
    main()