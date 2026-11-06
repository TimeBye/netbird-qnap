#!/bin/sh
# Netbird VPN QPKG service script for QNAP NAS
# Handles start/stop/restart/status/remove via QNAP's service management

CONF=/etc/config/qpkg.conf
QPKG_NAME="netbird"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
NETBIRD_BIN="${QPKG_ROOT}/netbird"
NETBIRD_CONF="${QPKG_ROOT}/netbird.conf"
NETBIRD_COMMON="${QPKG_ROOT}/netbird-common.sh"
NETBIRD_STATE="${QPKG_ROOT}/netbird-state.sh"
LAST_ERROR="${QPKG_ROOT}/last-error"
PIDF="/var/run/netbird.pid"
SVCLOG="/var/log/netbird-service.log"
APACHE_CONF="/etc/default_config/apache-netbird.conf"

# 'netbird up' normally finishes in seconds. It can block indefinitely if the
# peer is unregistered and falls through to an interactive SSO flow, which
# would hang the whole QPKG start, so it runs under a timeout.
NB_UP_TIMEOUT=90

export QNAP_QPKG=$QPKG_NAME

if [ -z "$QPKG_ROOT" ] || [ ! -f "$NETBIRD_COMMON" ]; then
    echo "netbird: cannot locate the install path (QPKG_ROOT='$QPKG_ROOT')." >&2
    echo "netbird: expected shared helpers at '$NETBIRD_COMMON'." >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') ABORT: QPKG_ROOT='$QPKG_ROOT', missing $NETBIRD_COMMON" >> "$SVCLOG"
    exit 1
fi

# shellcheck source=netbird-common.sh
. "$NETBIRD_COMMON"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SVCLOG"
    echo "$1"
}

record_error() {
    printf '%s\n' "$1" > "$LAST_ERROR" 2>/dev/null
    chmod 644 "$LAST_ERROR" 2>/dev/null
}

clear_error() {
    rm -f "$LAST_ERROR" 2>/dev/null
}

# nb_timeout_prefix echoes a working timeout invocation, or nothing when the
# NAS has no usable timeout. BusyBox changed the syntax from "timeout -t SEC"
# to "timeout SEC" partway through its history and QTS versions differ, so it
# is probed rather than assumed.
nb_timeout_prefix() {
    if timeout 1 true >/dev/null 2>&1; then
        printf 'timeout %s' "$NB_UP_TIMEOUT"
    elif timeout -t 1 true >/dev/null 2>&1; then
        printf 'timeout -t %s' "$NB_UP_TIMEOUT"
    fi
}

setup_webui() {
    # Drop-in proxy config (WordPress containerized QPKG pattern)
    # /etc/container-proxy.d/ is auto-included by QTS Apache
    _proxy_dir="/etc/container-proxy.d"
    if [ -d "$_proxy_dir" ]; then
        log "Using container-proxy.d drop-in"
    else
        mkdir -p "$_proxy_dir" 2>/dev/null
        log "Created $_proxy_dir"
    fi

    # Alias directive serves files directly from QPKG_ROOT (no symlinks needed)
    cat > "${_proxy_dir}/netbird.conf" <<AEOF
Alias /netbird "${QPKG_ROOT}/web"
<Directory "${QPKG_ROOT}/web">
  Require all granted
</Directory>
ProxyPass /netbird !
AEOF
    log "Created ${_proxy_dir}/netbird.conf"

    # Also write the standalone config as fallback
    cat > "$APACHE_CONF" <<AEOF
Alias /netbird "${QPKG_ROOT}/web"
<Directory "${QPKG_ROOT}/web">
  Require all granted
</Directory>
ProxyPass /netbird !
AEOF

    # Try CrashPlan-style Include into Apache proxy configs
    for _pf in /etc/config/apache/extra/apache-proxy.conf /etc/default_config/apache/extra/apache-proxy.conf; do
        if [ -f "$_pf" ] && ! grep -q "apache-netbird.conf" "$_pf"; then
            echo "Include ${APACHE_CONF}" >> "$_pf"
            log "Added Include to $_pf"
        fi
    done

    # Reload web servers
    if [ -x /etc/init.d/thttpd.sh ]; then
        /etc/init.d/thttpd.sh reload 2>>"$SVCLOG"
        log "Reloaded thttpd"
    fi
    if [ -x /etc/init.d/stunnel.sh ]; then
        /etc/init.d/stunnel.sh reload 2>>"$SVCLOG"
        log "Reloaded stunnel"
    fi

    # CGI symlink (confirmed working on this NAS)
    ln -sf "${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi" /home/httpd/cgi-bin/netbird-api.cgi
    if [ -L /home/httpd/cgi-bin/netbird-api.cgi ]; then
        log "CGI symlink OK"
    else
        log "ERROR: Failed to create CGI symlink"
    fi
}

