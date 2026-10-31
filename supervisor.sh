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
STOP_TIMEOUT=10

LOG_DIR="./logs"
LOG_RETENTION_DAYS=7
PID_DIR="/tmp/process-supervisor"

SUPERVISOR_PID_FILE=""
CHILD_PID_FILE=""

running=true
child_pid=""
child_status=0
watchdog_pid=""
current_log_file=""

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

# Delete daily log files older than LOG_RETENTION_DAYS (0 = keep everything).
prune_logs() {
    (( LOG_RETENTION_DAYS > 0 )) || return 0
    find "$LOG_DIR" -maxdepth 1 -name "${NAME}_*.log" -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

log() {
    local ts file
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    file=$(log_file)
    if [[ "$file" != "$current_log_file" ]]; then
        # First line of a new day: switch files and drop expired ones.
        current_log_file="$file"
        prune_logs
    fi
    printf "%s [%s] %s\n" "$ts" "$NAME" "$*" | tee -a "$file"
}

# ==============================
# Config Loading
# ==============================

die() {
    echo "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found: $2"
}

load_config() {
    CONFIG_FILE="$1"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config not found: $CONFIG_FILE"
    fi

    # shellcheck source=/dev/null
    . "$CONFIG_FILE"

    if [[ -z "${NAME:-}" || -z "${COMMAND:-}" ]]; then
        die "Config must set NAME and COMMAND"
    fi

    case "$RESTART_POLICY" in
        always|on-failure|never) ;;
        *) die "Invalid RESTART_POLICY '$RESTART_POLICY' (expected always, on-failure or never)" ;;
    esac

    local var
    for var in MAX_CPU_PCT MAX_MEM_MB CHECK_INTERVAL STOP_TIMEOUT LOG_RETENTION_DAYS; do
        [[ "${!var}" =~ ^[0-9]+$ ]] || die "$var must be a whole number, got '${!var}'"
    done
    (( CHECK_INTERVAL > 0 )) || die "CHECK_INTERVAL must be at least 1"

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

# The child runs in its own process group whose ID is the child's PID
# (see start_child). A negative PID makes kill target the whole group.
group_alive() {
    [[ -n "$child_pid" ]] && kill -0 -- "-$child_pid" 2>/dev/null
}

signal_group() {
    [[ -n "$child_pid" ]] && kill -"$1" -- "-$child_pid" 2>/dev/null
    return 0
}

# ==============================
# Signal Handlers
# ==============================

on_term() {
    # Only flip the flag here. The trap makes `wait` in wait_for_child return
    # early, and wait_for_child then stops the child and waits for it to exit.
    if $running; then
        log "Received termination signal, shutting down supervisor..."
    fi
    running=false
}

setup_traps() {
    trap on_term INT TERM
}

# ==============================
# Resource Monitoring
# ==============================

# CPU % and RSS summed over every process in the child's process group,
# printed as "<cpu_pct> <mem_mb>". ps reports %CPU as an average over each
# process's lifetime, not its current rate (see README tradeoffs).
group_usage() {
    ps -e -o pgid=,%cpu=,rss= 2>/dev/null |
        awk -v pgid="$child_pid" '$1 == pgid { cpu += $2; rss += $3 }
                                  END { printf "%d %d\n", cpu, rss / 1024 }'
}

watchdog_loop() {
    local cpu mem reason

    while is_alive "$child_pid"; do
        read -r cpu mem < <(group_usage)

        reason=""
        if (( MAX_CPU_PCT > 0 && cpu > MAX_CPU_PCT )); then
            reason="CPU limit exceeded: ${cpu}% > ${MAX_CPU_PCT}%"
        elif (( MAX_MEM_MB > 0 && mem > MAX_MEM_MB )); then
            reason="Memory limit exceeded: ${mem}MB > ${MAX_MEM_MB}MB"
        fi

        if [[ -n "$reason" ]]; then
            log "$reason, stopping child PID $child_pid"
            stop_child
            return
        fi

        sleep "$CHECK_INTERVAL"
    done
}

start_watchdog() {
    if (( MAX_CPU_PCT > 0 || MAX_MEM_MB > 0 )); then
        watchdog_loop &
        watchdog_pid=$!
    fi
}

stop_watchdog() {
    if [[ -n "$watchdog_pid" ]]; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        watchdog_pid=""
    fi
}

# ==============================
# Child Process Management
# ==============================

start_child() {
    log "Starting child: $COMMAND"
    # setsid gives the child a new session and process group with ID == its
    # PID, so signal_group reaches every process the command starts. For a
    # simple command bash execs it and $! is the worker itself; for something
    # like `python worker.py | tee out.log`, $! is a bash wrapper and the
    # worker is its child, so signalling only $! would orphan the worker.
    setsid bash -c "$COMMAND" &
    child_pid=$!
    echo "$child_pid" > "$CHILD_PID_FILE"
    log "Child started with PID $child_pid"

    start_watchdog
}

