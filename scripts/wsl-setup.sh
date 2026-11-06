#!/usr/bin/env bash
# Linux 环境一次性安装：工具链 + Theos + 最新 iOS SDK
# 适用于：WSL / GitHub Actions(ubuntu) / 云服务器 / Codespaces
# 用法：
#   bash scripts/wsl-setup.sh

set -uo pipefail

THEOS_DIR="${THEOS:-$HOME/theos}"

echo "== [1/6] apt 索引 =="
sudo apt-get update -qq || { echo "apt update 失败"; exit 1; }

# 核心包：必须成功
echo "== [2/6] 核心工具链 =="
sudo apt-get install -y -qq git make clang fakeroot dpkg-dev xz-utils unzip curl \
    libssl-dev zlib1g-dev libplist-utils libplist-dev \
  || { echo "核心工具链安装失败"; exit 1; }

# 可选包：装不上不影响构建（不同发行版包名不一致）
echo "== [2b] 可选包（失败忽略）=="
sudo apt-get install -y -qq libtinfo-dev libncurses-dev ldid 2>/dev/null || true

echo "== [3/6] ldid =="
if ! command -v ldid >/dev/null 2>&1; then
    echo "apt 无 ldid，从 Procursus 取静态二进制..."
    ok=0
    for url in \
      "https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64.zip" \
      "https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64"
    do
        if curl -fL "$url" -o /tmp/ldid.bin 2>/dev/null; then ok=1; break; fi
    done
    if [ "$ok" = "1" ]; then
        if file /tmp/ldid.bin 2>/dev/null | grep -qi zip; then
            sudo unzip -o -q /tmp/ldid.bin -d /usr/local/bin/
        else
            sudo cp /tmp/ldid.bin /usr/local/bin/ldid
        fi
        sudo chmod +x /usr/local/bin/ldid 2>/dev/null
        # zip 里可能是子目录，兜底找一下
        if ! command -v ldid >/dev/null 2>&1; then
            found=$(sudo find /usr/local/bin -name 'ldid*' -type f 2>/dev/null | head -1)
            [ -n "$found" ] && sudo ln -sf "$found" /usr/local/bin/ldid
        fi
    else
        echo "!! ldid 获取失败，signing 步骤会跳过（dylib 仍可产出，全能签会重新签名）"
    fi
fi
command -v ldid >/dev/null 2>&1 && { echo -n "  ldid: "; ldid -v 2>&1 | head -1; } || echo "  ldid: 缺失（不阻断）"

echo "== [4/6] Theos =="
if [ ! -d "$THEOS_DIR/makefiles" ]; then
    git clone --recursive --depth 1 https://github.com/theos/theos.git "$THEOS_DIR" \
      || { echo "theos clone 失败"; exit 1; }
else
    echo "  已存在，跳过"
fi

echo "== [5/6] iOS SDK（只取最新的一个）=="
mkdir -p "$THEOS_DIR/sdks"
if ls "$THEOS_DIR"/sdks/*.sdk >/dev/null 2>&1; then
    echo "  已存在 SDK，跳过"
else
    # 全量 sdks 仓库解压约 15G，CI runner 只有 ~14G 可用 → 必须 sparse 只取一个
    LATEST=$(curl -fsSL https://api.github.com/repos/theos/sdks/contents/ 2>/dev/null \
      | python3 -c '
import sys, json
try:
    ns = [x["name"] for x in json.load(sys.stdin)
          if x["name"].startswith("iPhoneOS") and x["name"].endswith(".sdk")]
    ns.sort(key=lambda s: [int(p) for p in s.replace("iPhoneOS","").replace(".sdk","").split(".")])
    print(ns[-1] if ns else "")
except Exception:
    print("")
' 2>/dev/null)
    [ -z "${LATEST:-}" ] && LATEST="iPhoneOS16.5.sdk"
    echo "  目标 SDK: $LATEST"

    git clone --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks-src \
      || { echo "!! sdks 仓库 clone 失败"; }
    if [ -d /tmp/sdks-src ]; then
        ( cd /tmp/sdks-src && git sparse-checkout set "$LATEST" ) || true
        if [ -d "/tmp/sdks-src/$LATEST" ]; then
            cp -R "/tmp/sdks-src/$LATEST" "$THEOS_DIR/sdks/"
            echo "  已安装 $LATEST"
        else
            echo "!! sparse checkout 未拿到 $LATEST"
        fi
        rm -rf /tmp/sdks-src
    fi
fi
echo -n "  SDK 列表: "; ls "$THEOS_DIR"/sdks 2>/dev/null | tr '\n' ' '; echo

echo "== [6/6] 环境变量 =="
export THEOS="$THEOS_DIR"
export PATH="$THEOS/bin:$PATH"
if [ -w "$HOME" ] && ! grep -q 'export THEOS=' "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ''
        echo '# ---- Theos ----'
        echo "export THEOS=$THEOS_DIR"
        echo 'export PATH=$THEOS/bin:$PATH'
    } >> "$HOME/.bashrc" 2>/dev/null || true
fi

echo
echo "======================================================"
echo "自检："
echo "  THEOS = $THEOS"
echo -n "  make  = "; command -v make  || echo "缺失"
echo -n "  clang = "; command -v clang || echo "缺失"
echo -n "  ldid  = "; command -v ldid  || echo "缺失（不阻断）"
echo "  SDK   = $(ls "$THEOS_DIR"/sdks 2>/dev/null | head -1)"
echo "======================================================"
echo "下一步：bash scripts/build-here.sh"
