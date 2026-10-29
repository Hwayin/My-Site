# 免费云主机部署手册：前后端分离 + GitHub 自动发布

> 目标机器：腾讯云轻量/CVM，Ubuntu，**2 核 / 1.9G 内存 / 48G 磁盘**，公网 IP `122.51.145.11`
> 目标形态：**Nginx 托管前端静态文件 + Node 提供 /api 接口**，`git push` 后 GitHub Actions 自动构建并发布。

部署完成后首页长这样（本地模拟 Nginx + 真实后端渲染）：

![部署后的首页](docs/preview.png)

---

## 0. 先看清楚这台机器

| 指标 | 实机数值 | 结论 |
|---|---|---|
| CPU | 2 核，负载 0.08 | 跑 Nginx + Node 绰绰有余 |
| 内存 | 1.9G（已用 419M） | **偏小**：必须加 2G swap，否则构建/突发流量会被 OOM Kill |
| 磁盘 | 48.5G，可用 40.9G | 充裕，够放代码 + 日志 + 数据库 |
| 峰值 IO | `/dev/shm` 只有 981M | 容器化轻量机，别指望大 tmpfs |
| 系统 | Ubuntu，86 个待更新 | 先 `apt upgrade`，再装环境 |

**由此确定的三个设计决策：**

1. **前端不在服务器上构建。** Vite 打包一次要吃 1G+ 内存，1.9G 的机器很危险。改为在 GitHub Actions 的 4G/16G 机器上 `vite build`，只把 `dist/` 里的静态文件传过去。
2. **后端打包成单文件再上传。** 用 esbuild 把 Express 打成 `server.cjs`，服务器上**不执行 `npm install`**，发布只做「传文件 + 重启」，秒级完成。
3. **后端只监听 `127.0.0.1:3000`。** 对外只开 Nginx 的 80/443，Node 端口不暴露到公网，安全组只放行 22/80/443。

---

## 1. 架构

```
                       ┌──────────────────────── 云主机 122.51.145.11 ───────────────────────┐
   浏览器 ──80/443──►  │  Nginx                                                              │
                       │   ├─ /            → /var/www/site/          （Vue3 构建出的静态文件）│
                       │   ├─ /assets/*    → 长缓存 30d                                      │
                       │   ├─ /version.json→ 不缓存（前端据此判断是否最新）                   │
                       │   └─ /api/*       → 127.0.0.1:3000  ──►  Node/Express (systemd)    │
                       │                                              ├─ /api/health          │
                       │                                              ├─ /api/version         │
                       │                                              └─ /api/hello           │
                       └─────────────────────────────────────────────────────────────────────┘
                                     ▲                                   ▲
                                     │ rsync（Actions 里构建好，只传产物） │
                       ┌─────────────┴─────────────┐                     │
                       │  GitHub Actions（ubuntu）  │                     │
                       │  build → upload-artifact → deploy                  │
                       └───────────────────────────────────────────────────┘
                                     ▲
                                  git push main
```

访问链路只有一条：**浏览器 → Nginx**。前端和后端同域，所以**没有跨域（CORS）问题**，也不需要配 `Access-Control-Allow-Origin`。

---

## 2. 目录结构

```
free-server-site/
├─ .github/workflows/deploy.yml      # 构建 + 发布流水线（核心）
├─ frontend/                         # Vue 3 + Vite
│  ├─ index.html
│  ├─ vite.config.js                 # 本地 dev 把 /api 代理到 :3000
│  └─ src/{main.js, App.vue, style.css}
├─ backend/                          # Express（ESM 源码，esbuild 打成 CJS 单文件）
│  ├─ package.json
│  └─ src/server.js
└─ deploy/scripts/
   ├─ bootstrap.sh                   # 服务器一键初始化（swap/Node/Nginx/用户/systemd）
   ├─ add-deploy-key.sh              # 装 GitHub 部署公钥
   └─ server-pull-deploy.sh          # 备选方案 B：服务器主动拉取更新
```

服务器上的落点：

| 路径 | 内容 | 属主 |
|---|---|---|
| `/var/www/site/` | 前端 `dist/` 产物 | `deploy` |
| `/opt/site/backend/dist/server.cjs` | 后端单文件 | `deploy` |
| `/opt/site/VERSION` | 当前版本 JSON（sha/分支/构建时间） | `deploy` |
| `/etc/systemd/system/site-api.service` | 后端服务 | root |
| `/etc/nginx/sites-available/site.conf` | Nginx 站点 | root |

---

