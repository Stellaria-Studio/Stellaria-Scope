#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_AGENT="$PWD/Build/StellarScope.app/Contents/Resources/agent/stellarscope_powermetrics_agent.py"
SRC_AGENT="$PWD/Sources/StellarScope/Resources/stellarscope_powermetrics_agent.py"
AGENT="$SRC_AGENT"
if [[ -f "$APP_AGENT" ]]; then
  AGENT="$APP_AGENT"
fi

if [[ ! -f "$AGENT" ]]; then
  echo "找不到 helper：$AGENT"
  read -k 1 "?按任意键退出..."
  exit 1
fi

PY="/usr/bin/python3"
if [[ ! -x "$PY" ]]; then
  PY="$(command -v python3 || true)"
fi
if [[ -z "$PY" ]]; then
  echo "找不到 python3。请先安装 Xcode Command Line Tools。"
  read -k 1 "?按任意键退出..."
  exit 1
fi

echo "Starting StellarScope advanced helper..."
echo "Agent: $AGENT"
echo "Output: /tmp/stellarscope-powermetrics.json"
echo "Log: /tmp/stellarscope-powermetrics-agent.log"
PLIST="/Library/LaunchDaemons/com.lmz.StellarScope.PowermetricsAgent.plist"
TMPPLIST="/tmp/com.lmz.StellarScope.PowermetricsAgent.plist"
cat > "$TMPPLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lmz.StellarScope.PowermetricsAgent</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$AGENT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>STELLARSCOPE_INTERVAL_MS</key>
        <string>1000</string>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/stellarscope-powermetrics-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/stellarscope-powermetrics-agent.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF
sudo /bin/zsh -lc "rm -f /tmp/stellarscope-powermetrics.json /tmp/stellarscope-powermetrics.pid; : > /tmp/stellarscope-powermetrics-agent.log; chmod 644 /tmp/stellarscope-powermetrics-agent.log; cp '$TMPPLIST' '$PLIST'; chown root:wheel '$PLIST'; chmod 644 '$PLIST'; echo '[StellarScope] bootstrapping LaunchDaemon at '$(date) >> /tmp/stellarscope-powermetrics-agent.log; launchctl bootout system/com.lmz.StellarScope.PowermetricsAgent 2>/dev/null || true; launchctl bootstrap system '$PLIST'; launchctl kickstart -k system/com.lmz.StellarScope.PowermetricsAgent || true"


echo "Launched. Waiting for first sample..."
sleep 4
if [[ -f /tmp/stellarscope-powermetrics.json ]]; then
  echo "OK: JSON exists."
  cat /tmp/stellarscope-powermetrics.json | head -80
else
  echo "JSON not found. Log tail:"
  tail -80 /tmp/stellarscope-powermetrics-agent.log || true
fi
read -k 1 "?按任意键退出..."
