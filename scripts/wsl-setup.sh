#!/usr/bin/env bash
# WSL(Ubuntu) 一次性环境安装：工具链 + Theos + iOS SDK
# 用法：在 Ubuntu 终端里执行
#   bash /mnt/g/智能体工作区/DSH-微信AI助手/scripts/wsl-setup.sh

set -uo pipefail

echo "== [1/6] apt 索引 =="
sudo apt update || { echo "apt update 失败，检查网络/源"; exit 1; }

echo "== [2/6] 基础工具链 =="
sudo apt install -y git make clang fakeroot dpkg-dev xz-utils unzip curl \
    libssl-dev zlib1g-dev libtinfo-dev libplist-utils libplist-dev \
    libplist++-dev || true

echo "== [3/6] ldid =="
if ! command -v ldid >/dev/null 2>&1; then
    echo "apt 无 ldid，尝试从 Procursus 拉取..."
    curl -fL -o /tmp/ldid.zip \
        https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64.zip 2>/dev/null \
      && sudo unzip -o /tmp/ldid.zip -d /usr/local/bin/ \
      && sudo chmod +x /usr/local/bin/ldid \
      && echo "ldid 安装完成" \
      || echo "!! ldid 自动安装失败，请手动下载 ldid_linux_x86_64.zip 解压到 /usr/local/bin"
fi
command -v ldid >/dev/null 2>&1 && ldid -v 2>&1 | head -2

echo "== [4/6] Theos =="
if [ ! -d "$HOME/theos/makefiles" ]; then
    git clone --recursive https://github.com/theos/theos.git "$HOME/theos" \
      || { echo "theos clone 失败"; exit 1; }
else
    echo "已存在，跳过 clone"
fi

echo "== [5/6] iOS SDK =="
mkdir -p "$HOME/theos/sdks"
if ! ls "$HOME"/theos/sdks/*.sdk >/dev/null 2>&1; then
    curl -fL https://github.com/theos/sdks/archive/refs/heads/master.tar.gz -o /tmp/sdks.tgz \
      || { echo "SDK 下载失败，手动放 .sdk 到 ~/theos/sdks/"; exit 1; }
    tar xzf /tmp/sdks.tgz -C /tmp
    # 只装最新的一个 iPhoneOS SDK：全量拷贝要 10G+，Codespaces 磁盘扛不住
    LATEST=$(ls -d /tmp/sdks-master/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1)
    if [ -n "${LATEST:-}" ]; then
        cp -R "$LATEST" "$HOME/theos/sdks/"
        echo "已安装 $(basename "$LATEST")（只装最新一个）"
    else
        echo "!! 未找到 iPhoneOS*.sdk，退回全量拷贝"
        cp -R /tmp/sdks-master/*.sdk "$HOME/theos/sdks/" 2>/dev/null || true
    fi
    rm -rf /tmp/sdks-master /tmp/sdks.tgz
fi
echo "SDK 列表："; ls "$HOME"/theos/sdks

echo "== [6/6] 环境变量 =="
if ! grep -q 'export THEOS=' "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ''
        echo '# ---- Theos ----'
        echo 'export THEOS=$HOME/theos'
        echo 'export PATH=$THEOS/bin:$PATH'
    } >> "$HOME/.bashrc"
fi
export THEOS="$HOME/theos"
export PATH="$THEOS/bin:$PATH"

echo
echo "======================================================"
echo "自检："
echo "  THEOS = $THEOS"
echo -n "  make  = "; command -v make || echo "缺失"
echo -n "  clang = "; command -v clang || echo "缺失"
echo -n "  ldid  = "; command -v ldid || echo "缺失"
echo "======================================================"
echo "下一步：新开一个终端（或 source ~/.bashrc），然后执行"
echo "  bash /mnt/g/智能体工作区/DSH-微信AI助手/scripts/wsl-build.sh"
