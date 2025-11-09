# RabbitMQ Python Pika Documentation Reference

## Official Resources
- **RabbitMQ Hello World Tutorial**: https://www.rabbitmq.com/tutorials/tutorial-one-python
- **RabbitMQ Work Queues Tutorial**: https://www.rabbitmq.com/tutorials/tutorial-two-python
- **Pika Documentation**: https://pika.readthedocs.io
- **Pika Channel Methods**: https://pika.readthedocs.io/en/stable/modules/channel.html
- **Blocking Consumer Example**: https://pika.readthedocs.io/en/stable/examples/blocking_consume.html

---

## Publisher Confirms (CRITICAL!)

### ⚠️ WARNING: Messages Can Be Silently Lost Without Publisher Confirms

**CRITICAL ISSUE**: With `BlockingConnection`, `basic_publish()` is **synchronous** but does **NOT** wait for confirmation from RabbitMQ **UNLESS you enable publisher confirms**.

**What happens without publisher confirms:**
1. Messages go into Pika's internal buffer
2. `basic_publish()` returns immediately (appears successful)
3. If buffer fills or connection blocks, **messages are SILENTLY DROPPED**
4. Producer has no idea messages were lost
5. RabbitMQ never receives the messages

**Solution: Enable Publisher Confirms**

```python
# BEFORE publishing any messages, enable confirms:
channel.confirm_delivery()

# Now basic_publish waits for RabbitMQ to acknowledge
channel.basic_publish(
    exchange='',
    routing_key='task_queue',
    body=message,
    properties=pika.BasicProperties(delivery_mode=2)
)
```

**With publisher confirms enabled:**
- Each `basic_publish()` **blocks** until RabbitMQ confirms receipt
- If message can't be delivered, raises `pika.exceptions.UnroutableError`
- **Guarantees** messages actually reach RabbitMQ
- Slower (adds latency) but **reliable**

---

## Message Persistence

### Making Messages Persistent

To mark messages as persistent (survive RabbitMQ restart):

```python
# Enable publisher confirms (CRITICAL!)
channel.confirm_delivery()

# Publish persistent message
channel.basic_publish(
    exchange='',
    routing_key='task_queue',
    body=message,
    properties=pika.BasicProperties(
        delivery_mode=pika.DeliveryMode.Persistent  # or delivery_mode=2
    )
)
```

**Note**: Marking messages as persistent doesn't fully guarantee that a message won't be lost. There's a short time window when RabbitMQ has accepted a message but hasn't saved it yet. RabbitMQ doesn't do fsync(2) for every message.

### Making Queues Durable

For messages to persist to disk and survive server restart:
1. Publish to a durable exchange
2. Queue must be durable
3. Message must have persistent flag

```python
channel.queue_declare(queue='task_queue', durable=True)
```

---

## Consumer Patterns: basic_get vs basic_consume

### basic_consume (RECOMMENDED ✅)

**What it does**: Push-based model where RabbitMQ pushes messages to your consumer as they become available.

**How it works**:
1. Consumer registers with server via `basic_consume`
2. Broker pushes messages using `basic.deliver`
3. Consumer acknowledges messages (unless no-ack option set)

**Example**:
```python
def callback(ch, method, properties, body):
    print(f"Received {body}")
    ch.basic_ack(delivery_tag=method.delivery_tag)

channel.basic_consume(queue='task_queue', on_message_callback=callback)
channel.start_consuming()
```

**Advantages**:
- **Efficient**: Messages pushed as they arrive
- **Low latency**: No polling overhead
- **Scalable**: Can handle high throughput
- **Recommended by RabbitMQ**: Official best practice

---

### basic_get (DISCOURAGED ❌)

**What it does**: Polling-based model where consumer requests messages one at a time.

**How it works**:
1. Client sends request to server for a message
2. Server responds with `get-ok` (with message) or `get-empty` (no messages)
3. Repeat for each message

**Example**:
```python
method_frame, properties, body = channel.basic_get(queue='task_queue', auto_ack=False)
if method_frame:
    print(f"Received {body}")
    channel.basic_ack(delivery_tag=method_frame.delivery_tag)
else:
    print("Queue is empty")
```

**Disadvantages**:
- **Highly inefficient**: Polling overhead for each message
- **Wasteful**: Especially when queues are often empty
- **High latency**: Request/response cycle for each message
- **Not recommended**: Official RabbitMQ docs discourage this

**Quote from RabbitMQ docs**:
> "Fetching messages one by one is highly discouraged as it is very inefficient compared to regular long-lived consumers. As with any polling-based algorithm, it will be extremely wasteful in systems where message publishing is sporadic and queues can stay empty for prolonged periods of time."

