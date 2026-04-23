#!/bin/bash
# Claude Code CLI Security Hook
# Analyzes CLI commands and approves read-only operations, prompts for modifying ones

set -e

# Configuration
CONFIG_FILE="${HOME}/.claude/cli-commands.json"
LOG_FILE="${HOME}/.claude/hook-approvals.log"

# Parse JSON configuration using jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required for this hook. Please install jq to continue." >&2
    exit 1
fi

# Parse command from input
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
CHAINED=$(echo "$INPUT" | jq -r '.tool_input.chained // false')

# Debug logging
log_debug() {
    if [[ "${HOOK_DEBUG:-false}" == "true" ]]; then
        echo "[DEBUG] $1" >&2
    fi
}

# Log approvals/decisions
log_approval() {
    local status=$1
    local reason=$2
    local timestamp=$(date -Iseconds)
    if [[ -f "$LOG_FILE" ]]; then
        echo "[$timestamp] [$status] $COMMAND - $reason" >> "$LOG_FILE"
    fi
}

# Check if command exists in read-only list
is_read_only_unix() {
    local cmd=$1

    # Simple check for basic read-only commands
    case "$cmd" in
        # Information commands
        ls*|pwd|cd|echo*|cat*|head*|tail*|grep*|find*|which*|whoami|id|groups|\
        ps*|top|htop|df|du|free|uname|hostname|date|uptime|w|last|lastlog|lsof*|vmstat|iostat|netstat|
        ss|ip\ addr*|ip\ link*|ip\ route*|psql\ -l|mysql\ -e\ "show\ databases"*)
            return 0
            ;;
        # Git read-only operations
        git\ status*|git\ log*|git\ show*|git\ diff*|git\ branch*|git\ remote\ -v*|git\ tag*|git\ describe*)
            return 0
            ;;
        # Package managers list operations
        npm\ list*|yarn\ list*|pip\ list*|composer\ show*|gem\ list*)
            return 0
            ;;
        # Docker info commands
        docker\ ps*|docker\ images*|docker\ inspect*|docker\ version*|docker\ info*|docker\ stats*)
            return 0
            ;;
        # Kubectl safe operations
        kubectl\ get*|kubectl\ describe*|kubectl\ logs*|kubectl\ version*)
            return 0
            ;;
        # Terraform show operations
        terraform\ show*|terraform\ output*|terraform\ state\ list*|terraform\ providers*)
            return 0
            ;;
        # AWS describe/list operations (simplified check)
        aws\ *\ describe-*|aws\ *\ list-*|aws\ s3\ ls*|aws\ ec2\ describe-instances|\
        aws\ s3api\ head-object|aws\ s3api\ list-*)
            return 0
            ;;
    esac

    # For more complex checks, consult the JSON configuration
    if [[ -f "$CONFIG_FILE" ]]; then
        local unix_readonly=$(jq -r '.read_only_commands.unix[]' "$CONFIG_FILE" 2>/dev/null | grep -x "${cmd%% *}" || true)
        if [[ -n "$unix_readonly" ]]; then
            return 0
        fi
    fi

    return 1
}

# Check if command matches a modifying pattern
is_modifying_unix() {
    local cmd=$1

    # Check for modifying patterns
    case "$cmd" in
        # File operations
        rm*|rmdir*|mv*|cp*|touch*|mkdir*|chmod*|chown*|chgrp*|ln\ -s*|
        # User management
        useradd*|userdel*|usermod*|groupadd*|groupdel*|passwd*|
        # System operations
        mount*|umount*|shutdown*|reboot*|systemctl\ (stop|start|restart|enable|disable)*|
        service\ (stop|start|restart)|halt|poweroff|
        # Package managers
        apt-get*|apt*|yum*|dnf*|rpm*|dpkg*|pip\ (install|uninstall)*|
        npm\ (install|uninstall)|yarn\ (add|remove)|composer\ (require|remove)*|
        # Database operations
        mysql*|psql*|mongo*|redis-cli*|sqlite3*|createdb*|dropdb*|
        # Network operations
        curl\ -X\ (POST|PUT|DELETE|PATCH)*|wget\ (without\ --spider)|scp*|sftp*|
        # File editors and redirects
        vi*|nano*|emacs*>|>*>|>>*|sed\ -i*|awk\ -i*)
            return 0
            ;;
    esac

    # Check JSON configuration for modifying patterns
    if [[ -f "$CONFIG_FILE" ]]; then
        local modifying_patterns=$(jq -r '.modifying_patterns.unix[]' "$CONFIG_FILE" 2>/dev/null)
        for pattern in $modifying_patterns; do
            if [[ "$cmd" == $pattern* ]]; then
                return 0
            fi
        done
    fi

    return 1
}

