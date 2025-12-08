#!/usr/bin/env bash
set -u

# ==============================
# Globals / Defaults
# ==============================

CONFIG_FILE=""

NAME=""
COMMAND=""
RESTART_POLICY="always"

MAX_CPU_PCT=0
MAX_MEM_MB=0
CHECK_INTERVAL=2

LOG_DIR="./logs"
PID_DIR="/tmp/process-supervisor"

SUPERVISOR_PID_FILE=""
CHILD_PID_FILE=""

running=true
child_pid=""
watchdog_pid=""

# ==============================
# Helper: Logging
# ==============================

log_init() {
    mkdir -p "$LOG_DIR" "$PID_DIR"
}

log_file() {
    local date_part
    date_part=$(date +%F)
    echo "$LOG_DIR/${NAME}_${date_part}.log"
}

log() {
    local ts msg
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    msg="$*"
    printf "%s [%s] %s\n" "$ts" "$NAME" "$msg" | tee -a "$(log_file)"
}

# ==============================
# Helper: Config loading
# ==============================

load_config() {
    CONFIG_FILE="$1"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Config not found: $CONFIG_FILE" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    . "$CONFIG_FILE"

    if [[ -z "${NAME:-}" || -z "${COMMAND:-}" ]]; then
        echo "Config must set NAME and COMMAND" >&2
        exit 1
    fi

    SUPERVISOR_PID_FILE="$PID_DIR/${NAME}.supervisor.pid"
    CHILD_PID_FILE="$PID_DIR/${NAME}.child.pid"

    log_init
}

# ==============================
# Helper: PID / Status
# ==============================

is_alive() {
    local pid="$1"
    if [[ -z "$pid" ]]; then
        return 1
    fi
    kill -0 "$pid" 2>/dev/null
}

read_pid_file() {
    local file="$1"
    [[ -f "$file" ]] && cat "$file" 2>/dev/null || echo ""
}

# ==============================
# Signal Handlers
# ==============================

on_term() {
    log "Received termination signal, shutting down supervisor..."

    running=false

    if [[ -n "$child_pid" ]] && is_alive "$child_pid"; then
        log "Sending SIGTERM to child PID $child_pid"
        kill -TERM "$child_pid" 2>/dev/null || true
    fi

    if [[ -n "$watchdog_pid" ]] && is_alive "$watchdog_pid"; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
    fi
}

setup_traps() {
    trap on_term INT TERM
}

# ==============================
# Resource Monitoring
# ==============================

get_cpu_pct() {
    local pid="$1"
    ps -o %cpu= -p "$pid" 2>/dev/null | awk '{printf "%d\n", $1}'
}

get_mem_mb() {
    local pid="$1"
    ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%d\n", $1/1024}'
}

watchdog_loop() {
    local pid="$1"

    while is_alive "$pid"; do
        if (( MAX_CPU_PCT > 0 )); then
            local cpu
            cpu=$(get_cpu_pct "$pid" || echo 0)
            if [[ -n "$cpu" ]] && (( cpu > MAX_CPU_PCT )); then
                log "CPU limit exceeded: ${cpu}%% > ${MAX_CPU_PCT}%%, killing PID $pid"
                kill -TERM "$pid" 2>/dev/null || true
            fi
        fi

        if (( MAX_MEM_MB > 0 )); then
            local mem
            mem=$(get_mem_mb "$pid" || echo 0)
            if [[ -n "$mem" ]] && (( mem > MAX_MEM_MB )); then
                log "Memory limit exceeded: ${mem}MB > ${MAX_MEM_MB}MB, killing PID $pid"
                kill -TERM "$pid" 2>/dev/null || true
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

start_watchdog() {
    watchdog_loop "$child_pid" &
    watchdog_pid=$!
}

# ==============================
# Child Process Management
# ==============================

start_child() {
    log "Starting child: $COMMAND"
    bash -c "$COMMAND" &
    child_pid=$!
    echo "$child_pid" > "$CHILD_PID_FILE"
    log "Child started with PID $child_pid"

    start_watchdog
}

wait_for_child() {
    if [[ -z "$child_pid" ]]; then
        return
    fi

    wait "$child_pid"
    local status=$?

    if [[ -n "$watchdog_pid" ]] && is_alive "$watchdog_pid"; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi

    log "Child PID $child_pid exited with status $status"
    rm -f "$CHILD_PID_FILE"

    echo "$status"
}

should_restart() {
    local status="$1"

    case "$RESTART_POLICY" in
        always)
            return 0
            ;;
        on-failure)
            (( status != 0 ))
            ;;
        never|*)
            return 1
            ;;
    esac
}

