#!/usr/bin/env bash
# 把 GitHub Actions 的公钥装到部署用户的 authorized_keys
# 用法：sudo bash add-deploy-key.sh 'ssh-ed25519 AAAAC3... github-actions-site'
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
KEY="${1:-}"

if [ -z "$KEY" ]; then
  echo "用法: sudo bash add-deploy-key.sh 'ssh-ed25519 AAAAC3Nza... 备注'"
  echo "公钥内容来自你本地生成的 ~/.ssh/site_deploy.pub"
  exit 1
fi

case "$KEY" in
  ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) ;;
  *) echo "[x] 这不像一行 SSH 公钥：$KEY" >&2; exit 1 ;;
esac

id -u "$DEPLOY_USER" >/dev/null 2>&1 || { echo "[x] 用户 $DEPLOY_USER 不存在，先跑 bootstrap.sh" >&2; exit 1; }

HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH="${SSH_DIR}/authorized_keys"

install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SSH_DIR"
touch "$AUTH"

FINGERPRINT="$(printf '%s\n' "$KEY" | awk '{print $1" "$2}')"
if grep -qF "$FINGERPRINT" "$AUTH" 2>/dev/null; then
  echo "[i] 这把公钥已经存在，跳过"
else
  printf '%s\n' "$KEY" >> "$AUTH"
  echo "[ok] 已添加公钥"
fi

chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH"
chmod 600 "$AUTH"
echo "[i] 当前授权公钥数量：$(wc -l < "$AUTH")"
