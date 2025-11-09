# Simple Load Test Guide for RabbitMQ Cluster

## FILES YOU NEED TO COPY FROM WINDOWS TO LINUX

Copy these 6 files from your Windows machine to your Linux test server:

```
simple_load_test.sh                      ← Main script (run this)
simple_load_test.conf                    ← Configuration file (edit this)
test/simple_multiprocess_producer.py     ← Producer program
test/simple_multiprocess_consumer.py     ← Consumer program
test/Dockerfile                          ← Container definition
test/requirements.txt                    ← Python dependencies
```

**Folder structure on Linux server** (create this):
```
/root/rabbitmq-load-test/
├── simple_load_test.sh
├── simple_load_test.conf
└── test/
    ├── simple_multiprocess_producer.py
    ├── simple_multiprocess_consumer.py
    ├── Dockerfile
    └── requirements.txt
```

---

## QUICK CHECKLIST (WHAT TO DO)

- [ ] **Step 1**: Copy 6 files from Windows to Linux test server using WinSCP
- [ ] **Step 2**: SSH into Linux test server
- [ ] **Step 3**: Fix Windows line endings (CRITICAL - see below)
- [ ] **Step 4**: Edit `simple_load_test.conf` (change IPs and passwords)
- [ ] **Step 5**: Run `chmod +x simple_load_test.sh` (make it executable)
- [ ] **Step 6**: Run `./simple_load_test.sh` (execute the test)
- [ ] **Step 7**: Read the comprehensive report with push/pop capacity

**Total time**: ~5 minutes to setup, ~1-2 minutes per test

---

## ⚠️ CRITICAL: Fix Windows Line Endings (Do This First!)

**If you copied files from Windows, you MUST run this command first or you'll get errors!**

After copying files to Linux (Step 2), immediately run:

```bash
cd /root/rabbitmq-load-test

# Fix Windows line endings (CRLF → LF)
sed -i 's/\r$//' simple_load_test.sh
sed -i 's/\r$//' simple_load_test.conf
sed -i 's/\r$//' test/*.py
```

**Why?** Windows uses different line endings (`\r\n`) than Linux (`\n`). This causes the error:
```
/bin/bash^M: bad interpreter: No such file or directory
```

