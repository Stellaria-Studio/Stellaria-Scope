#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
"$PWD/scripts/build_and_run.command"
APP="$PWD/Build/StellarScope.app"
DEST="/Applications/StellarScope.app"
if [[ -d "$APP" ]]; then
  echo "复制到 /Applications 可能需要管理员权限。"
  osascript -e "do shell script \"rm -rf '/Applications/StellarScope.app' && cp -R '$APP' '/Applications/'\" with administrator privileges"
  echo "已安装到：$DEST"
  open "$DEST"
fi
