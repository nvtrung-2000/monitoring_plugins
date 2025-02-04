#!/usr/bin/env bash
# Using /usr/bin/env to ensure the script uses the bash interpreter in the PATH

set -euo pipefail
# -e: exit immediately when a command exits with a non-zero status
# -u: treat unset variables as an error and exit immediately
# -o pipefail: the return value of a pipeline is the status of the last command to exit with a non-zero status

###############################################################################
# Function: usage
# Displays help information about how to run this script.
###############################################################################
usage() {
    cat <<EOF
Usage: ${0##*/} -w|--warning <warning_threshold> -c|--critical <critical_threshold>

Options:
  -w, --warning <warning_threshold>
      Set the warning threshold for the number of logged-in users.
      (Must be a positive integer greater than 0.)
  -c, --critical <critical_threshold>
      Set the critical threshold for the number of logged-in users.
      (Must be a positive integer and greater than or equal to the warning threshold.)
  -h, --help
      Display this help message and exit.

Examples:
  ${0##*/} --warning 10 --critical 15
  (For use in a Nagios command definition:)
      command[check_users]=/usr/bin/env bash /path/to/check_users.sh --warning 10 --critical 15

EOF
    exit 3
}

###############################################################################
# Function: is_number
# Checks if the provided argument is a valid positive integer.
###############################################################################
is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

###############################################################################
# Function: validate_thresholds
# Validates the warning and critical thresholds provided via command-line.
###############################################################################
validate_thresholds() {
    if [[ -z "${WARNING_THRESHOLD:-}" || -z "${CRITICAL_THRESHOLD:-}" ]]; then
        echo "UNKNOWN - Both warning and critical thresholds must be provided." >&2
        usage
    fi

    if ! is_number "$WARNING_THRESHOLD" || ! is_number "$CRITICAL_THRESHOLD"; then
        echo "UNKNOWN - Thresholds must be positive integers." >&2
        usage
    fi

    if [[ "$WARNING_THRESHOLD" -le 0 || "$CRITICAL_THRESHOLD" -le 0 ]]; then
        echo "UNKNOWN - Thresholds must be greater than 0." >&2
        exit 3
    fi

    if [[ "$CRITICAL_THRESHOLD" -lt "$WARNING_THRESHOLD" ]]; then
        echo "UNKNOWN - Critical threshold must be greater than or equal to the warning threshold." >&2
        exit 3
    fi
}

###############################################################################
# Function: check_command_exists
# Checks if the required command is available on the system.
###############################################################################
check_command_exists() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "UNKNOWN - Required command '$1' not found." >&2
        exit 3
    fi
}

###############################################################################
# Function: get_user_count
# Retrieves the count of logged-in users using the 'who' command.
###############################################################################
get_user_count() {
    local count
    count=$(timeout 5 who | wc -l) || {
        echo "UNKNOWN - Timeout or error while fetching user count." >&2
        exit 3
    }
    # Remove any whitespace
    count=$(echo "$count" | tr -d ' ')
    if ! is_number "$count"; then
        echo "UNKNOWN - Retrieved user count is not a valid number." >&2
        exit 3
    fi
    echo "$count"
}

###############################################################################
# Check for the existence of required commands before execution
###############################################################################
for cmd in timeout who date wc; do
    check_command_exists "$cmd"
done

###############################################################################
# Command-line argument parsing
###############################################################################
if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--warning)
            if [[ -n "${2:-}" ]]; then
                WARNING_THRESHOLD="$2"
                shift 2
            else
                echo "UNKNOWN - Missing argument for option $1." >&2
                usage
            fi
            ;;
        -c|--critical)
            if [[ -n "${2:-}" ]]; then
                CRITICAL_THRESHOLD="$2"
                shift 2
            else
                echo "UNKNOWN - Missing argument for option $1." >&2
                usage
            fi
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "UNKNOWN - Invalid option: $1" >&2
            usage
            ;;
    esac
done

readonly WARNING_THRESHOLD
readonly CRITICAL_THRESHOLD

validate_thresholds

###############################################################################
# Retrieve the number of logged-in users
###############################################################################
user_count=$(get_user_count)

###############################################################################
# Prepare performance data in Nagios format: users=value;warn;crit;min;max
###############################################################################
perfdata="users=${user_count};${WARNING_THRESHOLD};${CRITICAL_THRESHOLD};;"

###############################################################################
# Compare the user count against the thresholds and output the appropriate status
###############################################################################
if [[ "$user_count" -ge "$CRITICAL_THRESHOLD" ]]; then
    echo "CRITICAL - ${user_count} users logged in | ${perfdata}"
    exit 2
elif [[ "$user_count" -ge "$WARNING_THRESHOLD" ]]; then
    echo "WARNING - ${user_count} users logged in | ${perfdata}"
    exit 1
else
    echo "OK - ${user_count} users logged in | ${perfdata}"
    exit 0
fi
