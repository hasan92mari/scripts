# Server Health Check

A Bash-based DevOps utility for checking the health and basic system status of multiple remote Linux servers through SSH.

The script reads server definitions from an SSH configuration file and uses the SSH aliases defined there to connect to each server.

## Quick Start

### 1. Make the script executable

```bash
chmod +x server_health_check.sh
```

### 2. Configure your SSH hosts

By default, the script reads:

```text
~/.ssh/config
```

Example:

```sshconfig
Host control-plane-4
    HostName 192.168.1.10
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519

Host worker-1
    HostName 192.168.1.11
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
```

The script uses the `Host` aliases directly, so there is no need to specify the IP address, username, or SSH key separately.

### 3. Run the health check

```bash
./server_health_check.sh
```

The script will automatically discover the hosts from:

```text
~/.ssh/config
```

### 4. Use a custom SSH config

You can provide another SSH configuration file with `-f`:

```bash
./server_health_check.sh -f /path/to/ssh_config
```

For example:

```bash
./server_health_check.sh -f ./test-ssh-config
```

### 5. Display help

```bash
./server_health_check.sh -h
```

## What the Script Checks

For every SSH host found in the configuration, the script checks:

- SSH connectivity
- System uptime
- Root filesystem usage
- Memory usage
- Failed SSH login attempts
- Availability of the authentication log

Example output:

```text
[INFO] Using SSH config: /Users/user/.ssh/config
[INFO] Found 3 SSH hosts.
[INFO] Starting health checks...

[INFO] --- Checking Server: control-plane-4 ---

--- System Uptime ---
 23:10  up 12 days, 4:32, 2 users, load averages: 0.32 0.28 0.25

--- Disk Usage (Root /) ---
Used: 41% (20G/50G)

--- Memory Usage ---
Used: 1820MB / Total: 4096MB (44.43%)

--- Security (SSH) ---
Auth Log: /var/log/auth.log
Failed SSH Attempts: 3

[INFO] --- Finished Check: control-plane-4 ---
```

## Connection Timeout

The script is designed to fail quickly when a server cannot be reached.

SSH uses the following options:

```text
ConnectTimeout=3
ConnectionAttempts=1
ServerAliveInterval=2
ServerAliveCountMax=1
```

This means the script does not repeatedly retry an unavailable server for a long time.

If a server does not respond, the output will indicate the problem:

```text
[ERROR] Server did not respond: worker-2
[ERROR] Please check whether the server is running and SSH connectivity is available.
```

The script then continues checking the remaining servers.

---

# Detailed Explanation

## SSH Configuration

Instead of maintaining a separate server list and username/key arguments, the script uses OpenSSH's configuration format.

A typical configuration looks like:

```sshconfig
Host control-plane-4
    HostName 192.168.1.10
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519

Host worker-1
    HostName 192.168.1.11
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
```

The important part for the script is the `Host` alias:

```text
control-plane-4
worker-1
```

When connecting, the script simply runs:

```bash
ssh control-plane-4
```

OpenSSH then resolves the actual:

```text
HostName
User
IdentityFile
Port
```

and other SSH options from the configuration.

This avoids duplicating SSH configuration inside the health-check script.

## Discovering Hosts

The script extracts `Host` entries from the selected SSH configuration file.

Wildcard entries such as:

```sshconfig
Host *
```

are ignored because they represent configuration rules rather than individual servers.

For example:

```sshconfig
Host *
    ServerAliveInterval 60

Host server-1
    HostName 10.0.0.10

Host server-2
    HostName 10.0.0.11
```

The script checks:

```text
server-1
server-2
```

but does not attempt to check:

```text
*
```

## SSH Configuration Validation

Before running the health checks, the script uses:

```bash
ssh -G -F "$ssh_config" "$server"
```

`ssh -G` asks OpenSSH to resolve the configuration for a specific host without establishing a connection.

This allows the script to detect configuration problems before attempting the actual health check.

## Health Checks

### 1. System Uptime

The remote server executes:

```bash
uptime
```

This provides information about how long the system has been running and its current load averages.

### 2. Disk Usage

The script checks the root filesystem:

```bash
df -h /
```

The result is presented in a simplified format:

```text
Used: 41% (20G/50G)
```

### 3. Memory Usage

On Linux systems with the `free` command, the script calculates the current memory usage:

```text
Used: 1820MB / Total: 4096MB (44.43%)
```

If `free` is unavailable, the script reports:

```text
Memory information unavailable: free command not found.
```

### 4. SSH Security Check

The script checks for failed SSH authentication attempts.

It supports the two common Linux authentication log locations:

```text
/var/log/auth.log
/var/log/secure
```

For example:

```text
Auth Log: /var/log/auth.log
Failed SSH Attempts: 3
```

If neither log exists, the script reports:

```text
Failed SSH Attempts: authentication log not found.
```

## Error Handling

The script uses Bash strict mode:

```bash
set -euo pipefail
```

This enables:

- `-e` — exit when an unexpected command failure occurs
- `-u` — detect the use of undefined variables
- `pipefail` — propagate failures through pipelines

Individual server connection failures are handled separately so that one unavailable server does not stop the entire health check.

For example:

```text
[INFO] --- Checking Server: server-1 ---
...
[INFO] --- Finished Check: server-1 ---

[INFO] --- Checking Server: server-2 ---
[ERROR] Server did not respond: server-2

[INFO] --- Checking Server: server-3 ---
...
[INFO] --- Finished Check: server-3 ---
```

## Exit Status

The script returns:

```text
0
```

when all server checks complete successfully.

If one or more servers fail their health check, the script returns:

```text
1
```

This makes the script suitable for automation and CI/CD pipelines where the exit code can be used to determine whether the health-check job succeeded.

## Logging

A temporary log file is created when the script starts:

```text
/tmp/server_health.XXXXXX
```

Informational and error messages are written both to the terminal and to this log during execution.

The temporary log is removed automatically when the script exits.

## Requirements

### Local Machine

- Bash
- OpenSSH client
- Access to an SSH configuration file

The script is designed to work with the default Bash version available on macOS and with modern Bash versions on Linux.

### Remote Servers

The health checks expect a Linux-based remote server with:

- SSH access
- `uptime`
- `df`
- `awk`
- `free` for memory information
- Access to the authentication log for SSH security checks

Some checks may report limited information if a command or log file is unavailable.

## Security Considerations

The script does not store SSH passwords or private keys.

Authentication is delegated to OpenSSH and the configured:

```text
IdentityFile
```

entries in the SSH configuration.

The script only reads the SSH configuration and uses the configured SSH credentials to establish connections.

For production environments, SSH keys should be protected with appropriate filesystem permissions and, where appropriate, a passphrase.

## Project Structure

```text
.
├── server_health_check.sh
└── README.md
```

Run the complete health check with:

```bash
./server_health_check.sh
```

Or specify a custom SSH configuration:

```bash
./server_health_check.sh -f ./ssh_config
```