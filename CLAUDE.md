# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a **RabbitMQ Cluster Setup** for Rocky Linux 8 using Podman. It provides scripts and configurations to deploy a 3-node RabbitMQ cluster with high availability and message durability testing.

## Key Components

### Core Files
- **rmq.sh**: Main cluster management script with commands for prep, up, join, policy, status, down, wipe
- **rabbitmq.conf**: RabbitMQ configuration with clustering, quorum queues, and management settings
- **.env.example**: Environment template with all required variables (copy to .env)
- **QUICKSTART.md**: Complete step-by-step setup guide

### Test Application
- **test/**: Python producer/consumer application for testing cluster functionality
  - **Dockerfile**: Minimal Python 3 + pika environment
  - **producer.py**: Publishes persistent messages with publisher confirms
  - **consumer.py**: Consumes messages with manual acks and throughput reporting

## Architecture

- **3-node RabbitMQ cluster** using quorum queues with replication factor 3
- **Rootless Podman containers** using official rabbitmq:3.13-management image
- **Classic config peer discovery** with shared Erlang cookie
- **High availability testing** with node failure simulation

## Common Development Tasks

### Cluster Management
```bash
./rmq.sh prep                 # Install Podman, configure firewall
./rmq.sh up rmq1             # Start RabbitMQ node
./rmq.sh join rmq2 rmq1      # Join node to cluster
./rmq.sh policy              # Apply quorum queue policy
./rmq.sh status              # Check cluster status
./rmq.sh down rmq1           # Stop node
./rmq.sh wipe rmq1           # Delete all node data
```

### Test Application
```bash
cd test/
podman build -t rabbitmq-test .
podman run --rm --env-file ../.env rabbitmq-test python producer.py
podman run -d --name consumer --env-file ../.env rabbitmq-test python consumer.py
```

## Environment Configuration

Copy `.env.example` to `.env` and configure:
- Server IP addresses (RMQ1_HOST, RMQ2_HOST, RMQ3_HOST, TEST_HOST)
- RabbitMQ credentials (RABBITMQ_ADMIN_USER, RABBITMQ_ADMIN_PASSWORD)
- Shared Erlang cookie (generate with `openssl rand -base64 32`)

## Network Requirements

**Firewall ports**: 5672 (AMQP), 15672 (Management UI), 4369 (EPMD), 25672 (Inter-node)

## Expected Infrastructure

- 4 Rocky Linux 8 servers with SSH access
- Servers 1-3: RabbitMQ cluster nodes
- Server 4: Test application host
- Network connectivity between all servers