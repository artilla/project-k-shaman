# syntax=docker/dockerfile:1.7
FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS frontend-build

WORKDIR /build/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run typecheck && npm run build

FROM python:3.13-slim-bookworm@sha256:9d7f287598e1a5a978c015ee176d8216435aaf335ed69ac3c38dd1bbb10e8d64 AS python-build

WORKDIR /build
COPY requirements-build.lock ./
RUN python -m pip install --no-cache-dir --disable-pip-version-check \
    --require-hashes -r requirements-build.lock
COPY pyproject.toml README.md ./
COPY src/ src/
RUN python -m pip wheel --no-cache-dir --disable-pip-version-check \
    --no-deps --no-build-isolation --wheel-dir /wheels .

FROM python:3.13-slim-bookworm@sha256:9d7f287598e1a5a978c015ee176d8216435aaf335ed69ac3c38dd1bbb10e8d64 AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

RUN groupadd --gid 10001 shindang \
    && useradd --uid 10001 --gid shindang --no-create-home --home-dir /app --shell /usr/sbin/nologin shindang

WORKDIR /app
COPY requirements.lock ./
RUN python -m pip install --no-cache-dir --disable-pip-version-check \
    --require-hashes -r requirements.lock
COPY --from=python-build /wheels/shindang-*.whl /tmp/
RUN python -m pip install --no-cache-dir --disable-pip-version-check \
    --no-deps /tmp/shindang-*.whl \
    && rm -f /tmp/shindang-*.whl
COPY --from=frontend-build /build/frontend/dist/ frontend/dist/

RUN chmod -R a+rX frontend/dist \
    && mkdir -p state/events state/tts_cache \
    && chown -R shindang:shindang /app/state

USER 10001:10001
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"]

CMD ["python", "-m", "uvicorn", "shindang.web.app:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