---

## Key Pika Concepts

### BlockingConnection

A synchronous connection adapter. Blocks until operation completes.

```python
import pika

credentials = pika.PlainCredentials('username', 'password')
parameters = pika.ConnectionParameters(
    host='localhost',
    port=5672,
    credentials=credentials,
    heartbeat=600,
    blocked_connection_timeout=300
)

connection = pika.BlockingConnection(parameters)
channel = connection.channel()
```

### Quality of Service (QoS)

Controls how many unacknowledged messages a consumer can have:

```python
channel.basic_qos(prefetch_count=10)
```

- `prefetch_count`: Max number of unacknowledged messages
- Higher = better throughput, but more messages at risk if consumer crashes
- Lower = safer, but slower

### Message Acknowledgment

**Manual acknowledgment** (recommended for reliability):
```python
channel.basic_consume(queue='task_queue', on_message_callback=callback, auto_ack=False)

def callback(ch, method, properties, body):
    # Process message
    ch.basic_ack(delivery_tag=method.delivery_tag)
```

**Auto acknowledgment** (faster but risky):
```python
channel.basic_consume(queue='task_queue', on_message_callback=callback, auto_ack=True)
```

---

## Common Issues

### Issue 1: Messages Not Being Consumed

**Symptoms**: Producer sends messages, but consumer receives 0.

**Possible causes**:
1. **Queue name mismatch**: Producer and consumer using different queue names
2. **Using `basic_get` instead of `basic_consume`**: Inefficient polling
3. **Consumer exits too quickly**: Process ends before consuming
4. **Connection issues**: Can't connect to RabbitMQ

**Solutions**:
- Use `basic_consume` with callbacks (recommended)
- Ensure queue names match exactly
- Keep consumer running with `start_consuming()`

### Issue 2: Slow Consumer Performance

**Symptoms**: Consumer can't keep up with producer rate.

**Solutions**:
1. Increase `prefetch_count` (process more messages in parallel)
2. Use multiple consumer workers
3. Optimize message processing logic
4. Use batch acknowledgments

### Issue 3: Messages Lost on Consumer Crash

**Symptoms**: Messages disappear when consumer dies.

**Solutions**:
1. Use manual acknowledgment (`auto_ack=False`)
2. Only acknowledge after successful processing
3. Use persistent messages + durable queues

---

## Best Practices for High-Throughput Consumers

### 1. Use basic_consume (Not basic_get)
```python
# ✅ GOOD
channel.basic_consume(queue='task_queue', on_message_callback=callback)
channel.start_consuming()

# ❌ BAD
while True:
    method_frame, properties, body = channel.basic_get(queue='task_queue')
    if method_frame:
        process(body)
```

### 2. Set Appropriate Prefetch
```python
# For high throughput
channel.basic_qos(prefetch_count=100)  # Process 100 messages before acking

# For safety
channel.basic_qos(prefetch_count=10)   # Lower risk if consumer crashes
```

### 3. Use Multiple Connections
- Each connection runs in separate thread/process
- Spreads load across network sockets
- Better utilization of multi-core CPUs

### 4. Batch Acknowledgments
```python
message_count = 0

def callback(ch, method, properties, body):
    global message_count
    process(body)
    message_count += 1

    # Ack every 50 messages
    if message_count % 50 == 0:
        ch.basic_ack(delivery_tag=method.delivery_tag, multiple=True)
```

### 5. Handle Errors Gracefully
```python
def callback(ch, method, properties, body):
    try:
        process(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as e:
        print(f"Error: {e}")
        # Reject and requeue (or send to dead letter queue)
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
```

---

## Performance Comparison

| Metric | basic_consume | basic_get |
|--------|---------------|-----------|
| Throughput | **High** (10K-100K+ msg/s) | **Low** (100-1K msg/s) |
| Latency | **Low** (push-based) | **High** (polling overhead) |
| CPU Usage | **Efficient** | **Wasteful** (constant polling) |
| Network Efficiency | **High** (batch delivery) | **Low** (per-message request) |
| Recommendation | **✅ Use this** | **❌ Avoid** |

---

## Summary

### DO ✅
- Use `basic_consume` for consumers
- Use manual acknowledgment for reliability
- Set appropriate `prefetch_count` (100-500 for high throughput)
- Use multiple worker processes/connections
- Make messages persistent and queues durable for important data

### DON'T ❌
- Don't use `basic_get` in a loop (extremely inefficient)
- Don't use auto-ack unless you can afford to lose messages
- Don't create one connection per message
- Don't skip error handling