teardown_webui() {
    # Remove drop-in proxy config
    rm -f /etc/container-proxy.d/netbird.conf 2>/dev/null
    rm -f "$APACHE_CONF"

    # Remove Include lines from Apache proxy configs
    for _pf in /etc/config/apache/extra/apache-proxy.conf /etc/default_config/apache/extra/apache-proxy.conf; do
        [ -f "$_pf" ] && sed -i '/apache-netbird\.conf/d' "$_pf" 2>/dev/null
    done

    # Reload web servers
    [ -x /etc/init.d/thttpd.sh ] && /etc/init.d/thttpd.sh reload 2>/dev/null
    [ -x /etc/init.d/stunnel.sh ] && /etc/init.d/stunnel.sh reload 2>/dev/null

    # Remove CGI symlink and stale web root symlinks
    rm -f /home/httpd/cgi-bin/netbird-api.cgi
    rm -f /home/Qhttpd/Web/netbird 2>/dev/null
}

# run_netbird_up builds the argv from netbird.conf and runs 'netbird up'.
#
# Every setting is passed explicitly rather than through NB_* environment
# variables so that the config file, not the daemon's stored profile, decides
# what this peer connects to. Output goes to $1; the exit status is returned.
run_netbird_up() {
    _out="$1"
    _argv_log=""

    set --
    for _row in $NB_OPTION_TABLE; do
        _key=${_row%%|*}
        _flag=$(nb_row_flag "$_row")
        _type=$(nb_row_type "$_row")
        [ "$_type" = "local" ] && continue

        eval "_val=\${NBQ_$_key-}"
        [ -n "$_val" ] || continue

        case "$_type" in
            bool)
                _norm=$(nb_bool "$_val") || continue
                set -- "$@" "--${_flag}=${_norm}"
                _argv_log="${_argv_log} --${_flag}=${_norm}"
                ;;
            secret)
                set -- "$@" "--${_flag}" "$_val"
                _argv_log="${_argv_log} --${_flag} ***"
                ;;
            *)
                set -- "$@" "--${_flag}" "$_val"
                _argv_log="${_argv_log} --${_flag} ${_val}"
                ;;
        esac
    done

    # EXTRA_ARGS is a free-text escape hatch and is deliberately word-split.
    # shellcheck disable=SC2086
    set -- "$@" $NBQ_EXTRA_ARGS
    [ -n "$NBQ_EXTRA_ARGS" ] && _argv_log="${_argv_log} ${NBQ_EXTRA_ARGS}"

    log "Running: netbird up${_argv_log}"

    _to=$(nb_timeout_prefix)
    # shellcheck disable=SC2086
    $_to "$NETBIRD_BIN" up "$@" >> "$_out" 2>&1
}

