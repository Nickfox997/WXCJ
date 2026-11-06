#!/usr/bin/env bash
# 不使用 Theos 的 iOS dylib 交叉编译（Linux）
# 关键点：-undefined dynamic_lookup 让微信的类符号留到运行时解析
# 用法：
#   bash scripts/native-build.sh
#   ARCHS="arm64" bash scripts/native-build.sh     # 只编 arm64，快一倍

set -uo pipefail

SDK_HOME="${SDK_HOME:-$HOME/ios-sdks}"
THEOS_DIR="${THEOS:-$HOME/theos}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../WeChatAIChatTweak" && pwd)"
OUT="$HERE/../libmarsbridge.dylib"

# ── SDK ──
SDK=$(ls -d "$SDK_HOME"/*.sdk 2>/dev/null | sort -V | tail -1)
[ -z "${SDK:-}" ] && SDK=$(ls -d "$THEOS_DIR"/sdks/*.sdk 2>/dev/null | sort -V | tail -1)
[ -z "${SDK:-}" ] && { echo "找不到 iOS SDK（先跑 scripts/linux-setup.sh）"; exit 1; }
echo "SDK: $SDK"

# ── 链接器 ──
LD64="${LD64:-$(command -v ld64.lld || command -v ld64.lld-18 || ls /usr/bin/ld64.lld* 2>/dev/null | head -1)}"
[ -z "$LD64" ] && { echo "找不到 ld64.lld（sudo apt install lld）"; exit 1; }
LIPO="${LIPO:-$(command -v llvm-lipo || command -v llvm-lipo-18 || ls /usr/bin/llvm-lipo* 2>/dev/null | head -1)}"
echo "LD64: $LD64"

ARCHS="${ARCHS:-arm64 arm64e}"

# 源文件
SRCS=$(ls "$PROJ"/src/*.m "$PROJ"/src/*.c 2>/dev/null | grep -v 'WCAIAutoEngine.m')
[ -z "$SRCS" ] && { echo "找不到源文件"; exit 1; }

COMMON=(
  -isysroot "$SDK"
  -fobjc-arc
  -O2
  -fvisibility=hidden
  -Wno-unused-function
  -Wno-deprecated-declarations
  -DWCAI_DISABLE_AUTO=1
  -DWCAI_MAIN_ACCOUNT_BUILD=1
  -DWCAI_ENABLE_GOT_PATCH=0
  -I "$PROJ/src"
)

LINK=(
  -dynamiclib
  -fuse-ld="$LD64"
  -install_name "@executable_path/Frameworks/libmarsbridge.dylib"
  -undefined dynamic_lookup
  -framework Foundation
  -framework UIKit
  -framework CoreGraphics
  -lsqlite3
  -Wl,-dead_strip
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BUILT=()

for A in $ARCHS; do
    echo "== 编译架构 $A =="
    OUTARCH="$TMP/wcai-$A.dylib"
    set -x
    clang -target "$A-apple-ios14.0" "${COMMON[@]}" "${LINK[@]}" \
          -o "$OUTARCH" $SRCS
    rc=$?
    set +x
    if [ $rc -ne 0 ]; then
        echo "!! $A 编译失败（上面是完整命令，可直接改参数复现）"
        exit 1
    fi
    BUILT+=("$OUTARCH")
    file "$OUTARCH"
done

if [ ${#BUILT[@]} -gt 1 ] && [ -n "${LIPO:-}" ]; then
    "$LIPO" -create "${BUILT[@]}" -output "$OUT"
else
    cp "${BUILT[0]}" "$OUT"
fi

echo
echo "== 产物 =="
ls -lh "$OUT"
file "$OUT"
if [ -n "${LIPO:-}" ]; then
    "$LIPO" -info "$OUT" 2>/dev/null || echo "(单架构)"
fi

if command -v ldid >/dev/null 2>&1; then
    ldid -S "$OUT" && echo "已 ldid 伪签"
fi

echo
echo "产物：$OUT"
