#!/usr/bin/env bash
#
# server_health_check.sh
#
# Check the health of multiple SSH hosts defined in an SSH config file.
#
# Usage:
#   ./server_health_check.sh
#   ./server_health_check.sh -f <ssh_config_file>
#
# By default, the script uses:
#   ~/.ssh/config
#
# The SSH config should contain entries such as:
#
#   Host Host1
#       HostName 192.168.1.10
#       User admin
#       IdentityFile ~/.ssh/id_ed25519
#
#   Host Host2
#       HostName 192.168.1.20
#       User ubuntu
#       IdentityFile ~/.ssh/server_key
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Global Constants
# ---------------------------------------------------------------------------

readonly DEFAULT_SSH_CONFIG="${HOME}/.ssh/config"
readonly LOG_FILE="$(mktemp /tmp/server_health.XXXXXX)"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info() {
    echo "[INFO] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE" >&2
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

print_usage() {
    cat << EOF
Usage: $0 [-f <ssh_config_file>] [-h]

Options:
    -f <file>    Path to a custom SSH config file.
                 Default: ~/.ssh/config

    -h           Display this help message.

Examples:
    $0
    $0 -f ~/.ssh/config
    $0 -f /path/to/custom_ssh_config
EOF
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
    rm -f "$LOG_FILE"
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# SSH Config
# ---------------------------------------------------------------------------

# Extract Host entries from the SSH config.
#
# We intentionally only extract actual Host aliases here.
# HostName, User and IdentityFile are resolved by OpenSSH itself
# using "ssh -G".
#
get_ssh_hosts() {
    local config_file="$1"

    awk '
        /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
            for (i = 2; i <= NF; i++) {

                # Ignore wildcard Host patterns.
                if ($i !~ /[*?!]/) {
                    print $i
                }
            }
        }
    ' "$config_file"
}

# ---------------------------------------------------------------------------
# Server Health Check
# ---------------------------------------------------------------------------

check_server() {
    local server="$1"
    local ssh_config="$2"
    log_info "--- Checking Server: $server ---"
    # -----------------------------------------------------------------------
    # Validate SSH configuration
    # -----------------------------------------------------------------------
    if ! ssh -G -F "$ssh_config" "$server" >/dev/null 2>&1; then
        log_error "SSH configuration could not be resolved for: $server"
        log_error "Skipping server: $server"
        return 1
    fi
    # -----------------------------------------------------------------------
    # Run remote health checks
    #
    # Connection settings:
    #   ConnectTimeout=3       -> wait max 3 seconds for connection
    #   ConnectionAttempts=1  -> do not retry the connection
    #   ServerAliveInterval=2 -> check connection every 2 seconds
    #   ServerAliveCountMax=1 -> terminate if server stops responding
    # -----------------------------------------------------------------------
    if ssh \
        -n \
        -F "$ssh_config" \
        -o ConnectTimeout=3 \
        -o ConnectionAttempts=1 \
        -o ServerAliveInterval=2 \
        -o ServerAliveCountMax=1 \
        "$server" << 'EOF'
echo "--- System Uptime ---"
uptime
echo "--- Disk Usage (Root /) ---"
df -h / | awk '
    NR == 2 {
        printf "Used: %s (%s/%s)\n", $5, $3, $2
    }
'
echo "--- Memory Usage ---"
if command -v free >/dev/null 2>&1; then
    free -m | awk '
        NR == 2 {
            printf "Used: %sMB / Total: %sMB (%.2f%%)\n",
                   $3, $2, ($3 / $2) * 100
        }
    '
else
    echo "Memory information unavailable: free command not found."
fi
echo "--- Security (SSH) ---"
AUTH_LOG=""
if [[ -f /var/log/auth.log ]]; then
    AUTH_LOG="/var/log/auth.log"
elif [[ -f /var/log/secure ]]; then
    AUTH_LOG="/var/log/secure"
fi
if [[ -n "$AUTH_LOG" ]]; then
    failed_attempts=$(
        grep -c "Failed password" "$AUTH_LOG" || true
    )
    echo "Auth Log: $AUTH_LOG"
    echo "Failed SSH Attempts: $failed_attempts"
else
    echo "Failed SSH Attempts: authentication log not found."
fi
EOF
    then
        log_info "--- Finished Check: $server ---"
        return 0
    fi
    # -----------------------------------------------------------------------
    # SSH connection failed
    # -----------------------------------------------------------------------
    log_error "Server did not respond: $server"
    log_error "Please check whether the server is running and SSH connectivity is available."
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {

    local ssh_config="$DEFAULT_SSH_CONFIG"

    # -----------------------------------------------------------------------
    # Argument Parsing
    # -----------------------------------------------------------------------

    while getopts ":f:h" opt; do

        case "$opt" in

            f)
                ssh_config="$OPTARG"
                ;;

            h)
                print_usage
                exit 0
                ;;

            \?)
                log_error "Invalid option: -$OPTARG"
                print_usage
                exit 1
                ;;

            :)
                log_error "Option -$OPTARG requires an argument."
                print_usage
                exit 1
                ;;

        esac

    done

    # -----------------------------------------------------------------------
    # Input Validation
    # -----------------------------------------------------------------------

    if [[ ! -f "$ssh_config" ]]; then
        log_error "SSH config file not found: $ssh_config"
        exit 1
    fi

    if [[ ! -r "$ssh_config" ]]; then
        log_error "SSH config file is not readable: $ssh_config"
        exit 1
    fi

    log_info "Using SSH config: $ssh_config"

    # -----------------------------------------------------------------------
    # Extract Hosts
    # -----------------------------------------------------------------------

    servers=()

    while IFS= read -r server; do
        [[ -n "$server" ]] && servers+=("$server")
    done < <(get_ssh_hosts "$ssh_config")

    if [[ ${#servers[@]} -eq 0 ]]; then
        log_error "No valid SSH hosts found in: $ssh_config"
        exit 1
    fi

    log_info "Found ${#servers[@]} SSH hosts."
    log_info "Starting health checks..."

    # -----------------------------------------------------------------------
    # Health Checks
    # -----------------------------------------------------------------------

    local failed_servers=0

    for server in "${servers[@]}"; do

        if ! check_server "$server" "$ssh_config"; then
            ((failed_servers++))
            log_error "Server check failed: $server"

        fi  

        echo

    done

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------

    local total_servers="${#servers[@]}"
    local successful_servers=$((total_servers - failed_servers))

    log_info "========================================"
    log_info "Health Check Summary"
    log_info "========================================"
    log_info "Total servers:     $total_servers"
    log_info "Successful checks: $successful_servers"
    log_info "Failed checks:     $failed_servers"
    log_info "========================================"

    if [[ "$failed_servers" -gt 0 ]]; then
        log_error "Some server checks failed."
        exit 1
    fi

    log_info "All server checks completed successfully."
}

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

main "$@"