# SIGTERM the child's process group, then SIGKILL whatever is left after
# STOP_TIMEOUT seconds.
stop_child() {
    group_alive || return 0

    log "Sending SIGTERM to child process group $child_pid"
    signal_group TERM

    # Count 0.2s ticks rather than compare against $SECONDS, which only moves
    # on whole-second boundaries and would cut the grace period short.
    local ticks=0
    while group_alive && (( ticks < STOP_TIMEOUT * 5 )); do
        sleep 0.2
        ticks=$(( ticks + 1 ))
    done

    if group_alive; then
        log "Child process group $child_pid still running after ${STOP_TIMEOUT}s, sending SIGKILL"
        signal_group KILL
    fi
}

# Runs in the main shell, never in $(...): `wait` only works on children of
# the current process, and the child belongs to the main shell.
wait_for_child() {
    local rc

    while :; do
        $running || stop_child

        wait "$child_pid"
        rc=$?

        # A trapped signal makes `wait` return early (status > 128) while the
        # child is still running. Loop: stop it, then wait for its real status.
        if (( rc > 128 )) && is_alive "$child_pid"; then
            continue
        fi
        break
    done
    child_status=$rc

    # The child has exited, but processes it started may still be running in
    # its group. Stop them so a restart never runs two copies side by side.
    stop_child
    stop_watchdog

    log "Child PID $child_pid exited with status $child_status"
    rm -f "$CHILD_PID_FILE"
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

    local exit_code=0

    while $running; do
        start_child
        wait_for_child
        $running || break

        if should_restart "$child_status"; then
            log "Restarting child (policy=$RESTART_POLICY)..."
            sleep 1
        else
            log "Not restarting child (policy=$RESTART_POLICY, status=$child_status), exiting."
            exit_code=$child_status
            break
        fi
    done

    log "Supervisor exiting."
    rm -f "$SUPERVISOR_PID_FILE"
    return "$exit_code"
}

# ==============================
# CLI Commands
# ==============================

cmd_start() {
    load_config "$1"

    require_cmd setsid "install util-linux"
    if (( MAX_CPU_PCT > 0 || MAX_MEM_MB > 0 )); then
        require_cmd ps "the watchdog needs it; install procps or set MAX_CPU_PCT and MAX_MEM_MB to 0"
    fi

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

    local pid cpid
    pid=$(read_pid_file "$SUPERVISOR_PID_FILE")

    if [[ -z "$pid" ]] || ! is_alive "$pid"; then
        echo "Supervisor for '$NAME' is not running."
        rm -f "$SUPERVISOR_PID_FILE"
        exit 0
    fi

    echo "Stopping supervisor PID $pid for '$NAME'..."
    kill -TERM "$pid" 2>/dev/null || true

    # The supervisor gives its child STOP_TIMEOUT seconds before SIGKILL,
    # so wait a little longer than that before forcing anything.
    local deadline=$(( SECONDS + STOP_TIMEOUT + 5 ))
    while is_alive "$pid" && (( SECONDS < deadline )); do
        sleep 0.5
    done

    if is_alive "$pid"; then
        echo "Supervisor did not exit, sending SIGKILL to it and its child process group..."
        cpid=$(read_pid_file "$CHILD_PID_FILE")
        if [[ -n "$cpid" ]]; then
            kill -KILL -- "-$cpid" 2>/dev/null || true
        fi
        kill -KILL "$pid" 2>/dev/null || true
        rm -f "$SUPERVISOR_PID_FILE" "$CHILD_PID_FILE"
    fi

    echo "Stopped."
}

# Exit code 0 when both supervisor and child are running, 1 otherwise,
# so this works as a Kubernetes liveness probe.
cmd_status() {
    load_config "$1"

    local spid cpid rc=0
    spid=$(read_pid_file "$SUPERVISOR_PID_FILE")
    cpid=$(read_pid_file "$CHILD_PID_FILE")

    if [[ -n "$spid" ]] && is_alive "$spid"; then
        echo "Supervisor for '$NAME' is running (PID $spid)."
    else
        echo "Supervisor for '$NAME' is NOT running."
        rc=1
    fi

    if [[ -n "$cpid" ]] && is_alive "$cpid"; then
        echo "  Child process running (PID $cpid)."
        if command -v ps >/dev/null 2>&1; then
            echo "  Process group $cpid:"
            ps -e -o pid,pgid,%cpu,%mem,rss,cmd | awk -v pgid="$cpid" 'NR == 1 || $2 == pgid'
        fi
    else
        echo "  Child process is NOT running."
        rc=1
    fi

    echo "  Logs: $(log_file)"
    exit "$rc"
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
    echo "  status  <config>  Show supervisor/child status (exit 0 = both running)"
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
