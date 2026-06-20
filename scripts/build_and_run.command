#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== StellarScope build =="
echo "Project: $PWD"

if ! command -v swift >/dev/null 2>&1; then
  echo "没有找到 swift。请先安装 Xcode，或运行：xcode-select --install"
  read -k 1 "?按任意键退出..."
  exit 1
fi

echo "== swift build -c release =="
swift build -c release

APP="$PWD/Build/StellarScope.app"
EXE="$PWD/.build/release/StellarScope"
SMC_PROBE="$PWD/.build/release/StellarScopeSMCProbe"
INFO="$PWD/Bundle/Info.plist"
AGENT_SRC="$PWD/Sources/StellarScope/Resources/stellarscope_powermetrics_agent.py"
ICON="$PWD/Bundle/AppIcon.icns"

if [[ ! -x "$EXE" ]]; then
  echo "构建产物不存在：$EXE"
  read -k 1 "?按任意键退出..."
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/agent"
cp "$EXE" "$APP/Contents/MacOS/StellarScope"
cp "$INFO" "$APP/Contents/Info.plist"
cp "$AGENT_SRC" "$APP/Contents/Resources/agent/stellarscope_powermetrics_agent.py"
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -x "$SMC_PROBE" ]]; then
  cp "$SMC_PROBE" "$APP/Contents/Resources/agent/StellarScopeSMCProbe"
fi
chmod +x "$APP/Contents/MacOS/StellarScope" "$APP/Contents/Resources/agent/stellarscope_powermetrics_agent.py"
if [[ -f "$APP/Contents/Resources/agent/StellarScopeSMCProbe" ]]; then
  chmod +x "$APP/Contents/Resources/agent/StellarScopeSMCProbe"
fi

# Ad-hoc sign makes local opening smoother. It does not notarize the app.
/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "== Done =="
echo "App 已生成：$APP"
if [[ "${STELLARSCOPE_SKIP_OPEN:-0}" == "1" ]]; then
  exit 0
fi
echo "正在退出旧的 StellarScope 实例..."
/usr/bin/osascript -e 'tell application id "com.lmz.StellarScope" to quit' >/dev/null 2>&1 || true
/usr/bin/pkill -x StellarScope >/dev/null 2>&1 || true
/bin/sleep 1
echo "正在打开 StellarScope..."
open "$APP"