start_service() {
    log "=== START ==="
    log "QPKG_ROOT=$QPKG_ROOT"

    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        log "ABORT: $QPKG_NAME is disabled (Enable=$ENABLED)"
        exit 1
    fi

    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        log "$QPKG_NAME is already running (PID: $(cat "$PIDF"))"
        return 0
    fi

    if [ ! -x "$NETBIRD_BIN" ]; then
        log "ABORT: netbird binary not found at $NETBIRD_BIN"
        record_error "netbird binary not found at $NETBIRD_BIN"
        exit 1
    fi

    nb_load_config "$NETBIRD_CONF"
    export HOME="${QPKG_ROOT}"

    _log_file="${NBQ_LOG_FILE:-/var/log/netbird.log}"
    _log_level="${NBQ_LOG_LEVEL:-info}"

    # Do not copy identity state while the daemon is writing to it, even if the PID file is missing.
    if ! command -v pidof >/dev/null 2>&1; then
        record_error "Cannot verify daemon is stopped: pidof is unavailable."
        log "ABORT: pidof is unavailable"
        return 1
    fi
    if pidof netbird >/dev/null 2>&1; then
        record_error "Netbird is running without a valid PID file; stop it before starting."
        log "ABORT: netbird process exists; refusing state migration"
        return 1
    fi
    if [ ! -f "$NETBIRD_STATE" ]; then
        record_error "State helper not found: $NETBIRD_STATE"
        log "ABORT: missing state helper"
        return 1
    fi
    . "$NETBIRD_STATE"
    if ! nb_prepare_state >> "$SVCLOG" 2>&1; then
        record_error "State migration failed; original identity retained. Check $SVCLOG."
        log "ABORT: state migration failed"
        return 1
    fi
    ln -sf "$NETBIRD_BIN" /usr/local/bin/netbird 2>/dev/null

    # Clean stale config from previous versions
    pkill -f "busybox httpd -p 58090" 2>/dev/null
    pkill -f "busybox httpd -p 8090" 2>/dev/null

    # Set up web UI
    setup_webui

    # Log qpkg.conf state for debugging
    log "qpkg.conf: WebUI=$(/sbin/getcfg $QPKG_NAME WebUI -f $CONF 2>/dev/null) Web_Port=$(/sbin/getcfg $QPKG_NAME Web_Port -f $CONF 2>/dev/null)"

    # Start netbird daemon
    log "Starting netbird daemon..."

    "$NETBIRD_BIN" service run \
        --log-file "$_log_file" \
        --log-level "$_log_level" \
        > /dev/null 2>&1 &

    echo $! > "$PIDF"
    log "Daemon PID: $(cat "$PIDF")"

    # Wait for daemon socket
    _retries=0
    while [ $_retries -lt 15 ]; do
        if [ -S /var/run/netbird.sock ]; then
            break
        fi
        sleep 1
        _retries=$((_retries + 1))
    done

    if [ ! -S /var/run/netbird.sock ]; then
        log "WARNING: daemon socket not ready after 15 seconds (check $_log_file)"
        record_error "Daemon socket /var/run/netbird.sock was not ready after 15 seconds. Check $_log_file."
        return 1
    fi
    log "Daemon socket ready"

    # Decide whether 'netbird up' can run unattended. With a setup key it can
    # always register. Without one it can only reconnect an already-registered
    # peer -- an unregistered peer would fall through to interactive SSO.
    _status_json=$("$NETBIRD_BIN" status --json 2>/dev/null)
    _daemon_status=$(nb_json_str "$_status_json" daemonStatus)
    log "Daemon status before apply: ${_daemon_status:-unknown}"

    if [ -z "$NBQ_SETUP_KEY" ] && { [ -z "$_daemon_status" ] || [ "$_daemon_status" = "NeedsLogin" ]; }; then
        log "No SETUP_KEY configured and this peer is not registered."
        log "Daemon is running but the tunnel is not activated."
        log "Configure via the web UI at /netbird/ or edit $NETBIRD_CONF"
        record_error "No setup key configured. Enter one on the settings page and press Save & Restart."
        log "=== START COMPLETE (tunnel not activated) ==="
        return 0
    fi

    # 'netbird up' returns early with "Already connected" -- before it sends
    # SetConfig -- whenever the daemon reports StatusConnected, and the daemon
    # auto-connects from its stored profile as soon as it starts. Without this
    # 'down' every setting below is silently discarded and 'up' still exits 0,
    # which is how a stale management URL survives every restart.
    log "Bringing tunnel down before applying settings"
    "$NETBIRD_BIN" down >> "$SVCLOG" 2>&1

    _up_out="/tmp/netbird-up.$$"
    : > "$_up_out"
    run_netbird_up "$_up_out"
    _rc=$?
    cat "$_up_out" >> "$SVCLOG" 2>/dev/null

    if [ $_rc -ne 0 ]; then
        log "ERROR: 'netbird up' failed (rc=$_rc)"
        record_error "$(cat "$_up_out" 2>/dev/null)"
        rm -f "$_up_out"
        /sbin/log_tool -t2 -uSystem -p127.0.0.1 -mlocalhost -a "Netbird VPN failed to connect (rc=$_rc)"
        return 1
    fi

    rm -f "$_up_out"
    clear_error
    log "'netbird up' succeeded"

    /sbin/log_tool -t1 -uSystem -p127.0.0.1 -mlocalhost -a "Netbird VPN service started"
    log "=== START COMPLETE ==="
}

stop_service() {
    log "=== STOP ==="

    if [ -S /var/run/netbird.sock ]; then
        "$NETBIRD_BIN" down 2>/dev/null
    fi

    if [ -f "$PIDF" ]; then
        _pid=$(cat "$PIDF")
        if kill -0 "$_pid" 2>/dev/null; then
            kill "$_pid" 2>/dev/null
            _retries=0
            while [ $_retries -lt 10 ] && kill -0 "$_pid" 2>/dev/null; do
                sleep 1
                _retries=$((_retries + 1))
            done
            if kill -0 "$_pid" 2>/dev/null; then
                kill -9 "$_pid" 2>/dev/null
            fi
        fi
        rm -f "$PIDF"
    fi

    teardown_webui

    pkill -f "busybox httpd -p 58090" 2>/dev/null
    pkill -f "busybox httpd -p 8090" 2>/dev/null

    killall netbird 2>/dev/null
    rm -f /usr/local/bin/netbird 2>/dev/null

    /sbin/log_tool -t1 -uSystem -p127.0.0.1 -mlocalhost -a "Netbird VPN service stopped"
    log "=== STOP COMPLETE ==="
}

case "$1" in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        sleep 2
        start_service
        ;;
    status)
        if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
            echo "$QPKG_NAME is running (PID: $(cat "$PIDF"))"
            "$NETBIRD_BIN" status 2>/dev/null
            exit 0
        else
            echo "$QPKG_NAME is not running."
            exit 1
        fi
        ;;
    remove)
        stop_service
        rm -f /usr/local/bin/netbird 2>/dev/null
        exit 0
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|remove}"
        exit 1
        ;;
esac

# Propagate the outcome. This used to be an unconditional "exit 0", so a start
# that failed to bring the tunnel up still reported success to QTS.
exit $?
