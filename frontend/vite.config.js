import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

// 生产环境由 Nginx 同域反向代理 /api，所以前端只需要相对路径请求。
// 本地开发时把 /api 代理到本地后端（npm run dev 同时启动 backend）。
export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:3000',
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
    chunkSizeWarningLimit: 800,
  },
});
