#!/usr/bin/env bash
# CodexQuota one-line installer
#   curl -fsSL https://raw.githubusercontent.com/sergioperezcheco/CodexQuota/main/scripts/install.sh | bash
set -euo pipefail

REPO_URL="${CODEXQUOTA_REPO:-https://github.com/sergioperezcheco/CodexQuota.git}"
INSTALL_DIR="/Applications"
BRANCH="main"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Xcode Command Line Tools ─────────────────────────────────────────────
if ! command -v swiftc >/dev/null 2>&1; then
    log "swiftc 不存在，尝试定位 Xcode CLT…"
    if xcode-select -p >/dev/null 2>&1; then
        fail "xcode-select 指向 $(xcode-select -p) 但没有 swiftc，请重装 Command Line Tools"
    fi
    log "提示: 将弹出安装 Xcode Command Line Tools 的窗口，装完后重新运行本脚本"
    xcode-select --install || fail "无法启动 CLT 安装器"
    exit 1
fi

# ── Clone ────────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log "克隆仓库 $REPO_URL …"
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP/CodexQuota" 2>/dev/null \
    || git clone --depth 1 "$REPO_URL" "$TMP/CodexQuota" \
    || fail "git clone 失败（检查网络 / 仓库地址）"

# ── Build ────────────────────────────────────────────────────────────────
log "编译（约 10–30 秒）…"
cd "$TMP/CodexQuota"
swiftc -O -o "$TMP/CodexQuota" Sources/codex_quota.swift || fail "编译失败"

# ── Bundle ───────────────────────────────────────────────────────────────
log "打包 .app …"
mkdir -p "$TMP/CodexQuota.app/Contents/MacOS"
cp "$TMP/CodexQuota" "$TMP/CodexQuota.app/Contents/MacOS/CodexQuota"
cp Info.plist "$TMP/CodexQuota.app/Contents/Info.plist"

# Ad-hoc sign the bundle. An unsigned/linker-signed bundle makes
# SMAppService.mainApp.register() fail → launch-at-login silently broken.
log "签名 …"
codesign --force --deep --sign - "$TMP/CodexQuota.app" || fail "codesign 失败"

# ── Install ──────────────────────────────────────────────────────────────
log "安装到 $INSTALL_DIR …"
if [ -d "$INSTALL_DIR/CodexQuota.app" ]; then
    pkill -x CodexQuota 2>/dev/null || true
    sleep 1
fi
cp -R "$TMP/CodexQuota.app" "$INSTALL_DIR/" || fail "复制到 $INSTALL_DIR 失败（权限不足？尝试 sudo 或改 INSTALL_DIR）"

# ── Launch ───────────────────────────────────────────────────────────────
log "启动 CodexQuota …"
open "$INSTALL_DIR/CodexQuota.app"
# The app registers itself as a login item on first launch (SMAppService,
# with an automatic LaunchAgent fallback if registration fails).

cat <<'EOF'

  ✅ CodexQuota 安装完成！
     菜单栏出现 ● Codex:x%|x% 即成功。

     · Codex 监控自动生效（需登录过 Codex CLI）
     · GLM 监控:  launchctl setenv GLM_API_KEY "你的key" 后重启 app

EOF
