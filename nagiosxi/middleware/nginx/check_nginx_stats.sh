#!/usr/bin/bash

# Plugin for NagiosXI to check Nginx Status
# check_nginx_status.sh
# Author  : nvtrung16122000@gmail.com
#
# Help : ./check_nginx_stats.sh --help

# Default values
url="/nginx_status"
no_keepalives=false
warning=""
critical=""
port=""
hostname="localhost"
timeout=10
state_file="/tmp/nginx_status_${hostname}_${port}.state"

# Exit codes for Nagios
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Function to display usage
usage() {
    echo "Usage: $0 -H <hostname> -p <port> -u <url> [-w <warning>] [-c <critical>] [--no-keepalives]"
    echo "Options:"
    echo "  -H, --hostname      Hostname or IP address (default: localhost)"
    echo "  -p, --port          Port number"
    echo "  -u, --url           Nginx Status URL (usually /nginx_status)"
    echo "  -w, --warning       Warning threshold for Active Connections count"
    echo "  -c, --critical      Critical threshold for Active Connections count"
    echo "      --no-keepalives Use when nginx config has 'keepalive_timeout 0'"
    echo "  -t, --timeout       Connection timeout (default: 10s)"
    echo "  -h, --help          Display usage information"
    exit $STATE_UNKNOWN
}

# Function to check warning/critical thresholds
# Returns 1 if threshold is exceeded, 0 if normal
check_threshold() {
    local value=$1
    local threshold=$2
    
    # Empty threshold means no warning
    if [[ -z "$threshold" ]]; then
        return 0
    fi
    
    # Special case for range with '@' prefix (inside range)
    if [[ $threshold == @* ]]; then
        local range=${threshold:1}  # Remove '@' prefix
        
        # Range with colon
        if [[ $range == *:* ]]; then
            local min=${range%%:*}
            local max=${range##*:}
            
            # Handle empty values
            [[ -z "$min" ]] && min=0
            [[ -z "$max" ]] && max=infinity
            
            # Check if value is within range (warning condition)
            if [[ $max == "infinity" ]]; then
                (( value >= min )) && return 1 || return 0
            else
                (( value >= min && value <= max )) && return 1 || return 0
            fi
        else
            # Single value (warn if equal)
            (( value == range )) && return 1 || return 0
        fi
    else
        # Regular threshold (outside range)
        
        # Range with colon
        if [[ $threshold == *:* ]]; then
            local min=${threshold%%:*}
            local max=${threshold##*:}
            
            # Handle empty values
            [[ -z "$min" ]] && min=0
            [[ -z "$max" ]] && max=infinity
            
            # Check if value is outside range (warning condition)
            if [[ $max == "infinity" ]]; then
                (( value < min )) && return 1 || return 0
            else
                (( value < min || value > max )) && return 1 || return 0
            fi
        else
            # Single value (warn if greater than or equal)
            (( value >= threshold )) && return 1 || return 0
        fi
    fi
}

# Process command line parameters
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H|--hostname)
            hostname="$2"
            shift 2
            ;;
        -p|--port)
            port="$2"
            shift 2
            ;;
        -u|--url)
            url="$2"
            shift 2
            ;;
        -w|--warning)
            warning="$2"
            shift 2
            ;;
        -c|--critical)
            critical="$2"
            shift 2
            ;;
        --no-keepalives)
            no_keepalives=true
            shift
            ;;
        -t|--timeout)
            timeout="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "UNKNOWN: Undefined option: $1"
            usage
            ;;
    esac
done

# Check required parameters
if [[ -z "$port" ]]; then
    echo "UNKNOWN: Missing port parameter"
    usage
fi

# Update state file path with hostname and port
state_file="/tmp/${url}_${hostname}_${port}.state"

# Create URL to check
request_url="http://${hostname}:${port}${url}"

# Get current timestamp
current_time=$(date +%s)

# Get Nginx status information
status_output=$(curl -s --max-time "$timeout" "$request_url" 2>&1)
curl_exit_code=$?

if [[ $curl_exit_code -ne 0 ]]; then
    echo "CRITICAL: Unable to connect to Nginx status - curl error: $curl_exit_code - $status_output"
    exit $STATE_CRITICAL
fi

