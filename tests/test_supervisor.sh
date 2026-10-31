#!/usr/bin/env bash
# Behaviour tests for supervisor.sh: restart policies, signal handling,
# process-group cleanup, the watchdog and config validation.
# Each test starts a real supervisor against a small Bash child.
#
# Usage:  bash tests/test_supervisor.sh
# Needs:  Linux, bash, procps (ps/pgrep), util-linux (setsid)

# Child scripts below are single-quoted on purpose: they expand when they run.
# shellcheck disable=SC2016
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUP="${SUP:-$ROOT/supervisor.sh}"
WORK=$(mktemp -d)
passed=0
failed=0
dir=""
sup_pid=""
sup_rc=""

cleanup() {
    pkill -KILL -f "$WORK/" 2>/dev/null   # anything a failed test left behind
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- helpers ----------

# new_case <name> <child script> [config lines...]
# The child runs as `bash $dir/child.sh`; later config lines override earlier ones.
new_case() {
    local name=$1 body=$2
    shift 2
    dir="$WORK/$name"
    mkdir -p "$dir"
    printf '%s\n' "$body" > "$dir/child.sh"
    {
        echo "NAME=\"$name\""
        echo "COMMAND=\"bash $dir/child.sh\""
        echo "LOG_DIR=\"$dir/logs\""
        echo "PID_DIR=\"$dir/pids\""
        echo "STOP_TIMEOUT=3"
        echo "CHECK_INTERVAL=1"
        printf '%s\n' "$@"
    } > "$dir/test.conf"
}

start_sup() {
    bash "$SUP" start "$dir/test.conf" > "$dir/out.log" 2>&1 &
    sup_pid=$!
}

sup_running() {
    local stat
    stat=$(ps -o stat= -p "$sup_pid" 2>/dev/null) || return 1
    [[ "$stat" != Z* ]]
}

children() {   # how many copies of this case's child are running
    pgrep -fc "^bash $dir/child.sh" || true
}

child_pid() {
    cat "$dir/pids/$(basename "$dir").child.pid" 2>/dev/null
}

group_empty() {   # no process left in process group $1
    [[ -n "$1" ]] && ! pgrep -g "$1" >/dev/null 2>&1
}

is_group_leader() {   # process $1 leads its own process group
    [[ -n "$1" ]] && [[ "$(ps -o pgid= -p "$1" | tr -d ' ')" == "$1" ]]
}

now_ms() {
    local us=${EPOCHREALTIME/[.,]/}
    echo $(( us / 1000 ))
}

not() { ! "$@"; }

wait_until() {   # wait_until <seconds> <command...>
    local deadline=$(( SECONDS + $1 ))
    shift
    until "$@"; do
        (( SECONDS >= deadline )) && return 1
        sleep 0.2
    done
}

wait_for_exit() {   # wait up to $1 seconds for the supervisor to exit; sets sup_rc
    if wait_until "$1" not sup_running; then
        wait "$sup_pid" 2>/dev/null
        sup_rc=$?
    else
        sup_rc="still running"
    fi
}

stop_sup() {   # SIGTERM the supervisor, like `docker stop` or a pod delete
    kill -TERM "$sup_pid" 2>/dev/null
    wait_for_exit "${1:-10}"
}

check() {   # check <description> <command...>
    local desc=$1
    shift
    if "$@"; then
        echo "PASS  $desc"
        passed=$(( passed + 1 ))
    else
        echo "FAIL  $desc"
        failed=$(( failed + 1 ))
        [[ -f "$dir/out.log" ]] && tail -n 12 "$dir/out.log" | sed 's/^/      | /'
    fi
}

logged() { grep -q -- "$1" "$dir/out.log"; }

# ---------- tests ----------

echo "== always: long-running child"
new_case always_long 'sleep 300' 'RESTART_POLICY="always"'
start_sup
sleep 3
cpid=$(child_pid)
check "exactly one child after 3s, no pile-up" test "$(children)" -eq 1
check "no restarts while the child is running" not logged "Restarting"
check "child leads its own process group" is_group_leader "$cpid"
stop_sup
check "SIGTERM: supervisor exits 0" test "$sup_rc" = 0
check "SIGTERM: child and its sleep are gone" group_empty "$cpid"

echo "== always: crashing child"
new_case always_crash 'sleep 1; exit 3' 'RESTART_POLICY="always"'
start_sup
max=0
for _ in $(seq 20); do
    n=$(children)
    (( n > max )) && max=$n
    sleep 0.2
done
check "never more than one child at a time" test "$max" -le 1
check "child restarted after exiting with 3" logged "exited with status 3"
stop_sup

echo "== on-failure"
new_case on_failure 'n=$(cat "$(dirname "$0")/runs" 2>/dev/null || echo 0)
echo $(( n + 1 )) > "$(dirname "$0")/runs"
sleep 0.5
(( n >= 2 )) && exit 0 || exit 3' 'RESTART_POLICY="on-failure"'
start_sup
wait_for_exit 15
check "restarts on exit 3, stops on exit 0" test "$(grep -c 'Starting child' "$dir/out.log")" -eq 3
check "supervisor exits 0 after the child's clean exit" test "$sup_rc" = 0
check "no arithmetic error in the log" not logged "syntax error"

echo "== never"
new_case never 'sleep 1; exit 3' 'RESTART_POLICY="never"'
t0=$(now_ms)
start_sup
wait_for_exit 10
check "supervisor waits for the child (>= 1s)" test $(( $(now_ms) - t0 )) -ge 1000
check "supervisor exits with the child's status 3" test "$sup_rc" = 3
check "no orphaned child" test "$(children)" -eq 0

echo "== graceful shutdown"
new_case graceful 'trap "sleep 1; echo child: clean shutdown; exit 0" TERM
while :; do sleep 0.1; done' 'RESTART_POLICY="always"'
start_sup
sleep 1
t0=$(now_ms)
stop_sup
check "child finished its SIGTERM handler" logged "child: clean shutdown"
check "supervisor waited for it" test $(( $(now_ms) - t0 )) -ge 1000
check "child exit status 0 was recorded" logged "exited with status 0"

echo "== SIGKILL escalation"
new_case stubborn 'trap "" TERM
while :; do sleep 0.1; done' 'RESTART_POLICY="always"' 'STOP_TIMEOUT=2'
start_sup
sleep 1
cpid=$(child_pid)
t0=$(now_ms)
stop_sup 10
check "child ignoring SIGTERM gets SIGKILL" logged "sending SIGKILL"
check "after STOP_TIMEOUT (2s), not before" test $(( $(now_ms) - t0 )) -ge 2000
check "nothing left in the child's group" group_empty "$cpid"
check "supervisor exited" test "$sup_rc" = 0

echo "== pipeline command (bash wrapper between supervisor and worker)"
new_case pipeline 'trap "echo worker: got SIGTERM >&2; exit 0" TERM
while :; do sleep 0.1; done'
echo "COMMAND=\"bash $dir/child.sh | cat\"" >> "$dir/test.conf"
start_sup
sleep 1
check "worker inside 'worker | cat' is running" test "$(children)" -eq 1
stop_sup
check "worker received SIGTERM, not just the bash wrapper" logged "worker: got SIGTERM"
check "worker is not orphaned" test "$(children)" -eq 0

echo "== watchdog: CPU"
new_case cpu_hog 'while :; do :; done' 'RESTART_POLICY="never"' 'MAX_CPU_PCT=50'
start_sup
wait_for_exit 15
check "CPU limit enforced" logged "CPU limit exceeded"
check "log shows a single % sign" not logged "%%"
check "hog is gone" test "$(children)" -eq 0

echo "== watchdog: memory"
new_case mem_hog 'x=$(head -c 80000000 /dev/zero | tr "\0" a)
sleep 300' 'RESTART_POLICY="never"' 'MAX_MEM_MB=40'
start_sup
wait_for_exit 20
check "memory limit enforced" logged "Memory limit exceeded"
check "hog is gone" test "$(children)" -eq 0

echo "== config validation"
new_case bad_policy 'sleep 300' 'RESTART_POLICY="sometimes"'
timeout 5 bash "$SUP" start "$dir/test.conf" > "$dir/out.log" 2>&1
check "unknown RESTART_POLICY is rejected (exit 1)" test $? -eq 1
check "with a clear message" logged "Invalid RESTART_POLICY"

new_case bad_number 'sleep 300' 'MAX_MEM_MB=200MB'
timeout 5 bash "$SUP" start "$dir/test.conf" > "$dir/out.log" 2>&1
check "non-numeric limit is rejected" logged "MAX_MEM_MB must be a whole number"

new_case no_ps 'sleep 300' 'MAX_CPU_PCT=90'
mkdir -p "$dir/bin"
for tool in mkdir setsid; do ln -s "$(command -v "$tool")" "$dir/bin/$tool"; done
PATH="$dir/bin" "$(command -v timeout)" 5 "$(command -v bash)" "$SUP" start "$dir/test.conf" > "$dir/out.log" 2>&1
check "limits set without ps: refuses to start" logged "'ps' not found"

echo "== stop and status commands"
new_case cli 'sleep 300' 'RESTART_POLICY="always"'
start_sup
sleep 1
cpid=$(child_pid)
bash "$SUP" status "$dir/test.conf" > /dev/null 2>&1
check "status exits 0 while running" test $? -eq 0
bash "$SUP" stop "$dir/test.conf" > /dev/null 2>&1
wait_for_exit 5
check "stop: supervisor gone" test "$sup_rc" = 0
check "stop: child group gone" group_empty "$cpid"
bash "$SUP" status "$dir/test.conf" > /dev/null 2>&1
check "status exits 1 when stopped" test $? -eq 1

echo
echo "$passed passed, $failed failed"
(( failed == 0 ))
