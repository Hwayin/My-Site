import express from 'express';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const PORT = Number(process.env.PORT || 3000);
const ENV = process.env.NODE_ENV || 'development';
const APP_NAME = process.env.APP_NAME || 'site';

// 部署时 GitHub Actions 会把 VERSION 文件放到应用根目录
// 生产环境由 systemd 通过 VERSION_FILE 环境变量传入绝对路径
const VERSION_FILE = process.env.VERSION_FILE || path.resolve(process.cwd(), '..', 'VERSION');

const STARTED_AT = new Date();

function readVersion() {
  try {
    const raw = fs.readFileSync(VERSION_FILE, 'utf8');
    return JSON.parse(raw);
  } catch {
    return {
      sha: 'dev',
      short: 'dev',
      ref: 'local',
      message: '本地开发环境，未通过 CI 构建',
      builtAt: null,
      deployedAt: null,
    };
  }
}

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 1);

app.use(express.json({ limit: '1mb' }));

// 健康检查：供 Nginx / 监控 / CI 发布后探测
app.get('/api/health', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({
    status: 'ok',
    app: APP_NAME,
    env: ENV,
    host: os.hostname(),
    node: process.version,
    pid: process.pid,
    startedAt: STARTED_AT.toISOString(),
    uptime: Math.round(process.uptime()),
    now: new Date().toISOString(),
  });
});

// 版本信息：前端用来显示线上版本、比对是否更新到了最新构建
app.get('/api/version', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({ app: APP_NAME, ...readVersion() });
});

// 一个可替换的示例业务接口
app.get('/api/hello', (req, res) => {
  const name = String(req.query.name || '访客').slice(0, 40);
  res.json({ message: `你好，${name}！接口由 Node 提供，页面由 Nginx 提供。` });
});

app.use('/api', (req, res) => {
  res.status(404).json({ error: 'not_found', path: req.originalUrl });
});

// 所有未匹配的路径交回前端（Nginx 已经处理，这里只兜底）
app.use((req, res) => {
  res.status(404).type('text/plain').send('Not Found');
});

// 生产环境打印到 journald，便于 journalctl -u 查看
app.use((err, req, res, next) => {
  console.error('[error]', err);
  if (res.headersSent) return next(err);
  res.status(500).json({ error: 'internal_error' });
});

const server = app.listen(PORT, '127.0.0.1', () => {
  const v = readVersion();
  console.log(`[${APP_NAME}] API listening on 127.0.0.1:${PORT} (env=${ENV}, version=${v.short})`);
});

function shutdown(signal) {
  console.log(`[${APP_NAME}] received ${signal}, shutting down...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 8000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
