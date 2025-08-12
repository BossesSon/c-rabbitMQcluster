# RabbitMQ Test Application

This directory contains a simple Python test application to verify RabbitMQ cluster durability and high availability.

## Files

- **Dockerfile**: Minimal Python 3 environment with pika library
- **producer.py**: Publishes persistent messages with publisher confirms
- **consumer.py**: Consumes messages with manual acknowledgments and throughput reporting

## Usage

### Build the test container:
```bash
podman build -t rabbitmq-test .
```

### Run producer (send messages):
```bash
podman run --rm --env-file ../.env rabbitmq-test python producer.py
```

### Run consumer (receive messages):
```bash
podman run -d --name consumer --env-file ../.env rabbitmq-test python consumer.py
```

### Monitor consumer:
```bash
podman logs -f consumer
```

### Run interactive tests:
```bash
podman run -it --rm --env-file ../.env rabbitmq-test bash
```

## Environment Variables

The application reads these environment variables:

- `RABBITMQ_HOST`: RabbitMQ server hostname/IP
- `RABBITMQ_PORT`: RabbitMQ port (default: 5672)  
- `RABBITMQ_USERNAME`: Username for authentication
- `RABBITMQ_PASSWORD`: Password for authentication
- `RABBITMQ_VHOST`: Virtual host (default: /)
- `MESSAGE_COUNT`: Number of messages to send (default: 10)
- `PROCESSING_TIME`: Simulated processing delay in seconds (default: 0.1)
- `PREFETCH_COUNT`: Consumer prefetch count (default: 10)

## Testing High Availability

1. Start the consumer
2. Send some messages  
3. Stop one RabbitMQ node
4. Send more messages
5. Verify consumption continues without message loss