# Dockerfile for RabbitMQ Test Application
# Minimal Python 3 environment with pika library

FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies (if needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy simple multiprocess test scripts
COPY simple_multiprocess_producer.py .
COPY simple_multiprocess_consumer.py .

# Set default command
CMD ["python"]

# Add labels for documentation
LABEL maintainer="RabbitMQ Cluster Test"
LABEL description="Minimal Python application for testing RabbitMQ cluster durability and HA"