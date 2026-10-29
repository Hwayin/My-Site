#!/usr/bin/env bash
# =============================================================================
#  方案 B（备选）：服务器主动拉取更新
#  适用：GitHub Actions 连服务器不稳定，或你暂时不想配 Secrets。
#  原理：服务器定时 git pull -> 构建 -> 拷贝静态文件 -> 重启 API。
#  代价：构建在 1.9G 内存上进行，需要 bootstrap.sh 建好的 swap；耗时约 1~2 分钟。
#
#  安装（以 root 执行一次）：
#    sudo install -m 755 server-pull-deploy.sh /usr/local/bin/site-pull-deploy
#    sudo -u deploy bash -c 'cat > /opt/site/.git-credentials ...'   # 见 README 备选方案
#    # 定时：systemd timer 或 crontab
#    echo '*/5 * * * * deploy /usr/local/bin/site-pull-deploy >> /var/log/site-pull-deploy.log 2>&1' \
#      | sudo tee /etc/cron.d/site-pull-deploy
# =============================================================================
set -euo pipefail

APP_NAME="${APP_NAME:-site}"
REPO_URL="${REPO_URL:?请设置 REPO_URL，例如 https://github.com/you/repo.git}"
BRANCH="${BRANCH:-main}"
SRC_DIR="${SRC_DIR:-/opt/${APP_NAME}/src}"      # 源码检出目录
REPO_DIR="${REPO_DIR:-/opt/${APP_NAME}}"
WEB_DIR="${WEB_DIR:-/var/www/${APP_NAME}}"
SERVICE="${APP_NAME}-api"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# 1) 检出/更新代码
if [ -d "${SRC_DIR}/.git" ]; then
  log "拉取更新"
  git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$SRC_DIR" reset --hard "origin/${BRANCH}"
else
  log "首次克隆"
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi

cd "$SRC_DIR"

# 2) 构建前端（npm ci 需要 package-lock.json）
log "构建前端"
npm ci --prefix frontend --no-audit --no-fund
npm run build --prefix frontend

# 3) 打包后端
log "打包后端"
npm ci --prefix backend --no-audit --no-fund
npm run build --prefix backend

# 4) 版本信息
SHA="$(git rev-parse HEAD)"
SHORT="${SHA:0:7}"
MSG="$(git log -1 --pretty=%s | head -c 200)"
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SHA="$SHA" SHORT="$SHORT" BRANCH="$BRANCH" MSG="$MSG" NOW="$NOW" node -e '
  const fs = require("fs");
  const v = {
    sha: process.env.SHA, short: process.env.SHORT, ref: process.env.BRANCH,
    message: process.env.MSG, builtAt: process.env.NOW, deployedAt: new Date().toISOString(),
  };
  fs.writeFileSync("frontend/dist/version.json", JSON.stringify(v, null, 2));
  fs.writeFileSync("VERSION", JSON.stringify(v, null, 2));
'

# 5) 发布
log "同步产物"
rsync -a --delete "${SRC_DIR}/frontend/dist/" "${WEB_DIR}/"
mkdir -p "${REPO_DIR}/backend/dist"
rsync -a --delete "${SRC_DIR}/backend/dist/" "${REPO_DIR}/backend/dist/"
install -m 644 "${SRC_DIR}/VERSION" "${REPO_DIR}/VERSION"

log "重启 ${SERVICE}"
sudo "${SYSTEMCTL_BIN:-/usr/bin/systemctl}" restart "$SERVICE"
sleep 2
sudo "${SYSTEMCTL_BIN:-/usr/bin/systemctl}" is-active "$SERVICE"

log "发布完成：${SHORT} ${MSG}"