## 3. 部署前，先做这 3 件事

### 3.1 开放端口（最常见的坑）

> 两代产品的叫法不同，别找错地方：
> **云服务器 CVM** 没有「防火墙」菜单，等价物是 **安全组（Security Group）**；
> **轻量应用服务器 Lighthouse** 才叫 **防火墙**。

**A. 云服务器 CVM（本文这台）**

路径任选一条：

- 控制台左侧 **网络与安全 → 安全组**（会用新窗口打开 VPC 控制台），选地域 **上海**
- 或者：实例列表点实例 ID → **安全组** 标签页 → **配置规则**

然后 → **入站规则 → 添加规则**，填两行（出站规则不用动）：

| 类型 | 来源 | 协议端口 | 策略 | 备注 |
|---|---|---|---|---|
| 自定义 | `0.0.0.0/0` | `TCP:80` | 允许 | HTTP |
| 自定义 | `0.0.0.0/0` | `TCP:443` | 允许 | HTTPS |

保存后**立即生效**，不用重启实例。

> 三个容易填错的地方：① 填到了「出站规则」；② 来源写成内网段 `172.17.0.0/16`；③ 安全组建了但没**绑定**到这台实例（实例详情页能看到已绑定哪个安全组）。

**B. 轻量应用服务器 Lighthouse**

控制台 → 轻量应用服务器 → **防火墙** → 添加规则，应用类型选 `HTTP(80)`、`HTTPS(443)`。

> 只放行 22 的话，本地 `curl` 通、浏览器一律超时。**这一步不做，后面全白搭。**

### 3.2 系统更新 + 时区

```bash
ssh ubuntu@122.51.145.11
sudo apt update && sudo apt -y upgrade
sudo timedatectl set-timezone Asia/Shanghai
```

### 3.3 关于域名和备案（中国大陆服务器必看）

- **只用 IP 访问**：不需要备案，`http://122.51.145.11` 直接能开。
- **想用域名**：服务器在中国大陆，域名必须完成 **ICP 备案**，否则 80/443 会被拦。备案一般 7~20 个工作日，建议现在就去提交，不耽误先用 IP 开发。
- 域名解析：加一条 `A` 记录指向 `122.51.145.11`，`ping 你的域名` 能出这个 IP 就说明生效了。

---

## 4. 第一步：服务器初始化（3~5 分钟）

先把项目包传到服务器（此时还没建仓库，用 scp 最直接）：

```powershell
# 在 Windows PowerShell 里执行
scp "C:\Users\23878\Documents\deepseek-harness\default-workspace\free-server-site.zip" ubuntu@122.51.145.11:/tmp/
```

然后在服务器上（FinalShell / SSH）执行：

```bash
sudo apt update && sudo apt install -y unzip
cd ~ && unzip -q /tmp/free-server-site.zip
sudo bash ~/free-server-site/deploy/scripts/bootstrap.sh
```

> 如果你已经 push 到 GitHub 了，也可以 `git clone` 后再跑，效果一样。
> ⚠️ 如果 SSH 端口不是 22，先执行 `sudo ufw allow <你的端口>/tcp` 再跑脚本，否则可能把自己关在外面。

脚本做的事（幂等，可重复跑）：

1. `apt` 装 `nginx / rsync / curl / ufw / jq / git`
2. 没有 swap 就建 **2G swap** 并写入 `/etc/fstab`
3. 装 **Node.js 20 LTS**（NodeSource 源）
4. 创建部署用户 `deploy`（不是 root，最小权限）
5. 建目录 `/var/www/site`、`/opt/site/backend/dist`，属主给 `deploy`，并放一个占位首页
6. 写 **systemd 服务 `site-api`**：`Restart=always`、只监听 `127.0.0.1:3000`、日志进 journald
7. 给 `deploy` 配 **最小 sudo 白名单**：只允许重启/查看 `site-api`，别的干不了
8. 写 **Nginx 站点**：`/` 静态、`/api/` 反代、gzip、静态资源长缓存、禁用 `default` 站点
9. `ufw` 放行 22/80/443

跑完会打印类似：

```
systemd 服务  : site-api
部署用户      : deploy
后端端口      : 127.0.0.1:3000   (仅本机，不对外暴露)
```

此时访问 `http://122.51.145.11` 应该看到「**环境已就绪，等待第一次 GitHub Actions 发布…**」——说明 Nginx 已经在正常工作。

<details>
<summary>可选：改应用名/端口（默认 <code>site</code> / <code>3000</code>）</summary>

