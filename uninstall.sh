#!/bin/zsh
# Remove the daemon, the app, the hosts block and the pf anchor. Run with sudo.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "run: sudo ./uninstall.sh" >&2
    exit 2
fi
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')
USER_UID=$(id -u "$USER_NAME")

echo "==> stop daemon"
launchctl bootout system/com.dm.fence.daemon 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.dm.fence.daemon.plist

echo "==> remove the block"
if [[ -x /usr/local/libexec/fence-daemon ]]; then
    /usr/local/libexec/fence-daemon cleanup
fi
rm -f /usr/local/libexec/fence-daemon
rm -f /var/run/fence.sock
rm -rf "/Library/Application Support/Fence"

echo "==> remove app"
launchctl asuser "$USER_UID" sudo -u "$USER_NAME" launchctl bootout "gui/$USER_UID/com.dm.fence.app" 2>/dev/null || true
pkill -x "Fence" 2>/dev/null || true
rm -f "$USER_HOME/Library/LaunchAgents/com.dm.fence.app.plist"
rm -rf "/Applications/Fence.app"

echo "==> done. Logs stay in /Library/Logs/Fence. Remove them by hand if you want."