**Alternative method** (if sed doesn't work):
```bash
# Install dos2unix tool
sudo dnf install -y dos2unix

# Convert all files
dos2unix simple_load_test.sh simple_load_test.conf test/*.py
```

**After running one of the above commands, continue with the rest of the steps.**

---

## Table of Contents
1. [What is This?](#what-is-this)
2. [Quick Start (3 Steps)](#quick-start-3-steps)
3. [Understanding the Configuration](#understanding-the-configuration)
4. [Running Your First Test](#running-your-first-test)
5. [Understanding the Results](#understanding-the-results)
6. [Finding Your Cluster's Limit](#finding-your-clusters-limit)
7. [Troubleshooting](#troubleshooting)

---

## What is This?

This is a **beginner-friendly load testing system** for RabbitMQ. It helps you answer:
- **How fast can my cluster send messages?** (Push capacity)
- **How fast can my cluster receive messages?** (Pop capacity)
- **What's the maximum load my cluster can handle?**

### How It Works (Simple Explanation)

Think of it like testing a highway:
- **Producer** = Cars entering the highway
- **RabbitMQ Queue** = The highway itself
- **Consumer** = Cars exiting the highway
- **Load test** = See how many cars can use the highway at once

The test runs two programs:
1. **Producer**: Sends messages to RabbitMQ as fast as possible
2. **Consumer**: Receives messages from RabbitMQ as fast as possible

At the end, you get a report showing:
- How many messages sent/received per second
- Whether your cluster kept up
- Where the bottleneck is (if any)

---

## Quick Start (Complete Step-by-Step)

### Prerequisites
You need:
- **4 Rocky Linux 8 servers**:
  - Server 1 (192.168.1.101) - RabbitMQ node 1
  - Server 2 (192.168.1.102) - RabbitMQ node 2
  - Server 3 (192.168.1.103) - RabbitMQ node 3
  - Server 4 (192.168.1.104) - Load test machine (this is where you'll run the test)
- **RabbitMQ cluster** already running on servers 1-3
- **SSH client** on your Windows machine (PuTTY, MobaXterm, or Windows Terminal)
- **SCP/SFTP client** (WinSCP, FileZilla, or MobaXterm)

**IMPORTANT**: Replace the IP addresses above with your actual server IPs throughout this guide.

---

### Step 1: Copy Files from Windows to Linux Test Server

You have the following files on your Windows machine:
- `simple_load_test.sh`
- `simple_load_test.conf`
- `test/simple_multiprocess_producer.py`
- `test/simple_multiprocess_consumer.py`
- `test/Dockerfile`
- `test/requirements.txt`

#### Option A: Using WinSCP (Recommended for Beginners)

1. **Download and install WinSCP** (free): https://winscp.net/

2. **Connect to your test server (server 4)**:
   - Open WinSCP
   - Host name: `192.168.1.104` (your server 4 IP)
   - User name: Your Linux username (usually `root` or your user)
   - Password: Your Linux password
   - Click "Login"

3. **Create directory on Linux server**:
   - In the right panel (Linux side), navigate to `/root/` or `/home/yourusername/`
   - Right-click → New → Directory
   - Name it: `rabbitmq-load-test`
   - Press Enter

4. **Create subdirectory for test files**:
   - Double-click the `rabbitmq-load-test` folder to enter it
   - Right-click → New → Directory
   - Name it: `test`
   - Press Enter

5. **Copy files**:
   - In the left panel (Windows side), navigate to where you have the files
   - Select `simple_load_test.sh` and `simple_load_test.conf`
   - Drag them to the right panel (into `/root/rabbitmq-load-test/`)
   - Double-click the `test` folder on the right panel
   - On the left panel, go into your `test` folder
   - Select all 4 files: `simple_multiprocess_producer.py`, `simple_multiprocess_consumer.py`, `Dockerfile`, `requirements.txt`
   - Drag them to the right panel (into `/root/rabbitmq-load-test/test/`)

6. **Verify files were copied**:
   - You should see this structure on the Linux side:
     ```
     /root/rabbitmq-load-test/
     ├── simple_load_test.sh
     ├── simple_load_test.conf
     └── test/
         ├── simple_multiprocess_producer.py
         ├── simple_multiprocess_consumer.py
         ├── Dockerfile
         └── requirements.txt
     ```

#### Option B: Using Command Line (SCP)

If you have Windows Terminal with SSH:

```bash
# From your Windows machine, run this command (replace paths and IP):
scp simple_load_test.sh simple_load_test.conf root@192.168.1.104:/root/rabbitmq-load-test/
scp test/* root@192.168.1.104:/root/rabbitmq-load-test/test/
```

---

### Step 2: Connect to Linux Test Server via SSH

1. **Open your SSH client** (PuTTY, MobaXterm, or Windows Terminal)

2. **Connect to server 4**:
   - Host: `192.168.1.104` (your test server IP)
   - Port: `22`
   - Username: Your Linux username
   - Password: Your Linux password

3. **Navigate to the directory**:
   ```bash
   cd /root/rabbitmq-load-test
   ```
   OR if you're not root user:
   ```bash
   cd ~/rabbitmq-load-test
   ```

4. **Verify all files are there**:
   ```bash
   ls -la
   ```

   You should see:
   ```
   simple_load_test.sh
   simple_load_test.conf
   test/
   ```

5. **Check the test directory**:
   ```bash
   ls -la test/
   ```

   You should see:
   ```
   simple_multiprocess_producer.py
   simple_multiprocess_consumer.py
   Dockerfile
   requirements.txt
   ```

**If any files are missing**, go back to Step 1 and copy them again.

---

### Step 3: Edit Configuration File

**IMPORTANT**: You MUST edit this file with your actual server IPs and credentials.

1. **Open the configuration file for editing**:
   ```bash
   nano simple_load_test.conf
   ```

   This opens a text editor in the terminal.

2. **Find and change these lines** (use arrow keys to move):

   Find this section:
   ```bash
   RMQ1_HOST=192.168.1.101
   RMQ2_HOST=192.168.1.102
   RMQ3_HOST=192.168.1.103
   ```

   **Change the IP addresses** to match YOUR RabbitMQ servers.

   Find this section:
   ```bash
   RABBITMQ_ADMIN_USER=admin
   RABBITMQ_ADMIN_PASSWORD=password
   ```

   **Change `admin` and `password`** to your actual RabbitMQ username and password.

   Find this section:
   ```bash
   TEST_HOST=192.168.1.104
   ```

   **Change to the IP of this test server** (the machine you're connected to).

3. **Save the file**:
   - Press `Ctrl+X` (the editor will ask "Save modified buffer?")
   - Press `Y` for "Yes"
   - Press `Enter` to confirm the filename
   - You're back at the command prompt

4. **Verify your changes** (optional but recommended):
   ```bash
   cat simple_load_test.conf | grep HOST
   ```

   This shows all lines with "HOST" - verify your IPs are correct.

---

### Step 4: Make Script Executable

The script needs permission to run. Execute this command:

```bash
chmod +x simple_load_test.sh
```

**What this does**: Marks the file as "executable" (able to run as a program).

**Verify it worked**:
```bash
ls -la simple_load_test.sh
```

You should see: `-rwxr-xr-x` (the `x` means executable). If you see `-rw-r--r--`, run the chmod command again.

---

### Step 5: Run the Test

Now you're ready! Execute this command:

```bash
./simple_load_test.sh
```

**What the `./` means**: "Run the file in the current directory"

**What will happen**:
1. Script checks for required software (Podman/Docker)
2. If missing, it automatically installs it (may ask for password)
3. Validates connection to RabbitMQ servers
4. Builds a Docker container (takes ~30 seconds first time)
5. Runs the load test (default: 60 seconds)
6. Shows comprehensive results

**The test will run for 60 seconds by default** (you configured this in `simple_load_test.conf`).

**DO NOT close the terminal** while it's running. You'll see output like:
```
================================================================================
STEP 1: Checking Prerequisites
================================================================================
[INFO] Checking for Docker or Podman...
[SUCCESS] Found Podman

================================================================================
STEP 2: Loading Configuration
...
```

**Wait for it to finish**. At the end you'll see a comprehensive report.

---

### Step 6: Read the Results

After the test completes, you'll see a report like this:

```
================================================================================
COMPREHENSIVE LOAD TEST REPORT
================================================================================

TEST CONFIGURATION
================================================================================
Target Rate:              10000 messages/second
Message Size:             10 KB
Actual Duration:          60 seconds
...

PRODUCER PERFORMANCE (PUSH CAPACITY)
================================================================================
Total Messages Sent:      600,000 messages
Throughput:               10,000 msg/s
Data Rate:                100 MB/s
Status:                   ✓ TARGET ACHIEVED

CONSUMER PERFORMANCE (POP CAPACITY)
================================================================================
Total Messages Received:  600,000 messages
Throughput:               10,000 msg/s
Data Rate:                100 MB/s
Status:                   ✓ KEEPING UP WITH PRODUCER

QUEUE ANALYSIS
================================================================================
Maximum Queue Depth:      2,345 messages
Final Queue Depth:        0 messages
Status:                   ✓ QUEUE STABLE

CONCLUSION
================================================================================
✓ System handled this load successfully!

Next steps:
  1. Try increasing MESSAGES_PER_SECOND in simple_load_test.conf
  2. Re-run the test to find the maximum capacity
```

**KEY METRICS TO LOOK AT**:
- **Producer Throughput**: How many messages/second your cluster can PUSH
- **Consumer Throughput**: How many messages/second your cluster can POP
- **Status lines**: Look for ✓ (success), ⚠ (warning), or ✗ (problem)

See the "Understanding the Results" section below for detailed explanation.

---

### Step 7: Run Another Test (Optional)

To test with different settings:

1. **Edit configuration**:
   ```bash
   nano simple_load_test.conf
   ```

2. **Change the speed** (find this line):
   ```bash
   MESSAGES_PER_SECOND=10000
   ```

   Change `10000` to a higher number, like `20000` or `50000`

3. **Save** (Ctrl+X, Y, Enter)

4. **Run test again**:
   ```bash
   ./simple_load_test.sh
   ```

Keep increasing until you find where your cluster maxes out (when you see ✗ or ⚠ in the results).

---

## Summary of Commands (Quick Reference)

```bash
# 1. Connect to test server via SSH (from Windows)
# Use PuTTY or Windows Terminal: ssh root@192.168.1.104

# 2. Navigate to directory
cd /root/rabbitmq-load-test

# 3. Edit configuration (first time only)
nano simple_load_test.conf
# (Change IPs and credentials, then Ctrl+X, Y, Enter to save)

# 4. Make script executable (first time only)
chmod +x simple_load_test.sh

# 5. Run the test
./simple_load_test.sh

# 6. To run again with different settings
nano simple_load_test.conf    # Edit settings
./simple_load_test.sh          # Run again
```

That's it! The script does everything automatically:
- Installs required software (Podman, Python)
- Validates connection to RabbitMQ
- Builds test container
- Runs the load test
- Shows comprehensive results

---

## Understanding the Configuration

The `simple_load_test.conf` file has three main sections:

### 1. Test Parameters (What You'll Change Most)

```bash
# How many messages per second to send
MESSAGES_PER_SECOND=10000

# Size of each message in kilobytes
MESSAGE_SIZE_KB=10

# How long to run the test in seconds
TEST_DURATION_SECONDS=60
```

**Examples:**

| Scenario | Messages/sec | Size | Duration | Total Messages | Total Data |
|----------|--------------|------|----------|----------------|------------|
| Light test | 1,000 | 1 KB | 10 sec | 10,000 | ~10 MB |
| Medium test | 10,000 | 10 KB | 60 sec | 600,000 | ~6 GB |
| Heavy test | 50,000 | 10 KB | 60 sec | 3,000,000 | ~30 GB |
| Max test | 150,000 | 100 KB | 100 sec | 15,000,000 | ~1.43 TB |

### 2. Performance Tuning (Advanced)

```bash
# Number of worker processes
PRODUCER_WORKERS=4
CONSUMER_WORKERS=4

# Number of connections each worker creates
PRODUCER_CONNECTIONS_PER_WORKER=5
CONSUMER_CONNECTIONS_PER_WORKER=5
```

**When to change these:**
- **Not achieving target rate?** → Increase workers or connections
- **CPU maxed out?** → You've reached your test machine's limit
- **Network saturated?** → You've reached network bandwidth limit

**Rule of thumb:**
- Start with workers = number of CPU cores on test machine
- Each worker needs 1 CPU core
- More connections helps if network has bandwidth

### 3. RabbitMQ Configuration

```bash
# IP addresses of your 3 RabbitMQ servers
RMQ1_HOST=192.168.1.101
RMQ2_HOST=192.168.1.102
RMQ3_HOST=192.168.1.103

# Credentials
RABBITMQ_ADMIN_USER=admin
RABBITMQ_ADMIN_PASSWORD=password
```

Change these to match your actual setup.

---

## Running Your First Test

### Recommended First Test: Light Load

For your very first test, use these settings:

```bash
MESSAGES_PER_SECOND=1000
MESSAGE_SIZE_KB=1
TEST_DURATION_SECONDS=10
```

This is a **quick validation test** (10 seconds, 10,000 messages, ~10 MB).

**Why start small?**
- Verifies everything works
- Fast (10 seconds)
- Won't overwhelm your cluster
- Easy to understand the output

### Expected Output

You'll see output like this:

```
================================================================================
STEP 1: Checking Prerequisites
================================================================================
[INFO] Checking for Docker or Podman...
[SUCCESS] Found Podman

================================================================================
STEP 2: Loading Configuration
================================================================================
[INFO] Reading simple_load_test.conf...
[SUCCESS] Configuration loaded:
  Target Rate:        1000 messages/second
  Message Size:       1 KB
  Test Duration:      10 seconds
  ...

================================================================================
STEP 7: Running Load Test
================================================================================
[INFO] Test will send approximately:
  Messages: 10000
  Data:     10 MB

[INFO] Starting producer...
[INFO] Starting consumer...
[INFO] Test will run for 10 seconds...

  [5s] Queue depth: 234 messages (max: 456)
  [10s] Queue depth: 0 messages (max: 456)

[SUCCESS] Load test completed

================================================================================
COMPREHENSIVE LOAD TEST REPORT
================================================================================
...
```

### What Happens Behind the Scenes

1. **Validation** (5-10 seconds):
   - Checks for Podman/Docker
   - Tests connection to RabbitMQ
   - Builds container image (first time only, ~30 seconds)

2. **Test Execution** (10 seconds in this example):
   - Producer sends messages
   - Consumer receives messages
   - Script monitors queue depth every 5 seconds

3. **Report Generation** (instant):
   - Analyzes results
   - Shows comprehensive statistics
   - Identifies bottlenecks

**Total time: ~1 minute for first run, ~20 seconds for subsequent runs**

---

## Understanding the Results

The final report has 5 sections:

### 1. Test Configuration
```
Target Rate:              1000 msg/s
Message Size:             1 KB
Actual Duration:          10 seconds
Total Connections:        40
```

This confirms what you configured. "Actual Duration" may differ slightly from configured.

### 2. Producer Performance (PUSH CAPACITY)

```
===============================================================================
PRODUCER PERFORMANCE (PUSH CAPACITY)
===============================================================================
Total Messages Sent:      10,000 messages
Throughput:               1,000 msg/s
Data Rate:                1 MB/s
Target Achievement:       100%
Status:                   ✓ TARGET ACHIEVED
```

**What this means:**
- **Total Messages Sent**: How many messages the producer successfully sent
- **Throughput**: Messages per second (this is your PUSH capacity)
- **Data Rate**: Megabytes per second
- **Target Achievement**: Percentage of your configured target
- **Status**:
  - ✓ TARGET ACHIEVED = Producer can handle this rate
  - ⚠ CLOSE TO TARGET = Producer almost reached target (90-99%)
  - ✗ BELOW TARGET = Producer couldn't keep up

**Example Interpretations:**

| Throughput | Target | Status | What it means |
|------------|--------|--------|---------------|
| 10,000 msg/s | 10,000 msg/s | ✓ ACHIEVED | Cluster can push at 10K msg/s |
| 9,500 msg/s | 10,000 msg/s | ⚠ CLOSE | Almost there, increase workers |
| 7,000 msg/s | 10,000 msg/s | ✗ BELOW | Bottleneck detected |

### 3. Consumer Performance (POP CAPACITY)

```
===============================================================================
CONSUMER PERFORMANCE (POP CAPACITY)
===============================================================================
Total Messages Received:  10,000 messages
Throughput:               1,000 msg/s
Data Rate:                1 MB/s
Status:                   ✓ KEEPING UP WITH PRODUCER
```

**What this means:**
- **Total Messages Received**: How many messages the consumer received
- **Throughput**: Messages per second (this is your POP capacity)
- **Status**:
  - ✓ KEEPING UP = Consumer as fast as producer (95%+)
  - ⚠ FALLING SLIGHTLY BEHIND = Consumer slower (80-95%)
  - ✗ FALLING BEHIND = Consumer much slower (<80%)

**Key insight**: If consumer can't keep up, messages pile up in the queue.

### 4. Queue Analysis

```
===============================================================================
QUEUE ANALYSIS
===============================================================================
Initial Queue Depth:      0 messages
Maximum Queue Depth:      456 messages
Final Queue Depth:        0 messages
Net Queue Growth:         0 messages
Status:                   ✓ QUEUE STABLE (consumer keeping pace)
```

**What this means:**
- **Initial Queue Depth**: Messages in queue before test started
- **Maximum Queue Depth**: Highest number of messages during test
- **Final Queue Depth**: Messages remaining after test
- **Net Queue Growth**: Final - Initial
- **Status**:
  - ✓ QUEUE STABLE = Consumer keeping up (growth < 1,000)
  - ⚠ QUEUE GROWING SLOWLY = Consumer slightly behind (growth 1K-10K)
  - ✗ QUEUE GROWING RAPIDLY = Consumer falling behind (growth > 10K)

**Example Scenarios:**

| Initial | Max | Final | Growth | What happened |
|---------|-----|-------|--------|---------------|
| 0 | 500 | 0 | 0 | Perfect balance, consumer kept up |
| 0 | 50,000 | 5,000 | 5,000 | Consumer slower, queue grew |
| 0 | 10,000 | 0 | 0 | Temporary backlog, caught up at end |

### 5. Bottleneck Analysis

```
===============================================================================
BOTTLENECK ANALYSIS
===============================================================================
✓ Producer achieved target rate
✓ Consumer keeping up with producer
✓ Queue depth manageable

CONCLUSION
✓ System handled this load successfully!

Next steps:
  1. Try increasing MESSAGES_PER_SECOND in simple_load_test.conf
  2. Re-run the test to find the maximum capacity
```

This section tells you:
- **What succeeded** (✓)
- **What struggled** (⚠ or ✗)
- **Specific recommendations** to improve performance
- **Next steps** to find your cluster's limits

---

## Finding Your Cluster's Limit

Follow these steps to find the maximum capacity:

### Step 1: Start Conservative

Use these settings:
```bash
MESSAGES_PER_SECOND=10000
MESSAGE_SIZE_KB=10
TEST_DURATION_SECONDS=60
```

### Step 2: Gradually Increase

If the test shows "✓ TARGET ACHIEVED", increase the rate:

```bash
# Try 20,000 msg/s
MESSAGES_PER_SECOND=20000

# Then 30,000
MESSAGES_PER_SECOND=30000

# Then 50,000
MESSAGES_PER_SECOND=50000

# Keep going...
```

### Step 3: Watch for Signs of Stress

Stop increasing when you see:
- **Producer below target**: "✗ BELOW TARGET (85%)"
- **Queue growing rapidly**: "✗ QUEUE GROWING RAPIDLY"
- **Consumer falling behind**: "✗ FALLING BEHIND"

### Step 4: Fine-Tune

Once you hit the limit, try:

**If producer is the bottleneck:**
```bash
# Increase producer workers (use more CPU)
PRODUCER_WORKERS=8

# Or increase connections
PRODUCER_CONNECTIONS_PER_WORKER=10
```

**If consumer is the bottleneck:**
```bash
# Increase consumer workers
CONSUMER_WORKERS=8

# Or increase connections
CONSUMER_CONNECTIONS_PER_WORKER=10

# Or increase prefetch
CONSUMER_PREFETCH_COUNT=500
```

**If RabbitMQ is the bottleneck:**
- Check RabbitMQ server CPU/memory/disk
- Optimize RabbitMQ configuration
- Consider adding more nodes to cluster

### Step 5: Document Your Findings

Record your results:

| Test | Rate (msg/s) | Size (KB) | Producer ✓/✗ | Consumer ✓/✗ | Max Queue | Result |
|------|--------------|-----------|--------------|--------------|-----------|--------|
| 1 | 10,000 | 10 | ✓ | ✓ | 500 | Success |
| 2 | 30,000 | 10 | ✓ | ✓ | 2,000 | Success |
| 3 | 50,000 | 10 | ✓ | ⚠ | 15,000 | Consumer struggling |
| 4 | 70,000 | 10 | ⚠ | ✗ | 50,000 | Both struggling |

**Your cluster's limit is the highest "Success" rate.**

In this example, the cluster can reliably handle **30,000 msg/s** at 10KB.

---

## Troubleshooting

### Problem: "Could not connect to any RabbitMQ node!"

**Possible causes:**
1. RabbitMQ not running
2. Wrong IP addresses in config
3. Firewall blocking connections
4. Wrong credentials

**Solutions:**

1. **Check RabbitMQ is running:**
   ```bash
   # On each RabbitMQ server, run:
   sudo systemctl status rabbitmq-server
   ```

2. **Test connection manually:**
   ```bash
   # From test server, try:
   curl -u admin:password http://192.168.1.101:15672/api/overview

   # Should return JSON data, not error
   ```

3. **Check firewall:**
   ```bash
   # On RabbitMQ servers, these ports must be open:
   # 5672 (AMQP), 15672 (Management API)

   # Check firewall:
   sudo firewall-cmd --list-all

   # If ports are closed, open them:
   sudo firewall-cmd --permanent --add-port=5672/tcp
   sudo firewall-cmd --permanent --add-port=15672/tcp
   sudo firewall-cmd --reload
   ```

4. **Verify credentials:**
   - Check username and password in `simple_load_test.conf`
   - Try logging into RabbitMQ web UI: http://192.168.1.101:15672

### Problem: "Producer below target" or "Consumer falling behind"

**Cause**: Test machine (server 4) doesn't have enough resources.

**Solutions:**

1. **Increase workers** (if you have more CPU cores):
   ```bash
   # Check how many CPU cores you have:
   nproc

   # Set workers to number of cores:
   PRODUCER_WORKERS=8
   CONSUMER_WORKERS=8
   ```

2. **Increase connections**:
   ```bash
   PRODUCER_CONNECTIONS_PER_WORKER=10
   CONSUMER_CONNECTIONS_PER_WORKER=10
   ```

3. **Check CPU usage during test**:
   ```bash
   # In another terminal, run:
   top

   # Look for python processes at 100% CPU
   # If all cores at 100%, you've maxed out the test machine
   ```

4. **Use a more powerful test machine** (more cores, faster network).

### Problem: "Queue growing rapidly"

**Cause**: Consumer can't keep up with producer.

**Solutions:**

1. **Increase consumer workers/connections** (see above)

2. **Reduce producer rate temporarily**:
   ```bash
   # Lower the target to find sustainable rate
   MESSAGES_PER_SECOND=20000
   ```

3. **Increase prefetch count**:
   ```bash
   CONSUMER_PREFETCH_COUNT=500
   ```

### Problem: Container build fails

**Error**: "Failed to build container!"

**Solutions:**

1. **Check internet connection** (needs to download Python packages)

2. **Try building manually**:
   ```bash
   cd test
   podman build -t rabbitmq-simple-test .

   # Look for specific error messages
   ```

3. **Check disk space**:
   ```bash
   df -h
   # Need at least 2 GB free
   ```

### Problem: Python errors in logs

**Check the logs:**
```bash
cat /tmp/producer_full.log
cat /tmp/consumer_full.log
```

**Common errors:**

1. **"Connection refused"**: RabbitMQ not running or firewall blocking
2. **"Authentication failed"**: Wrong username/password
3. **"No module named 'pika'"**: Container build incomplete, rebuild

### Problem: Test runs but no messages sent/received

**Cause**: Queue name mismatch or permissions issue.

**Solutions:**

1. **Check RabbitMQ web UI**:
   - Go to: http://192.168.1.101:15672
   - Login with admin credentials
   - Click "Queues" tab
   - Look for queue named `simple_load_test_queue`
   - Check if messages are accumulating

2. **Check user permissions**:
   - In RabbitMQ UI, click "Admin" → "Users"
   - Click your username
   - Verify it has permissions on "/" vhost

---

## Advanced Tips

### Tip 1: Run Multiple Tests in Sequence

Create a script to run multiple tests:

```bash
#!/bin/bash

# Test different rates
for rate in 10000 20000 30000 50000; do
    echo "Testing at ${rate} msg/s..."

    # Update config
    sed -i "s/MESSAGES_PER_SECOND=.*/MESSAGES_PER_SECOND=${rate}/" simple_load_test.conf

    # Run test
    ./simple_load_test.sh

    # Save results
    mv /tmp/producer_full.log /tmp/producer_${rate}.log
    mv /tmp/consumer_full.log /tmp/consumer_${rate}.log

    # Wait between tests
    sleep 30
done
```

### Tip 2: Monitor RabbitMQ During Test

In another terminal:

```bash
# Watch RabbitMQ stats in real-time
watch -n 1 'curl -s -u admin:password http://192.168.1.101:15672/api/overview | grep -o "\"message_stats\":{[^}]*}"'
```

### Tip 3: Test Different Message Sizes

Different message sizes stress different parts of the system:

| Size | Stresses | Use case |
|------|----------|----------|
| 1 KB | Message routing, CPU | Notifications, events |
| 10 KB | Balanced | Typical JSON objects |
| 100 KB | Network bandwidth | Images, large payloads |
| 1 MB | Disk I/O, memory | Files, attachments |

---

## Summary

**To run a load test:**
1. Edit `simple_load_test.conf` (set IPs and credentials)
2. Run `./simple_load_test.sh`
3. Read the comprehensive report

**To find cluster limits:**
1. Start with 10,000 msg/s
2. Increase gradually
3. Stop when you see "✗" in the report
4. The previous successful rate is your limit

**Key metrics:**
- **Producer throughput** = Push capacity (how fast you can send)
- **Consumer throughput** = Pop capacity (how fast you can receive)
- **Queue growth** = Balance indicator (consumer keeping up?)

**Need help?** Check the troubleshooting section or examine the logs at:
- `/tmp/producer_full.log`
- `/tmp/consumer_full.log`

---

## Next Steps

Once you've found your cluster's capacity:

1. **Test different scenarios**:
   - Different message sizes
   - Different test durations
   - Different numbers of workers

2. **Optimize if needed**:
   - Tune RabbitMQ configuration
   - Add more cluster nodes
   - Upgrade hardware

3. **Document your findings**:
   - Record maximum sustainable rate
   - Note any bottlenecks
   - Plan capacity for production load

**Remember**: Your production load should be **50-70% of maximum tested capacity** to leave headroom for spikes.

Example: If max tested capacity is 50,000 msg/s, plan for 25,000-35,000 msg/s sustained production load.

---

**Questions or issues?** Check the logs and error messages. Most problems are:
1. Network connectivity (firewall, wrong IPs)
2. Authentication (wrong credentials)
3. Resources (need more CPU/RAM on test server)
