import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// ADR-0003: same-origin 유지 — dev에서는 /api·/audio·/static을 backend(8788)로 프록시,
// prod에서는 backend가 dist를 직접 서빙한다 (쿠키 SameSite=Lax·CORS 회피).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:8788",
      "/audio": "http://127.0.0.1:8788",
      "/static": "http://127.0.0.1:8788",
    },
  },
});
