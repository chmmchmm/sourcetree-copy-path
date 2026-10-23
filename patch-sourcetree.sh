#!/bin/bash
# SourceTree Copy Path - one-shot installer.
#
# Adds a "Copy Path" entry to the bookmark-list context menu by patching the
# app bundle. No resident injector and no debugger are required afterwards.
#
# Usage:
#   ./patch-sourcetree.sh install [path-to-dylib]   install / update the patch
#   ./patch-sourcetree.sh restore                   restore the original app
#   ./patch-sourcetree.sh status                    show current state
#
# How it works:
#   1. copy the library into Contents/Resources/stcopypath/
#   2. point LSEnvironment/DYLD_INSERT_LIBRARIES at it
#   3. re-sign the bundle ad-hoc (this also drops the Hardened Runtime flag,
#      without which dyld would ignore the environment variable)
set -euo pipefail

APP="${SOURCETREE_APP:-/Applications/Sourcetree.app}"
DEST_DIR="$APP/Contents/Resources/stcopypath"
PLIST="$APP/Contents/Info.plist"
BACKUP="${SOURCETREE_BACKUP:-$HOME/Sourcetree.app.backup}"
DYLIB_NAME="libstcopypath.dylib"
HERE="$(cd "$(dirname "$0")" && pwd)"

need_app() {
    [ -d "$APP" ] || { echo "error: $APP not found"; exit 1; }
}

do_status() {
    need_app
    echo "app          : $APP"
    echo "version      : $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
    echo "backup       : $([ -d "$BACKUP" ] && echo "present ($BACKUP)" || echo 'missing')"
    echo "library      : $([ -f "$DEST_DIR/$DYLIB_NAME" ] && echo 'present' || echo 'missing')"
    echo "LSEnvironment:"
    /usr/libexec/PlistBuddy -c "Print :LSEnvironment" "$PLIST" 2>/dev/null | sed 's/^/  /' || echo "  none"
    echo "signature    : $(codesign -dv "$APP" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)' || echo 'none')"
    if pgrep -x Sourcetree >/dev/null; then
        echo "running      : yes (PID $(pgrep -x Sourcetree | head -1))"
        echo "loaded       : $(lsof -p "$(pgrep -x Sourcetree | head -1)" 2>/dev/null | grep -c "$DYLIB_NAME") handle(s)"
    else
        echo "running      : no"
    fi
}

do_install() {
    need_app
    local src="${1:-$HERE/$DYLIB_NAME}"
    [ -f "$src" ] || { echo "error: library not found: $src"; exit 1; }

    echo "== 1/4 backing up the original app"
    if [ ! -d "$BACKUP" ]; then
        cp -R "$APP" "$BACKUP"
        echo "   saved to $BACKUP"
    else
        echo "   backup already exists, keeping it (delete it to re-create)"
    fi

    echo "== 2/4 installing the library"
    mkdir -p "$DEST_DIR"
    cp "$src" "$DEST_DIR/$DYLIB_NAME"
    chmod 755 "$DEST_DIR/$DYLIB_NAME"

    echo "== 3/4 writing Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$PLIST" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $DEST_DIR/$DYLIB_NAME" "$PLIST"

    echo "== 4/4 re-signing ad-hoc"
    codesign --force --deep --sign - "$APP" 2>&1 | tail -1
    codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

    echo
    echo "Done. Quit SourceTree if it is running, then start it again."
}

do_restore() {
    need_app
    [ -d "$BACKUP" ] || { echo "error: no backup found at $BACKUP"; exit 1; }
    echo "== quitting SourceTree"
    osascript -e 'tell application "Sourcetree" to quit' >/dev/null 2>&1 || true
    sleep 3
    pkill -x Sourcetree 2>/dev/null || true
    sleep 1
    echo "== restoring from backup"
    rm -rf "$APP"
    cp -R "$BACKUP" "$APP"
    codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
    echo "Restored."
}

case "${1:-}" in
    install) shift; do_install "${1:-}" ;;
    restore) do_restore ;;
    status)  do_status ;;
    *) echo "usage: $0 {install [dylib]|restore|status}"; exit 1 ;;
esac
