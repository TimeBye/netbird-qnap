#!/bin/sh
# Call only after confirming the daemon has stopped; state directories are created at runtime, not shipped in the package.

nb_state_check() (
    _src=$1
    _dst=$2
    if [ -L "$_dst" ] || { [ -e "$_dst" ] && [ ! -d "$_dst" ]; }; then
        echo "Unsafe persistent state path: $_dst" >&2
        return 1
    fi
    if [ -L "$_src" ]; then
        # During volume migration, accept only resolvable links to the same directory; do not guess old paths.
        if [ -d "$_dst" ] && [ -d "$_src" ] && [ "$_src" -ef "$_dst" ]; then
            return 0
        fi
        echo "Unknown or broken state symlink: $_src" >&2
        return 1
    fi
    if [ -e "$_src" ] && [ ! -d "$_src" ]; then
        echo "State path is not a directory: $_src" >&2
        return 1
    fi
    if [ -d "$_dst" ] && [ -d "$_src" ]; then
        # Include hidden files in the glob; ls exit status cannot determine whether a directory is empty.
        for _entry in "$_src"/* "$_src"/.[!.]* "$_src"/..?*; do
            if [ -e "$_entry" ] || [ -L "$_entry" ]; then
                echo "Conflicting state directories: $_src and $_dst" >&2
                return 1
            fi
        done
    fi
)

nb_state_prepare_dir() (
    _src=$1
    _dst=$2
    nb_state_check "$_src" "$_dst" || return 1
    umask 077
    _published=0
    _backup=
    if [ ! -d "$_dst" ]; then
        mkdir -p "${_dst%/*}" || return 1
        _stage=$(mktemp -d "${_dst}.staging.XXXXXX") || return 1
        # Copy on the destination volume and verify all contents before publishing; preserve the original identity on failure.
        if [ -d "$_src" ]; then
            if ! cp -a "$_src/." "$_stage/" || ! diff -r "$_src" "$_stage" >/dev/null; then
                rm -rf "$_stage"
                echo "State copy verification failed: $_src" >&2
                return 1
            fi
        fi
        if ! chmod 700 "$_stage" || ! mv "$_stage" "$_dst"; then
            rm -rf "$_stage"
            return 1
        fi
        _published=1
    fi
    chmod 700 "$_dst" || return 1
    if [ -L "$_src" ]; then
        [ "$(readlink "$_src")" = "$_dst" ] && return 0
        # The link resolves to the same directory; update the valid alias after volume migration.
        rm "$_src" || return 1
    elif [ -d "$_src" ]; then
        _backup=$(mktemp -d "${_src}.backup.XXXXXX") || return 1
        mv "$_src" "$_backup/original" || return 1
        if ! chmod 700 "$_backup/original"; then
            if mv "$_backup/original" "$_src"; then
                [ "$_published" -eq 0 ] || rm -rf "$_dst"
            fi
            return 1
        fi
    fi
    if ! mkdir -p "${_src%/*}" || ! ln -s "$_dst" "$_src"; then
        if [ -n "$_backup" ] && mv "$_backup/original" "$_src"; then
            [ "$_published" -eq 0 ] || rm -rf "$_dst"
        fi
        return 1
    fi
)

nb_prepare_state() (
    # Arguments isolate tests; production calls use the system default paths.
    _state=${1:-/var/lib/netbird}
    _config=${2:-/etc/netbird}
    nb_state_check "$_state" "$QPKG_ROOT/var/lib/netbird" &&
        nb_state_check "$_config" "$QPKG_ROOT/var/etc/netbird" || return 1
    nb_state_prepare_dir "$_state" "$QPKG_ROOT/var/lib/netbird" &&
        nb_state_prepare_dir "$_config" "$QPKG_ROOT/var/etc/netbird"
)
