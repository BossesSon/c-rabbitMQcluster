# Dockerfile for RabbitMQ Test Application
# Minimal Python 3 environment with pika library

FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies (if needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir pika==1.3.2

# Copy test scripts
COPY producer.py .
COPY consumer.py .

# Make scripts executable
RUN chmod +x producer.py consumer.py

# Set default command
CMD ["python", "consumer.py"]

# Add labels for documentation
LABEL maintainer="RabbitMQ Cluster Test"
LABEL description="Minimal Python application for testing RabbitMQ cluster durability and HA"