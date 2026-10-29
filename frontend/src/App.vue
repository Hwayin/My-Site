<script setup>
import { computed, onMounted, ref } from 'vue';

const health = ref(null);
const version = ref(null);
const lastCheck = ref(null);
const checking = ref(false);
const error = ref('');
const latest = ref(null); // 构建产物里的 /version.json，用于对比“是否最新”

async function getJSON(url) {
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
  return res.json();
}

async function refresh() {
  checking.value = true;
  error.value = '';
  try {
    const [h, v, l] = await Promise.all([
      getJSON('/api/health'),
      getJSON('/api/version'),
      getJSON('/version.json').catch(() => null),
    ]);
    health.value = h;
    version.value = v;
    latest.value = l;
    lastCheck.value = new Date();
  } catch (e) {
    error.value = e.message || String(e);
  } finally {
    checking.value = false;
  }
}

onMounted(refresh);

const up = computed(() => health.value?.status === 'ok');
const currentSha = computed(() => version.value?.short || version.value?.sha || '—');
const builtSha = computed(() => latest.value?.short || '—');
const isLatest = computed(() => !!latest.value && latest.value.short === currentSha.value);

function fmt(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? ts : d.toLocaleString('zh-CN', { hour12: false });
}

const uptimeText = computed(() => {
  const s = Number(health.value?.uptime || 0);
  if (!s) return '—';
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  return d ? `${d} 天 ${h} 小时` : h ? `${h} 小时 ${m} 分` : `${m} 分钟`;
});
</script>

<template>
  <main class="wrap">
    <header class="hero">
      <div class="badge" :class="up ? 'ok' : 'bad'">
        <span class="dot"></span>
        {{ up ? '服务运行中' : error ? '后端不可达' : '检测中…' }}
      </div>
      <h1>前后端分离部署已生效</h1>
      <p class="sub">
        Nginx 托管前端静态资源，<code>/api</code> 反向代理到 Node 服务；每次 <code>git push</code>
        由 GitHub Actions 构建并自动发布。
      </p>
      <div class="actions">
        <button class="btn primary" :disabled="checking" @click="refresh">
          {{ checking ? '检测中…' : '重新检测' }}
        </button>
        <span class="muted">上次检测：{{ fmt(lastCheck) }}</span>
      </div>
      <p v-if="error" class="err">接口错误：{{ error }}（若反复出现，查看 <code>journalctl -u site-api -n 50</code>）</p>
    </header>

    <section class="grid">
      <article class="card">
        <h2>当前线上版本</h2>
        <p class="big mono">{{ currentSha }}</p>
        <dl>
          <dt>提交信息</dt>
          <dd>{{ version?.message || '—' }}</dd>
          <dt>分支</dt>
          <dd class="mono">{{ version?.ref || '—' }}</dd>
          <dt>构建时间</dt>
          <dd>{{ fmt(version?.builtAt) }}</dd>
          <dt>发布时间</dt>
          <dd>{{ fmt(version?.deployedAt) }}</dd>
        </dl>
      </article>

      <article class="card">
        <h2>更新校验</h2>
        <p class="big mono">{{ builtSha }}</p>
        <p class="status" :class="isLatest ? 'ok' : 'warn'">
          {{ latest ? (isLatest ? '✓ 已是最新构建' : '⚠ 后端与前端版本不一致，等待发布完成或重启服务') : '静态版本文件 /version.json 未找到' }}
        </p>
        <dl>
          <dt>前端构建</dt>
          <dd class="mono">{{ builtSha }}</dd>
          <dt>后端运行</dt>
          <dd class="mono">{{ currentSha }}</dd>
        </dl>
      </article>

      <article class="card">
        <h2>运行状态</h2>
        <dl>
          <dt>进程启动于</dt>
          <dd>{{ fmt(health?.startedAt) }}</dd>
          <dt>已运行</dt>
          <dd>{{ uptimeText }}</dd>
          <dt>Node</dt>
          <dd class="mono">{{ health?.node || '—' }}</dd>
          <dt>主机</dt>
          <dd class="mono">{{ health?.host || '—' }}</dd>
          <dt>环境</dt>
          <dd class="mono">{{ health?.env || '—' }}</dd>
        </dl>
      </article>
    </section>

    <section class="card next">
      <h2>下一步</h2>
      <ol>
        <li>把本仓库根目录的 <code>README.md</code> 里的步骤走完（GitHub Secrets 配好即可 push 自动发布）。</li>
        <li>有域名的话：先完成 ICP 备案 → 解析 A 记录 → <code>certbot --nginx -d 你的域名</code> 上 HTTPS。</li>
        <li>改这个页面：编辑 <code>frontend/src/App.vue</code>，push 后 1~2 分钟自动生效。</li>
      </ol>
    </section>

    <footer class="foot">
      <span>前后端分离 · Nginx + Node.js · GitHub Actions 持续部署</span>
    </footer>
  </main>
</template>
