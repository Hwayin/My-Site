#!/usr/bin/env bash
# =============================================================================
#  一键初始化：Ubuntu 22.04 / 24.04（腾讯云轻量、CVM、任意云主机通用）
#
#  用法（服务器上以 root 执行）：
#     sudo bash bootstrap.sh
#  可覆盖的参数（示例）：
#     sudo APP_NAME=mysite API_PORT=3000 SERVER_NAME=example.com bash bootstrap.sh
#
#  做的事：swap -> Node 20 -> Nginx -> deploy 用户 -> 目录 -> systemd -> 站点
#  幂等：可以重复执行，不会重复加 swap、不会重复写 systemd 配置
# =============================================================================
set -euo pipefail

APP_NAME="${APP_NAME:-site}"
API_PORT="${API_PORT:-3000}"
SERVER_NAME="${SERVER_NAME:-_}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
REPO_DIR="${REPO_DIR:-/opt/${APP_NAME}}"
WEB_DIR="${WEB_DIR:-/var/www/${APP_NAME}}"
NODE_MAJOR="${NODE_MAJOR:-20}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

SERVICE="${APP_NAME}-api"

C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
log()  { printf '\n%s==> %s%s\n' "$C_OK" "$*" "$C_OFF"; }
warn() { printf '%s[!] %s%s\n'   "$C_WARN" "$*" "$C_OFF"; }
die()  { printf '%s[x] %s%s\n'   "$C_ERR" "$*" "$C_OFF"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash bootstrap.sh"
command -v apt-get >/dev/null || die "这个脚本只支持 Debian/Ubuntu"
. /etc/os-release
log "系统：${PRETTY_NAME}"

# ---------------------------------------------------------------- 1. 基础软件
log "安装基础软件包"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg lsb-release rsync nginx ufw \
  htop unzip jq git tzdata

# ---------------------------------------------------------------- 2. swap
# 1.9G 内存跑 Nginx + Node 够用，但构建/更新时需要余量，内存不足 Node 会被 OOM Kill
if swapon --show | grep -q .; then
  log "已存在 swap，跳过"
else
  log "创建 ${SWAP_SIZE} swap"
  if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  cat > /etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl --system >/dev/null
fi

# ---------------------------------------------------------------- 3. Node.js
# 注意：新系统（Ubuntu 25.10 / 26.04 等）NodeSource 可能还不支持，
# 所以这里准备了两条路：先试 NodeSource，失败则回退官方二进制包到 /usr/local。
NODE_DIST_VER="${NODE_DIST_VER:-20.19.5}"

install_node_tarball() {
  local arch name url
  case "$(uname -m)" in
    x86_64|amd64)  arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
  name="node-v${NODE_DIST_VER}-linux-${arch}"
  log "安装官方二进制包 Node v${NODE_DIST_VER} (${arch})"
  curl -fsSL --retry 3 -o /tmp/node.tar.gz "https://npmmirror.com/mirrors/node/v${NODE_DIST_VER}/${name}.tar.gz" \
    || curl -fsSL --retry 3 -o /tmp/node.tar.gz "https://nodejs.org/dist/v${NODE_DIST_VER}/${name}.tar.gz" \
    || die "Node 下载失败，请检查网络后重试"
  mkdir -p /usr/local/lib/nodejs
  tar -xzf /tmp/node.tar.gz -C /usr/local/lib/nodejs
  local bin
  for bin in node npm npx; do
    ln -sf "/usr/local/lib/nodejs/${name}/bin/${bin}" "/usr/local/bin/${bin}"
  done
  rm -f /tmp/node.tar.gz
  hash -r
}

if command -v node >/dev/null 2>&1; then
  CUR_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
else
  CUR_MAJOR=0
fi

if [ "$CUR_MAJOR" -lt "$NODE_MAJOR" ]; then
  log "安装 Node.js ${NODE_MAJOR}.x"
  if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource.sh 2>/dev/null \
     && bash /tmp/nodesource.sh >/tmp/nodesource.log 2>&1 \
     && apt-get install -y nodejs >>/tmp/nodesource.log 2>&1; then
    log "NodeSource 源安装完成"
  else
    warn "NodeSource 不支持当前系统（${PRETTY_NAME}），改用官方二进制包"
    # 清掉 NodeSource 可能留下的坏源，避免以后 apt update 报错
    rm -f /etc/apt/sources.list.d/nodesource*.list /etc/apt/keyrings/nodesource.gpg \
          /usr/share/keyrings/nodesource.gpg 2>/dev/null || true
    install_node_tarball
  fi
