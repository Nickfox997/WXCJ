#!/usr/bin/env bash
# Linux 原生交叉编译环境（不使用 Theos）
# 原理：clang 直接出 arm64/arm64e Mach-O 目标文件，用 LLVM 的 ld64.lld 链接，
#       绕开 Theos 在 Linux 上缺失 cctools/ld64 toolchain 的问题。
# 用法：
#   bash scripts/linux-setup.sh

set -uo pipefail
SDK_HOME="${SDK_HOME:-$HOME/ios-sdks}"

echo "== [1/5] apt =="
sudo apt-get update -qq
# clang 编译、lld 提供 Mach-O 链接器、llvm 提供 llvm-lipo
sudo apt-get install -y -qq clang lld llvm git curl unzip python3 \
    libssl-dev zlib1g-dev \
  || { echo "核心包安装失败"; exit 1; }
sudo apt-get install -y -qq ldid 2>/dev/null || echo "  (apt 无 ldid，稍后手动取)"

echo "== [2/5] 验证 Mach-O 链接器 =="
LD64=$(command -v ld64.lld || command -v ld64.lld-18 || ls /usr/bin/ld64.lld* 2>/dev/null | head -1)
if [ -z "$LD64" ]; then
    echo "!! 找不到 ld64.lld —— 没有它就链接不出 Mach-O"
    echo "   尝试：sudo apt install lld-18 或 sudo apt install lld-17"
    exit 1
fi
echo "  ld64.lld = $LD64"
LIPO=$(command -v llvm-lipo || command -v llvm-lipo-18 || ls /usr/bin/llvm-lipo* 2>/dev/null | head -1)
echo "  llvm-lipo = ${LIPO:-缺失（单架构可不用）}"

echo "== [3/5] ldid =="
if ! command -v ldid >/dev/null 2>&1; then
    ok=0
    for url in \
      "https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64.zip" \
      "https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64"
    do
        curl -fL "$url" -o /tmp/ldid.bin 2>/dev/null && { ok=1; break; }
    done
    if [ "$ok" = "1" ]; then
        if file /tmp/ldid.bin | grep -qi zip; then
            sudo unzip -o -q /tmp/ldid.bin -d /usr/local/bin/
        else
            sudo cp /tmp/ldid.bin /usr/local/bin/ldid
        fi
        sudo chmod +x /usr/local/bin/ldid
        found=$(sudo find /usr/local/bin -maxdepth 1 -name 'ldid*' -type f | head -1)
        [ -n "$found" ] && sudo ln -sf "$found" /usr/local/bin/ldid
    fi
fi
command -v ldid >/dev/null 2>&1 && { echo -n "  ldid: "; ldid -v 2>&1 | head -1; } || echo "  ldid: 缺失（不影响产物，全能签会重签）"

echo "== [4/5] iOS SDK（只取最新一个）=="
mkdir -p "$SDK_HOME"
if ls "$SDK_HOME"/*.sdk >/dev/null 2>&1; then
    echo "  已有 SDK，跳过"
else
    LATEST=$(curl -fsSL https://api.github.com/repos/theos/sdks/contents/ 2>/dev/null \
      | python3 -c 'import sys,json
try:
    ns=[x["name"] for x in json.load(sys.stdin) if x["name"].startswith("iPhoneOS") and x["name"].endswith(".sdk")]
    ns.sort(key=lambda s:[int(p) for p in s.replace("iPhoneOS","").replace(".sdk","").split(".")])
    print(ns[-1] if ns else "")
except Exception:
    print("")' 2>/dev/null)
    [ -z "${LATEST:-}" ] && LATEST="iPhoneOS16.5.sdk"
    echo "  目标: $LATEST"
    git clone --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks-src \
      && ( cd /tmp/sdks-src && git sparse-checkout set "$LATEST" ) \
      && cp -R "/tmp/sdks-src/$LATEST" "$SDK_HOME/" \
      && rm -rf /tmp/sdks-src \
      || echo "!! SDK 获取失败；若 GitHub 不通，可用共享文件夹从 Windows 拷入"
fi
echo -n "  SDK: "; ls -d "$SDK_HOME"/*.sdk 2>/dev/null | head -1

echo "== [5/5] 写入配置 =="
if [ -w "$HOME" ] && ! grep -q 'SDK_HOME=' "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ''
        echo '# ---- WCAI native toolchain ----'
        echo "export SDK_HOME=$SDK_HOME"
        echo "export LD64=$LD64"
        [ -n "${LIPO:-}" ] && echo "export LIPO=$LIPO"
    } >> "$HOME/.bashrc"
fi

echo
echo "======================================================"
echo "自检："
echo -n "  clang     = "; command -v clang || echo 缺失
echo -n "  ld64.lld  = "; echo "$LD64"
echo -n "  llvm-lipo = "; echo "${LIPO:-缺失}"
echo -n "  SDK       = "; ls -d "$SDK_HOME"/*.sdk 2>/dev/null | head -1
echo "======================================================"
echo "下一步：bash scripts/native-build.sh"