```bash
sudo APP_NAME=mysite API_PORT=8080 bash bootstrap.sh
```
改完记得同步改 `.github/workflows/deploy.yml` 顶部的 `APP_NAME / REMOTE_WEB / REMOTE_APP`。
</details>

---

## 5. 第二步：生成部署密钥

在**你自己的电脑**上执行（私钥永远不要进仓库、不要贴聊天记录）：

```bash
ssh-keygen -t ed25519 -C "github-actions-site" -f ~/.ssh/site_deploy -N ""
```

把公钥装到服务器（按你的系统选一条）：

```bash
# Linux / macOS：直接拷贝
ssh-copy-id -i ~/.ssh/site_deploy.pub deploy@122.51.145.11
```

```powershell
# Windows PowerShell（没有 ssh-copy-id，用下面这条）
type $env:USERPROFILE\.ssh\site_deploy.pub | ssh deploy@122.51.145.11 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

```bash
# 或者：在服务器上执行（把 pub 文件内容整行粘进去）
sudo bash deploy/scripts/add-deploy-key.sh 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... github-actions-site'
```

验证免密登录（能直接进、不再要密码才算成功）：

```bash
ssh -i ~/.ssh/site_deploy deploy@122.51.145.11 "whoami && ls -ld /var/www/site"
# 期望输出 deploy 和 drwxr-xr-x ... deploy deploy ... /var/www/site
```

---

## 6. 第三步：建仓库、配 4 个 Secrets、再 push

> 顺序很重要：**先建仓库 → 先配 Secrets → 最后 push**。
> 这样第一次 push 触发的发布就能直接成功，不会出现一次「缺少密钥」的红色失败。

### 6.1 在 GitHub 建一个空仓库

网页 → New repository → 填名字 → **不要**勾 "Add a README"（保持空仓库）→ Create。

### 6.2 加 4 个 Secrets

仓库 → **Settings → Secrets and variables → Actions → New repository secret**：

| Name | Value | 说明 |
|---|---|---|
| `SSH_HOST` | `122.51.145.11` | 服务器公网 IP（或已备案域名） |
| `SSH_USER` | `deploy` | 部署用户 |
| `SSH_PORT` | `22` | 可省略，默认 22 |
| `DEPLOY_SSH_KEY` | 私钥**全文** | 含 `-----BEGIN OPENSSH PRIVATE KEY-----` 头尾 |

复制私钥：

```powershell
# Windows
Get-Content $env:USERPROFILE\.ssh\site_deploy -Raw | Set-Clipboard
```
```bash
# Linux / macOS
pbcopy < ~/.ssh/site_deploy        # macOS
xclip -sel clip < ~/.ssh/site_deploy   # Linux（或手动 cat 复制）
```

> ⚠️ 粘贴进 GitHub 输入框时，**结尾不要多一个空行**，开头 `-----BEGIN` 前也不能有空格。

### 6.3 提交并 push

```powershell
cd C:\Users\23878\Documents\deepseek-harness\default-workspace\free-server-site
git init -b main
git add .
git commit -m "init: 前后端分离站点 + GitHub Actions 自动部署"
git remote add origin https://github.com/你的用户名/你的仓库.git
git push -u origin main
```

第一次 push 会弹出 GitHub 登录窗口（Git Credential Manager），浏览器里点一下授权即可。
如果提示要密码：**不能用账号密码**，去 GitHub → Settings → Developer settings → Personal access tokens 生成一个 `repo` 权限的 token 当密码用。

---

## 7. 第四步：触发首次发布并验证

push 后打开仓库 **Actions → Build & Deploy**，会看到两个 job：

```
构建前端 + 打包后端   ✔  约 40~80 秒（npm 有缓存更快）
发布到服务器           ✔  约 10~20 秒
```

`deploy` 里最后一步是**发布后健康检查**，它会真的 `curl` 一次 `/api/health`，所以变绿就代表后端活着，不用再单独验证。

浏览器打开 `http://122.51.145.11`，页面应该显示：

- 徽标 **「服务运行中」**（绿色）
- 「当前线上版本」= 7 位 commit sha
- 「更新校验」= **✓ 已是最新构建**（前端 `version.json` 与后端 `/api/version` 一致）

不放心再手动敲一条：

```bash
curl -s http://122.51.145.11/api/health | jq
curl -s http://122.51.145.11/api/version | jq
```

---

## 8. 日常开发流程

### 本地跑起来（两个终端）

