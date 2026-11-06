#!/usr/bin/env bash
# 在「Linux 就在本机磁盘」的环境里直接编译（GitHub Codespaces / 云服务器 / 虚拟机）。
# 与 wsl-build.sh 的区别：不 rsync、不拷回，仓库本身就在 Linux 文件系统上。
# 用法：
#   bash scripts/build-here.sh

set -uo pipefail
export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/bin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$HERE/../WeChatAIChatTweak"

[ -d "$PROJ" ] || { echo "找不到工程目录：$PROJ"; exit 1; }

if [ ! -d "$THEOS/makefiles" ]; then
    echo "Theos 未安装，先跑：bash scripts/wsl-setup.sh"
    exit 1
fi

cd "$PROJ" || exit 1
echo "== 编译 ($(pwd)) =="
make 2>&1 | tee /tmp/wcai-build.log
RC=${PIPESTATUS[0]}

echo
if [ "$RC" -ne 0 ]; then
    echo "== 失败，最后 40 行 =="
    tail -40 /tmp/wcai-build.log
    exit "$RC"
fi

DYLIB=$(find "$PROJ/.theos" -name 'libmarsbridge.dylib' 2>/dev/null | head -n1)
[ -z "$DYLIB" ] && DYLIB=$(find "$PROJ/.theos" -name '*.dylib' 2>/dev/null | head -n1)

echo "== 成功 =="
file "$DYLIB"
lipo -info "$DYLIB" 2>/dev/null || true
ls -lh "$DYLIB"

# .theos 是隐藏目录，文件树里看不到 —— 拷到仓库根，右键即可下载
DEST="$HERE/../libmarsbridge.dylib"
cp -f "$DYLIB" "$DEST"
echo
echo "产物：$DYLIB"
echo "已复制到仓库根：$DEST"
echo "→ 在左侧文件树里右键 libmarsbridge.dylib → Download 即可拿到手机"
