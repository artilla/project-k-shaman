# syntax=docker/dockerfile:1.7
FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS frontend-build

WORKDIR /build/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run typecheck && npm run build

FROM python:3.13-slim-bookworm@sha256:9d7f287598e1a5a978c015ee176d8216435aaf335ed69ac3c38dd1bbb10e8d64 AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    PORT=8000

RUN groupadd --gid 10001 shindang \
    && useradd --uid 10001 --gid shindang --no-create-home --home-dir /app --shell /usr/sbin/nologin shindang

WORKDIR /app
COPY requirements.lock ./
RUN python -m pip install --no-cache-dir --disable-pip-version-check -r requirements.lock

COPY backend/ backend/
COPY fortune-engine/ fortune-engine/
COPY --from=frontend-build /build/frontend/dist/ frontend/dist/

RUN chmod -R a+rX frontend/dist fortune-engine/web/static \
    && mkdir -p state/events state/tts_cache \
    && chown -R shindang:shindang /app/state

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]

CMD ["python", "-m", "uvicorn", "backend.app:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