```bash
# 终端 1：后端 :3000
cd backend && npm install && npm run dev

# 终端 2：前端 :5173，/api 自动代理到 :3000
cd frontend && npm install && npm run dev
# 打开 http://localhost:5173
```

### 改完发布

```bash
git add -A && git commit -m "feat: 首页改版" && git push
# Actions 跑完（1~2 分钟）刷新页面即可
```

### 改哪里 = 改什么

| 想改的东西 | 改文件 | 生效方式 |
|---|---|---|
| 页面内容/样式 | `frontend/src/App.vue`、`style.css` | push |
| 新接口 | `backend/src/server.js` 里加 `app.get('/api/xxx')` | push |
| 新页面 + 路由 | 装 `vue-router`，Nginx 已配好 `try_files ... /index.html` 回退 | push |
| 端口/应用名 | `deploy.yml` 顶部 env + 服务器 `bootstrap.sh` 参数 | 重跑 bootstrap |
| Nginx 规则 | 服务器 `/etc/nginx/sites-available/site.conf` → `nginx -t && systemctl reload nginx` | 即时 |

---

## 9. 域名 + HTTPS（拿到备案后）

```bash
# 1) 改 server_name
sudo sed -i 's/server_name .*/server_name example.com www.example.com;/' /etc/nginx/sites-available/site.conf
sudo nginx -t && sudo systemctl reload nginx

# 2) 签证书（自动续期由 certbot.timer 负责）
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d example.com -d www.example.com

# 3) 验证自动续期
sudo certbot renew --dry-run
```

certbot 会自己改写 443 配置并加 80→443 跳转。之后把 GitHub Secret `SSH_HOST` 改成域名即可。

---

## 10. 常用运维命令

```bash
# 服务状态 / 实时日志
sudo systemctl status site-api
sudo journalctl -u site-api -f

# 重启后端（改环境变量后必须重启）
sudo systemctl restart site-api

# Nginx
sudo nginx -t && sudo systemctl reload nginx
sudo tail -f /var/log/nginx/error.log

# 资源
free -h && swapon --show        # 看 swap 是否生效
df -h /                          # 看磁盘
htop

# 手动回滚到上一个 commit（服务器上无 git 历史，用 GitHub 的 Re-run 或本地 revert 再 push）
git revert <bad-commit> && git push
```

---

## 11. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 浏览器打不开，`curl` 也超时 | 安全组没放行 80 | 云控制台加 80/443 规则 |
| **502 Bad Gateway** | 后端没起 / 崩了 | `journalctl -u site-api -n 50`，多半是 `server.cjs` 不存在或端口不一致 |
| **403 Forbidden** | `/var/www/site` 属主不对或缺 `index.html` | `sudo chown -R deploy:deploy /var/www/site` |
| bootstrap 报 `duplicate default server for 0.0.0.0:80` | Ubuntu 自带的 `default` 站点没被真正禁用（nginx 是 `include sites-enabled/*` 通配加载，改名成 `.bak` 照样加载） | `sudo rm -f /etc/nginx/sites-enabled/default && sudo nginx -t && sudo systemctl reload nginx`；新版脚本已修正 |
| 首页正常，`/api/*` 404 | Nginx 没 reload，或请求打到了静态 root | `nginx -t && systemctl reload nginx`；确认 `location /api/` 在 `location /` 之前且带 `proxy_pass` |
| 页面还是旧版 | 浏览器缓存 `/index.html` | `Ctrl+Shift+R`；本项目对 `assets/` 长缓存、`index.html` 不缓存，正常不会遇到 |
| Actions 卡在 SSH 连接 | 22 端口被封 / 密钥不对 | 本地先 `ssh -i` 试通；看 Actions 日志里 `ssh-keyscan` 输出 |
| `sudo: a password is required` | sudoers 没生成或路径不匹配 | `sudo visudo -c`；`cat /etc/sudoers.d/site-api-deploy` |
| 脚本报 `/bin/bash^M: bad interpreter` | Windows 把换行转成了 CRLF | 仓库已带 `.gitattributes`；若仍出现就 `git config core.autocrlf input` 后重新 clone，或 `sed -i 's/\r$//' 脚本.sh` |
| bootstrap 卡在装 Node，日志有 `Unsupported distribution` | NodeSource 还没支持你刚出的新系统（如 Ubuntu 25.10/26.04） | 脚本会自动回退到官方二进制包，看到 `改用官方二进制包` 是正常的；也可手动指定 `sudo NODE_DIST_VER=20.19.5 bash bootstrap.sh` |
| Actions 报 `Host key verification failed` | 服务器重装过，指纹变了 | 删掉 Actions 里的旧指纹：重跑即可（每次都会 `ssh-keyscan` 覆盖追加），或本地 `ssh-keygen -R 122.51.145.11` |
| 发布成功但页面 404 | `rsync --delete` 时 `index.html` 没传上去 | 本地 `ls frontend/dist` 确认有 `index.html`；再 `ls -l /var/www/site` |
| `rsync: mkstemp ... Permission denied` | 目录属主不是 `deploy` | `sudo chown -R deploy:deploy /var/www/site /opt/site` |
| Node 被 Killed（日志 `signal: killed`） | 内存不够，swap 没生效 | `swapon --show`；没生效就重跑 bootstrap |
| 服务器上 `npm` 极慢 | npm 官方源在国内慢 | `npm config set registry https://registry.npmmirror.com`（本项目 CI 在境外跑，只有方案 B 会用到） |