# Parse Nginx status results
active_connections=$(echo "$status_output" | grep -i "Active connections" | awk '{print $3}')
server_accepts=$(echo "$status_output" | awk '/server accepts/ {getline; print $1}')
server_handled=$(echo "$status_output" | awk '/server accepts/ {getline; print $2}')
server_requests=$(echo "$status_output" | awk '/server accepts/ {getline; print $3}')
reading=$(echo "$status_output" | grep -i "Reading" | awk '{print $2}')
writing=$(echo "$status_output" | grep -i "Writing" | awk '{print $4}')
waiting=$(echo "$status_output" | grep -i "Waiting" | awk '{print $6}')

# Check if parsing was successful
if [[ -z "$active_connections" || ! "$active_connections" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: Failed to parse Active connections"
    exit $STATE_UNKNOWN
fi

if [[ -z "$server_accepts" || ! "$server_accepts" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: Failed to parse Server accepts"
    exit $STATE_UNKNOWN
fi

if [[ -z "$server_handled" || ! "$server_handled" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: Failed to parse Server handled"
    exit $STATE_UNKNOWN
fi

if [[ -z "$server_requests" || ! "$server_requests" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: Failed to parse Server requests"
    exit $STATE_UNKNOWN
fi

if [[ -z "$reading" || ! "$reading" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: Failed to parse Reading"
    exit $STATE_UNKNOWN
fi

if [[ -z "$writing" || ! "$writing" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: Failed to parse Writing"
    exit $STATE_UNKNOWN
fi

if [[ -z "$waiting" || ! "$waiting" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: Failed to parse Waiting"
    exit $STATE_UNKNOWN
fi

# Initialize rates
connections_per_sec=0
requests_per_sec=0

# Read previous state if available
if [[ -f "$state_file" ]]; then
    prev_time=$(awk -F':' '/^time:/ {print $2}' "$state_file")
    prev_accepts=$(awk -F':' '/^accepts:/ {print $2}' "$state_file")
    prev_requests=$(awk -F':' '/^requests:/ {print $2}' "$state_file")
    
    # Calculate elapsed time
    elapsed_time=$((current_time - prev_time))
    
    # Avoid division by zero
    if [[ $elapsed_time -gt 0 ]]; then
        # Calculate rates if previous values are valid numbers
        if [[ -n "$prev_accepts" && "$prev_accepts" =~ ^[0-9]+$ && "$server_accepts" -ge "$prev_accepts" ]]; then
            connections_per_sec=$(( (server_accepts - prev_accepts) / elapsed_time ))
        fi
        
        if [[ -n "$prev_requests" && "$prev_requests" =~ ^[0-9]+$ && "$server_requests" -ge "$prev_requests" ]]; then
            requests_per_sec=$(( (server_requests - prev_requests) / elapsed_time ))
        fi
    fi
fi

# Write current state for next run
cat > "$state_file" << EOF
time:${current_time}
accepts:${server_accepts}
requests:${server_requests}
EOF

# Check data consistency
if (( server_accepts < server_handled )); then
    echo "CRITICAL: Inconsistent Nginx statistics - Accepted ($server_accepts) < Handled ($server_handled)"
    exit $STATE_CRITICAL
fi

if [[ "$no_keepalives" = true ]] && (( server_handled < server_requests )); then
    echo "CRITICAL: Inconsistent Nginx statistics - Handled ($server_handled) < Requests ($server_requests) with no-keepalives option"
    exit $STATE_CRITICAL
fi

# Check thresholds for Active Connections
status=$STATE_OK
status_msg="OK"

# Check critical threshold first
if [[ -n "$critical" ]]; then
    check_threshold "$active_connections" "$critical"
    if [[ $? -ne 0 ]]; then
        status=$STATE_CRITICAL
        status_msg="CRITICAL"
    fi
fi

# Then check warning threshold if not already in critical state
if [[ $status -eq $STATE_OK && -n "$warning" ]]; then
    check_threshold "$active_connections" "$warning"
    if [[ $? -ne 0 ]]; then
        status=$STATE_WARNING
        status_msg="WARNING"
    fi
fi

# Prepare performance data - now including port
perfdata="port=$port;;;; active_connections=$active_connections;$warning;$critical;0; connections_per_sec=$connections_per_sec;;;0; requests_per_sec=$requests_per_sec;;;0; reading=$reading;;;0; writing=$writing;;;0; accepted=$server_accepts;;;0; handled=$server_handled;;;0; requests=$server_requests;;;0;"

# Output results in the requested format with performance data
echo "$status_msg: Active connections = $active_connections, Connections/sec = $connections_per_sec, Requests/sec = $requests_per_sec, Reading = $reading, Writing = $writing, Accepted = $server_accepts, Handled = $server_handled, Requests = $server_requests | $perfdata"
exit $status