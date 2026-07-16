import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// ADR-0003: same-origin 유지 — dev에서는 API와 오디오만 backend(8788)로 프록시한다.
// /static은 frontend/public의 단일 원본을 Vite가 직접 서빙하고, prod에서는 dist에 포함된다.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:8788",
      "/audio": "http://127.0.0.1:8788",
    },
  },
});