else
  log "Node 已是 $(node -v)，跳过"
fi

# 二次校验：如果 apt 装到的是老版本，仍然回退
if command -v node >/dev/null 2>&1; then
  CUR_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
else
  CUR_MAJOR=0
fi
if [ "$CUR_MAJOR" -lt "$NODE_MAJOR" ]; then
  warn "当前 Node 版本过低，改用二进制包"
  install_node_tarball
fi

command -v node >/dev/null || die "Node 安装失败"
node -v
npm -v

# ---------------------------------------------------------------- 4. 部署用户
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  log "用户 ${DEPLOY_USER} 已存在"
else
  log "创建部署用户 ${DEPLOY_USER}"
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
touch "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"

# ---------------------------------------------------------------- 5. 目录
log "准备目录"
mkdir -p "${REPO_DIR}/backend/dist" "${WEB_DIR}"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$REPO_DIR" "$WEB_DIR"
chmod 755 /var/www /var/www/"${APP_NAME}" 2>/dev/null || true

# 首次部署前显示一个占位页，避免访问 403
if [ ! -f "${WEB_DIR}/index.html" ]; then
  cat > "${WEB_DIR}/index.html" <<EOF
<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>${APP_NAME}</title>
<body style="font-family:system-ui;background:#0b1020;color:#e6edf7;display:grid;place-items:center;height:100vh;margin:0">
<div style="text-align:center"><h1>环境已就绪</h1>
<p style="color:#94a3b8">等待第一次 GitHub Actions 发布…</p></div></body></html>
EOF
  chown "$DEPLOY_USER:$DEPLOY_USER" "${WEB_DIR}/index.html"
fi

# ---------------------------------------------------------------- 6. systemd
log "写入 systemd 服务 ${SERVICE}"
NODE_BIN="$(command -v node)"
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=${APP_NAME} API (Node.js)
Documentation=https://github.com
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DEPLOY_USER}
Group=${DEPLOY_USER}
WorkingDirectory=${REPO_DIR}/backend
Environment=NODE_ENV=production
Environment=PORT=${API_PORT}
Environment=APP_NAME=${APP_NAME}
Environment=VERSION_FILE=${REPO_DIR}/VERSION
ExecStart=${NODE_BIN} ${REPO_DIR}/backend/dist/server.cjs
Restart=always
RestartSec=3
LimitNOFILE=65535

# 基础加固：只允许写自己的目录
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${REPO_DIR}

[Install]
WantedBy=multi-user.target
EOF

# Node 二进制在 /usr/bin，ProtectSystem=strict 下可读，无需额外放行

systemctl daemon-reload
systemctl enable "${SERVICE}" >/dev/null 2>&1 || true
# 服务在首次发布前没有 dist/server.cjs，先不启动（避免崩溃重启刷日志）
if [ -f "${REPO_DIR}/backend/dist/server.cjs" ]; then
  systemctl restart "${SERVICE}"
  log "服务已启动"
else
  warn "尚未发布代码，${SERVICE} 暂不启动"
fi

# ---------------------------------------------------------------- 7. sudo 权限
# 让 deploy 用户只能重启/查看本项目的服务，不能做别的 root 操作
log "配置 deploy 用户的最小 sudo 权限"
SYSTEMCTL_BIN="$(command -v systemctl)"
cat > "/etc/sudoers.d/${APP_NAME}-deploy" <<EOF
# 由 bootstrap.sh 生成：允许部署用户管理 ${SERVICE}，其余一律禁止
${DEPLOY_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} restart ${SERVICE}, \\
    ${SYSTEMCTL_BIN} start ${SERVICE}, ${SYSTEMCTL_BIN} stop ${SERVICE}, \\
    ${SYSTEMCTL_BIN} status ${SERVICE}, ${SYSTEMCTL_BIN} is-active ${SERVICE}, \\
    ${SYSTEMCTL_BIN} daemon-reload
EOF
chmod 440 "/etc/sudoers.d/${APP_NAME}-deploy"
visudo -cf "/etc/sudoers.d/${APP_NAME}-deploy" >/dev/null