supervisor_loop() {
    setup_traps

    echo "$$" > "$SUPERVISOR_PID_FILE"
    log "Supervisor started with PID $$, policy=$RESTART_POLICY"

    while $running; do
        start_child
        status=$(wait_for_child)
        [[ "$running" == false ]] && break

        if should_restart "$status"; then
            log "Restarting child (policy=$RESTART_POLICY)..."
            sleep 1
        else
            log "Not restarting child (policy=$RESTART_POLICY, status=$status), exiting."
            break
        fi
    done

    log "Supervisor exiting."
    rm -f "$SUPERVISOR_PID_FILE"
}

# ==============================
# CLI Commands
# ==============================

cmd_start() {
    load_config "$1"

    local existing
    existing=$(read_pid_file "$SUPERVISOR_PID_FILE")

    if [[ -n "$existing" ]] && is_alive "$existing"; then
        echo "Supervisor for '$NAME' already running with PID $existing"
        exit 0
    fi

    supervisor_loop
}

cmd_stop() {
    load_config "$1"

    local pid
    pid=$(read_pid_file "$SUPERVISOR_PID_FILE")

    if [[ -z "$pid" ]] || ! is_alive "$pid"; then
        echo "Supervisor for '$NAME' is not running."
        rm -f "$SUPERVISOR_PID_FILE"
        exit 0
    fi

    echo "Stopping supervisor PID $pid for '$NAME'..."
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1

    if is_alive "$pid"; then
        echo "Supervisor did not exit, sending SIGKILL..."
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$SUPERVISOR_PID_FILE"
}

cmd_status() {
    load_config "$1"

    local spid cpid
    spid=$(read_pid_file "$SUPERVISOR_PID_FILE")
    cpid=$(read_pid_file "$CHILD_PID_FILE")

    if [[ -n "$spid" ]] && is_alive "$spid"; then
        echo "Supervisor for '$NAME' is running (PID $spid)."
    else
        echo "Supervisor for '$NAME' is NOT running."
    fi

    if [[ -n "$cpid" ]] && is_alive "$cpid"; then
        echo "  Child process running (PID $cpid)."
        if command -v ps >/dev/null 2>&1; then
            echo "  Resource usage:"
            ps -p "$cpid" -o pid,ppid,%cpu,%mem,rss,cmd
        fi
    else
        echo "  Child process is NOT running."
    fi

    echo "  Logs: $(log_file)"
}

cmd_tail() {
    load_config "$1"
    tail -n 100 -F "$(log_file)"
}

usage() {
    echo "Usage: $0 <command> <config>"
    echo
    echo "Commands:"
    echo "  start   <config>  Start supervisor for process defined in config"
    echo "  stop    <config>  Stop supervisor"
    echo "  status  <config>  Show supervisor/child status"
    echo "  tail    <config>  Tail logs"
    echo
    echo "Example:"
    echo "  $0 start configs/example.conf"
    echo "  $0 status configs/example.conf"
}

main() {
    if (( $# < 2 )); then
        usage
        exit 1
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        start)  cmd_start "$@" ;;
        stop)   cmd_stop "$@" ;;
        status) cmd_status "$@" ;;
        tail)   cmd_tail "$@" ;;
        *)      usage; exit 1 ;;
    esac
}

main "$@"
