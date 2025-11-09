# Quick Deployment Instructions

## CRITICAL FIX: Publisher Confirms Added ⚠️

**THE PROBLEM WAS**: Producer was sending messages WITHOUT publisher confirms enabled. Messages were being buffered by Pika and **SILENTLY DROPPED** after ~130 messages. RabbitMQ never received them.

**THE FIX**: Added `channel.confirm_delivery()` to **guarantee** messages reach RabbitMQ.

## Files Changed
1. `simple_load_test.sh` - Added unbuffered Python output
2. `test/simple_multiprocess_producer.py` - **CRITICAL FIX: Added `confirm_delivery()` + detailed debug logging**
3. `test/simple_multiprocess_consumer.py` - **REWRITTEN to use basic_consume (push-based, RECOMMENDED)**

## What to Copy to Linux
Copy these **3 files** from Windows to Linux (overwrite existing):
- `simple_load_test.sh`
- `test/simple_multiprocess_producer.py`
- `test/simple_multiprocess_consumer.py` ← **NEW: Now uses proper consumption pattern**

## Commands to Run on Linux

```bash
# 1. Go to directory
cd /root/rabbitmq-load-test

# 2. Fix line endings (CRITICAL!)
dos2unix simple_load_test.sh
dos2unix test/simple_multiprocess_producer.py
dos2unix test/simple_multiprocess_consumer.py

# 3. Remove old container (force rebuild with new files)
podman rmi rabbitmq-simple-test

# 4. Run test
./simple_load_test.sh
```

## What You'll See in Logs

### Producer Log (Detailed Progress + Timing)

```
[Producer Worker 0] Starting initialization...
[Producer Worker 0] Target rate: 2500.0 msg/s, Delay: 0.000080s
[Producer Worker 0] Creating message body of 102400 bytes...
[Producer Worker 0] Message body created successfully
[Producer Worker 0] Connected with 5 connections to RabbitMQ
[Producer Worker 0] Entering message loop. Delay between messages: 0.000080s
[Producer Worker 0] SUCCESS! First message sent
[Producer Worker 0] SUCCESS! Second message sent (loop is working!)
[Producer Worker 0] Progress: 10 messages sent
[Producer Worker 0] Progress: 20 messages sent
...
[Producer Worker 0] Milestone 100: elapsed=5.2s, rate=19.2 msg/s
[Producer Worker 0] Progress: 1000 messages sent
[Producer Worker 0] MILESTONE: 1000 messages sent
[Producer Worker 0] Loop exited. Duration: 60.1s, Messages sent: 150000, Stop flag: 0
[Producer Worker 0] Finished: 150000 messages sent, 0 errors
```

### Consumer Log (Push-Based Consumption)

```
[Consumer Worker 0] Starting initialization...
[Consumer Worker 0] Connecting to 172.23.12.11:5672...
[Consumer Worker 0] Connected to RabbitMQ on 172.23.12.11
[Consumer Worker 0] Starting basic_consume (push-based consumption)...
[Consumer Worker 0] Consuming messages for 60 seconds...
[Consumer Worker 0] SUCCESS! First message received
[Consumer Worker 0] SUCCESS! Second message received (consuming is working!)
[Consumer Worker 0] Progress: 10 messages received
[Consumer Worker 0] Progress: 20 messages received
...
[Consumer Worker 0] MILESTONE: 1000 messages received
[Consumer Worker 0] Test duration reached. Stopping.
[Consumer Worker 0] Stopping consumption...
[Consumer Worker 0] Connection closed
[Consumer Worker 0] Finished: 150000 messages received, 0 errors
```

## What to Look For

### If it works: ✅
**Producer:**
- "SUCCESS! Second message sent (loop is working!)"
- Progress every 10 messages
- Milestone at 100: shows elapsed time and rate
- "Loop exited" shows duration and final count
- Final "Finished" line shows total messages sent

**Consumer:**
- "Starting basic_consume (push-based consumption)"
- "SUCCESS! Second message received (consuming is working!)"
- Progress every 10 messages
- Messages counting up steadily
- Final "Finished" line matches producer count

### If producer stops at ~130 messages:
The new logs will show:
- **Milestone 100**: Check the `rate` - is it very slow (e.g., 1 msg/s instead of 2500)?
- **Loop exited**: Check `Duration` - is it hitting 60 seconds with only 130 messages?
- **Delay between messages**: Check if this value is extremely large (> 1 second)

### If consumer gets 0 messages:
**Old behavior:** Used basic_get (polling) - inefficient
**New behavior:** Uses basic_consume (push) - should work!

If you still see 0:
- Check "Starting basic_consume" appears in log
- Check for error messages in consumer log
- Queue name mismatch (check producer and consumer use same queue)

### If there are errors:
You'll see:
- "ERROR during publish: [error message]"
- "ERROR in callback: [error message]" (consumer)
- "FATAL ERROR: [error message]"
- Full stack traces

## After Running - Check the Log

```bash
cat /tmp/producer_full.log
```

**Send me the FULL output** and I'll tell you exactly what's wrong!

## Common Issues and What the Log Will Show

| Log Stops At | Problem | Solution |
|--------------|---------|----------|
| "Connected with 5 connections" | Hangs entering loop | Check delay calculation |
| "Entering message loop" | Hangs on first publish | RabbitMQ blocking or memory issue |
| "Connection is BLOCKED" | RabbitMQ flow control | Lower message rate or increase RabbitMQ memory |
| "ERROR during publish: ..." | Network/permission issue | Check error message details |