# ---------------------------------------------------------------- 8. Nginx
log "配置 Nginx 站点"
mkdir -p /etc/nginx/snippets
cat > "/etc/nginx/sites-available/${APP_NAME}.conf" <<EOF
# 由 bootstrap.sh 生成 —— 改域名只需改 server_name，然后 nginx -t && systemctl reload nginx
server {
    listen 80 default_server;
    server_name ${SERVER_NAME};

    root ${WEB_DIR};
    index index.html;

    # 上传接口需要的话调大
    client_max_body_size 20m;

    # 不暴露版本号
    server_tokens off;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/javascript application/json application/xml image/svg+xml;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # 带 hash 的静态资源长缓存
    location /assets/ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files \$uri =404;
    }

    # 版本文件不缓存，前端靠它判断是否有新构建
    location = /version.json {
        add_header Cache-Control "no-store";
        try_files \$uri =404;
    }

    # 前后端分离的关键：/api 反代到 Node
    location /api/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    # 前端路由（history 模式）回退到 index.html
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/${APP_NAME}.conf" "/etc/nginx/sites-enabled/${APP_NAME}.conf"

# 关键：nginx.conf 里是 include /etc/nginx/sites-enabled/*;
# 所以「重命名成 .bak」没用，文件仍会被加载。必须把符号链接/文件真正移出这个目录。
rm -f /etc/nginx/sites-enabled/default
for f in /etc/nginx/sites-enabled/*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case "$f" in */"${APP_NAME}.conf") continue ;; esac
  if grep -q 'default_server' "$f" 2>/dev/null; then
    mv "$f" "/etc/nginx/sites-available/$(basename "$f").disabled"
    warn "已禁用冲突站点：${f}"
  fi
done
# conf.d 的 glob 是 *.conf，改名成 .bak 后不会再被加载
for f in /etc/nginx/conf.d/*.conf; do
  [ -e "$f" ] || continue
  if grep -q 'default_server' "$f" 2>/dev/null; then
    mv "$f" "${f}.bak"
    warn "已禁用冲突配置：${f} -> ${f}.bak"
  fi
done

NGINX_FAILED=0
if nginx -t 2>/tmp/nginx-test.log; then
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  log "Nginx 已生效"
else
  NGINX_FAILED=1
  warn "Nginx 配置校验失败，已跳过 reload，错误如下："
  sed 's/^/    /' /tmp/nginx-test.log
fi

# ---------------------------------------------------------------- 9. 防火墙
log "配置 ufw（云厂商安全组仍需单独放行 80/443）"
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
if ufw status | grep -q "Status: inactive"; then
  yes | ufw enable >/dev/null 2>&1 || warn "ufw 启用失败（容器环境常见，可忽略；用云安全组即可）"
fi
ufw status | head -n 8 || true

# ---------------------------------------------------------------- 10. 收尾提示
PUB_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
cat <<EOF

$C_OK============================================================$C_OFF
 初始化完成
$C_OK============================================================$C_OFF
 应用名        : ${APP_NAME}
 站点目录      : ${WEB_DIR}   (属主 ${DEPLOY_USER})
 后端目录      : ${REPO_DIR}/backend   (属主 ${DEPLOY_USER})
 版本文件      : ${REPO_DIR}/VERSION
 后端端口      : 127.0.0.1:${API_PORT}   (仅本机，不对外暴露)
 systemd 服务  : ${SERVICE}
 部署用户      : ${DEPLOY_USER}

 下一步（在你本地电脑执行）：

 1) 生成部署密钥（本地，不要放服务器）：
      ssh-keygen -t ed25519 -C "github-actions-${APP_NAME}" -f ~/.ssh/${APP_NAME}_deploy -N ""

 2) 把公钥装到服务器：
      ssh-copy-id -i ~/.ssh/${APP_NAME}_deploy.pub ${DEPLOY_USER}@${PUB_IP}
    或者把 ~/.ssh/${APP_NAME}_deploy.pub 的内容贴到服务器执行：
      sudo bash deploy/scripts/add-deploy-key.sh 'ssh-ed25519 AAAA...'

 3) GitHub 仓库 Settings -> Secrets and variables -> Actions 添加：
      SSH_HOST         ${PUB_IP}
      SSH_USER         ${DEPLOY_USER}
      SSH_PORT         22
      DEPLOY_SSH_KEY   ~/.ssh/${APP_NAME}_deploy 的【私钥全文】

 4) push 到 main，等待 Actions 变绿，浏览器打开
      http://${PUB_IP}

 记得去云厂商控制台「防火墙/安全组」放行 TCP 80、443。
EOF

if [ "${NGINX_FAILED:-0}" -eq 1 ]; then
  printf '\n%s[x] 注意：Nginx 没生效（上面有报错）。常见原因是还有别的配置也写了 default_server：\n' "$C_ERR"
  printf '    ls -l /etc/nginx/sites-enabled/ /etc/nginx/conf.d/\n'
  printf '    grep -rl default_server /etc/nginx/\n%s' "$C_OFF"
  exit 1
fi
