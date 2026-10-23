#!/bin/bash
# Legacy helper: inject the library into a running SourceTree via lldb.
# Superseded by patch-sourcetree.sh (which loads the library at launch).
set -u
DYLIB="$HOME/bin/stc/libstcopypath.dylib"
LOG="/tmp/stcopypath-inject.log"

[ -f "$DYLIB" ] || exit 0
PID="$(pgrep -x Sourcetree | head -1)"
[ -z "$PID" ] && exit 0

for f in /tmp/.stcopypath.*; do
    [ -e "$f" ] || continue
    case "$f" in */".stcopypath.$PID") ;; *) rm -f "$f" ;; esac
done

MARK="/tmp/.stcopypath.$PID"
[ -f "$MARK" ] && exit 0

/usr/bin/lldb --batch -p "$PID" -o "expr -l objc -- (char *)dlopen(\"$DYLIB\", 2)" >>"$LOG" 2>&1
if grep -q "0x" "$LOG" 2>/dev/null; then
    touch "$MARK"
fi
exit 0
