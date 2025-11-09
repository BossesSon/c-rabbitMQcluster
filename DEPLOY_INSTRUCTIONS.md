# Quick Deployment Instructions

## Files Changed
1. `simple_load_test.sh` - Added unbuffered Python output
2. `test/simple_multiprocess_producer.py` - Added detailed debug logging

## What to Copy to Linux
Copy these **2 files** from Windows to Linux (overwrite existing):
- `simple_load_test.sh`
- `test/simple_multiprocess_producer.py`

## Commands to Run on Linux

```bash
# 1. Go to directory
cd /root/rabbitmq-load-test

# 2. Fix line endings (CRITICAL!)
dos2unix simple_load_test.sh
dos2unix test/simple_multiprocess_producer.py

# 3. Remove old container (force rebuild)
podman rmi rabbitmq-simple-test

# 4. Run test
./simple_load_test.sh
```

## What You'll See in Logs

The producer log will now show **detailed progress**:

```
[Producer Worker 0] Starting initialization...
[Producer Worker 0] Target rate: 2500.0 msg/s, Delay: 0.000080s
[Producer Worker 0] Creating message body of 10240 bytes...
[Producer Worker 0] Message body created successfully
[Producer Worker 0] Connected with 5 connections to RabbitMQ
[Producer Worker 0] Entering message loop. Delay between messages: 0.000080s
[Producer Worker 0] SUCCESS! First message sent       ← THIS IS KEY!
[Producer Worker 0] Progress: 1000 messages sent
[Producer Worker 0] Progress: 2000 messages sent
...
```

## What to Look For

### If it works:
- You'll see "SUCCESS! First message sent"
- Progress messages every 1000 messages
- Messages accumulate in RabbitMQ

### If it hangs:
Log will stop at one of these lines (tells us WHERE):
- Stops at "Connected with 5 connections" → Hanging when entering loop
- Stops at "Entering message loop" → Hanging on first publish
- Shows "Connection is BLOCKED" → RabbitMQ flow control blocking

### If there are errors:
You'll see:
- "ERROR during publish: [error message]"
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