---

## 12. 备选方案 B：服务器主动拉取

如果 GitHub Actions 连你的机器不稳定，可以让**服务器定时 `git pull` 自己更新**，完全不需要向外暴露 SSH：

```bash
# 1) 下载脚本装进 PATH（服务器上，root）
sudo curl -fsSL -o /usr/local/bin/site-pull-deploy \
  https://raw.githubusercontent.com/你的用户名/你的仓库/main/deploy/scripts/server-pull-deploy.sh
sudo chmod 755 /usr/local/bin/site-pull-deploy

# 2) 私有仓库才需要：给 deploy 生成只读 Deploy Key
sudo -u deploy ssh-keygen -t ed25519 -f /home/deploy/.ssh/github -N ""
sudo cat /home/deploy/.ssh/github.pub
#   → 把它加到 GitHub 仓库 Settings → Deploy keys（不要勾 Allow write access）
sudo -u deploy ssh -o StrictHostKeyChecking=accept-new -T git@github.com
#   → 看到 "Hi 你的用户名/仓库! You've successfully authenticated" 即成功

# 3) 手动跑一次（首次会 clone 到 /opt/site/src）
sudo -u deploy REPO_URL=git@github.com:你的用户名/你的仓库.git bash /usr/local/bin/site-pull-deploy

# 4) 挂 cron，每 5 分钟检查一次
echo '*/5 * * * * deploy REPO_URL=git@github.com:你的用户名/你的仓库.git /usr/local/bin/site-pull-deploy >> /var/log/site-pull-deploy.log 2>&1' \
  | sudo tee /etc/cron.d/site-pull-deploy
sudo chmod 644 /etc/cron.d/site-pull-deploy
```

两种方案**不要同时开**，否则会互相覆盖。区别：

| | 方案 A（本文默认） | 方案 B |
|---|---|---|
| 构建位置 | GitHub 机器 | 服务器（吃 swap，1~2 分钟） |
| 首次生效 | 秒级 | 最多 5 分钟（cron 周期） |
| 需要 Secrets | 需要私钥 | 不需要 |
| 适合 | 正常情况 | 网络受限 / 不想配密钥 |

---

## 13. 后续可以加什么

按性价比排序，都适合 1.9G 的机器：

1. **数据库**：SQLite（零运维，先跑起来）→ 数据量上来再换 PostgreSQL（加 512M swap 后可跑）。
2. **原子发布**：现在 `rsync --delete` 直接覆盖 `/var/www/site`，发布瞬间可能有几百毫秒 404。进阶做法是 `releases/<sha>/` + 软链 `current` 原子切换，配合 Actions 里多传一个 release 目录。
3. **监控**：加一个 `/api/health` 外部拨测（UptimeRobot 免费版），挂了能收到通知。
4. **备份**：`/etc/cron.daily` 里加一条 `sqlite3 xxx.db ".backup"`，再 `rclone` 到对象存储。
5. **HTTPS 强制**：certbot 装完后把 80 全量 301 到 443。

---

## 附：本文用到的变量对照

| 变量 | 值 | 出现位置 |
|---|---|---|
| `APP_NAME` | `site` | `deploy.yml` env、`bootstrap.sh` |
| `WEB_DIR` | `/var/www/site` | Nginx `root` |
| `REPO_DIR` | `/opt/site` | systemd `WorkingDirectory` 的上级 |
| `API_PORT` | `3000` | systemd `PORT`、Nginx `proxy_pass` |
| `SERVICE` | `site-api` | `systemctl` 命令 |
| `DEPLOY_USER` | `deploy` | rsync / systemd `User` |
