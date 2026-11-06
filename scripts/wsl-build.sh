#!/usr/bin/env bash
# 每次编译用：把工程同步到 WSL 家目录编译（/mnt 上编译慢且偶发权限问题），
# 再把产物拷回 Windows。
# 用法：
#   bash /mnt/g/智能体工作区/DSH-微信AI助手/scripts/wsl-build.sh

set -uo pipefail
export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/bin:$PATH"

SRC="/mnt/g/智能体工作区/DSH-微信AI助手/WeChatAIChatTweak"
WORK="$HOME/wcai-build"

[ -d "$SRC" ] || { echo "找不到工程目录：$SRC"; exit 1; }

echo "== 同步工程到 $WORK =="
mkdir -p "$WORK"
rsync -a --delete --exclude '.theos' "$SRC/" "$WORK/" 2>/dev/null \
  || { rm -rf "$WORK"; cp -r "$SRC" "$WORK"; }

cd "$WORK" || exit 1

echo "== 编译 =="
make clean >/dev/null 2>&1 || true
if make 2>&1 | tee /tmp/wcai-build.log; then
    echo
    echo "== 编译成功 =="
else
    echo
    echo "== 编译失败，最后 40 行 =="
    tail -40 /tmp/wcai-build.log
    echo
    echo "把上面这段贴回去即可定位。"
    exit 1
fi

DYLIB=$(find "$WORK/.theos" -name 'libmarsbridge.dylib' 2>/dev/null | head -n1)
if [ -z "$DYLIB" ]; then
    echo "!! 没找到 libmarsbridge.dylib，列出产物："
    find "$WORK/.theos" -name '*.dylib' 2>/dev/null
    exit 1
fi

echo "== 产物 =="
file "$DYLIB"
lipo -info "$DYLIB" 2>/dev/null || true
ls -lh "$DYLIB"

echo "== 拷回 Windows =="
cp -f "$DYLIB" "$SRC/../libmarsbridge.dylib"
echo "已放到：$(cd "$SRC/.." && pwd)/libmarsbridge.dylib"
echo
echo "把它交给全能签注入即可。"
