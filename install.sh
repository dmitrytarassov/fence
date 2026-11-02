#!/bin/zsh
# Install the daemon (root) and the menu bar app (user). Run with sudo.
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
    echo "run: sudo ./install.sh" >&2
    exit 2
fi
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')
USER_UID=$(id -u "$USER_NAME")

echo "==> build as $USER_NAME"
sudo -u "$USER_NAME" ./build.sh

echo "==> daemon"
install -d -m 755 /usr/local/libexec "/Library/Application Support/Fence" /Library/Logs/Fence
install -m 755 build/fence-daemon /usr/local/libexec/fence-daemon
install -m 644 Resources/com.dm.fence.daemon.plist /Library/LaunchDaemons/com.dm.fence.daemon.plist
launchctl bootout system/com.dm.fence.daemon 2>/dev/null || true
# bootout returns before launchd removes a hung daemon. Wait for the removal, up to 30 seconds.
for i in $(seq 1 60); do
    launchctl print system/com.dm.fence.daemon >/dev/null 2>&1 || break
    sleep 0.5
done
bootstrapped=0
for i in 1 2 3 4 5; do
    if launchctl bootstrap system /Library/LaunchDaemons/com.dm.fence.daemon.plist; then
        bootstrapped=1
        break
    fi
    sleep 1
done
if [[ $bootstrapped -eq 0 ]]; then
    echo "    cannot load the daemon. Run: sudo launchctl print system/com.dm.fence.daemon"
    exit 1
fi
for i in 1 2 3 4 5 6 7 8 9 10; do
    if /usr/local/libexec/fence-daemon status >/dev/null 2>&1; then
        echo "    daemon answers on the socket"
        break
    fi
    sleep 0.5
done

echo "==> app"
rm -rf "/Applications/Fence.app"
cp -R "build/Fence.app" "/Applications/Fence.app"
chown -R "$USER_NAME" "/Applications/Fence.app"

AGENT="$USER_HOME/Library/LaunchAgents/com.dm.fence.app.plist"
install -d -o "$USER_NAME" -m 755 "$USER_HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dm.fence.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Fence.app/Contents/MacOS/Fence</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST
chown "$USER_NAME" "$AGENT"

# launchctl must talk to the user's GUI domain from inside that session, not from root.
as_user() { launchctl asuser "$USER_UID" sudo -u "$USER_NAME" "$@"; }
as_user launchctl bootout "gui/$USER_UID/com.dm.fence.app" 2>/dev/null || true
pkill -x "Fence" 2>/dev/null || true
sleep 1
if as_user launchctl bootstrap "gui/$USER_UID" "$AGENT"; then
    echo "    app started through launchd"
else
    echo "    launchd bootstrap failed, starting the app directly"
    as_user open -a "/Applications/Fence.app"
fi

echo "==> installed. The icon is in the menu bar. Log: /Library/Logs/Fence/daemon.log"