# Parse chained commands (simple version)
parse_commands() {
    local full_cmd=$1
    local commands=()

    # Replace newlines with semicolons for consistent parsing
    full_cmd=$(echo "$full_cmd" | tr '\n' ';')

    # Split by common chain operators (simplified)
    IFS='&|;' read -ra commands_array <<< "$full_cmd"

    for cmd in "${commands_array[@]}"; do
        # Clean up the command
        cmd=$(echo "$cmd" | sed 's/^ *//;s/ *$//;s/^&&//;s/^||//;s/^|//')
        if [[ -n "$cmd" ]]; then
            commands+=("$cmd")
        fi
    done

    echo "${commands[@]}"
}

# Analyze command and return status
analyze_command() {
    local cmd=$1

    log_debug "Analyzing command: $cmd"

    # Check if it's read-only
    if is_read_only_unix "$cmd"; then
        echo "readonly"
        return
    fi

    # Check if it's modifying
    if is_modifying_unix "$cmd"; then
        echo "modifying"
        return
    fi

    # Ambiguous - needs deeper analysis
    echo "ambiguous"
}

# Exit with code 0 for approval, 1 for denial
main() {
    log_debug "Hook started with command: $COMMAND"
    log_debug "Chained: $CHAINED"

    if [[ -z "$COMMAND" ]]; then
        log_debug "No command provided"
        exit 0  # Allow empty commands
    fi

    # Parse commands (handle both single and chained)
    if [[ "$CHAINED" == "true" ]] || [[ "$COMMAND" == *"&&"* ]] || [[ "$COMMAND" == *"|"* ]] || [[ "$COMMAND" == *";"* ]]; then
        IFS=' ' read -ra commands <<< "$(parse_commands "$COMMAND")"
    else
        commands=("$COMMAND")
    fi

    log_debug "Parsed ${#commands[@]} command(s)"

    # Analyze each command
    local modifying_commands=()
    local ambiguous_commands=()
    local readonly_commands=()

    for cmd in "${commands[@]}"; do
        local status=$(analyze_command "$cmd")
        log_debug "Command '$cmd' status: $status"

        case "$status" in
            "readonly")
                readonly_commands+=("$cmd")
                ;;
            "modifying")
                modifying_commands+=("$cmd")
                ;;
            "ambiguous")
                ambiguous_commands+=("$cmd")
                ;;
        esac
    done

    log_debug "Read-only: ${readonly_commands[*]}"
    log_debug "Modifying: ${modifying_commands[*]}"
    log_debug "Ambiguous: ${ambiguous_commands[*]}"

    # Decision logic
    if [[ ${#modifying_commands[@]} -eq 0 && ${#ambiguous_commands[@]} -eq 0 ]]; then
        # All commands are read-only or known safe
        log_approval "AUTO-APPROVE" "All commands are read-only"
        log_debug "Auto-approving all read-only commands"
        exit 0
    elif [[ ${#modifying_commands[@]} -gt 0 ]]; then
        log_approval "DENY" "Modifying commands detected"
        log_debug "Denying due to modifying commands"
        exit 1
    else
        # Only ambiguous commands - defer to prompt hook
        log_approval "AMBIGUOUS" "Ambiguous commands detected"
        log_debug "Deferring to prompt hook for ambiguous commands"
        exit 1
    fi
}

# Run main function
main