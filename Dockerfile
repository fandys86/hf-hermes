# ==================== Stage 1: Build Web UI ====================
# 单独构建前端，避免 node_modules 和构建工具污染最终镜像
FROM node:23-slim AS ui-builder

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates     && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN git clone --depth 1 https://github.com/EKKOLearnAI/hermes-web-ui.git /tmp/ui &&     cd /tmp/ui &&     npm pkg delete scripts.prepare &&     npm install &&     npm run build &&     npm prune --omit=dev &&     mkdir -p /opt/hermes-web-ui &&     cp -r dist node_modules package.json /opt/hermes-web-ui/ &&     cd / && rm -rf /tmp/ui /root/.npm /root/.cache /tmp/* /var/tmp/*

# ==================== Stage 2: Runtime ====================
FROM python:3.11-slim

LABEL maintainer="Hermes Agent Community"
LABEL version="0.10.0"
LABEL description="Hermes Agent v0.10.0 with Web UI on Hugging Face Spaces"

ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive
ENV HERMES_HOME=/data/.hermes
ENV PYTHONPATH=/app
ENV PORT=7860
ENV UPSTREAM=http://127.0.0.1:8642
ENV HERMES_BIN=/usr/local/bin/hermes

# ==================== 系统依赖 + bash ====================
# bash: NodeSource 脚本需要；ca-certificates: HTTPS 下载需要
RUN apt-get update && apt-get install -y --no-install-recommends     build-essential     ffmpeg     git     curl     unzip     ca-certificates     bash     && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ==================== Node.js 23 (NodeSource) ====================
# 使用 NodeSource 官方源，比手动下载 tar.gz 更稳定
RUN curl -fsSL --retry 3 --retry-delay 2 https://deb.nodesource.com/setup_23.x | bash - &&     apt-get install -y nodejs &&     node --version &&     npm --version &&     apt-get clean &&     rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ==================== Bun Runtime ====================
RUN curl -fsSL --retry 3 --retry-delay 2 https://bun.sh/install | bash &&     cp /root/.bun/bin/bun /usr/local/bin/bun &&     chmod +x /usr/local/bin/bun &&     bun --version &&     rm -rf /root/.bun /tmp/* /var/tmp/*

# ==================== yq ====================
RUN curl -fsSL --retry 3 --retry-delay 2     -o /usr/bin/yq     https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 &&     chmod +x /usr/bin/yq

# ==================== baoyu-skills 脚本预置 ====================
RUN mkdir -p /home/appuser/.baoyu-skills/baoyu-imagine &&     git clone --depth 1 https://github.com/JimLiu/baoyu-skills.git /tmp/baoyu-skills &&     cp -r /tmp/baoyu-skills/skills/baoyu-imagine/scripts           /home/appuser/.baoyu-skills/baoyu-imagine/scripts &&     rm -rf /tmp/baoyu-skills

# ==================== Python 依赖 ====================
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt &&     rm -f /tmp/requirements.txt

# ==================== Hermes Agent ====================
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /tmp/hermes-agent &&     pip install --no-cache-dir /tmp/hermes-agent[all] &&     rm -rf /tmp/hermes-agent /root/.cache/pip

# ==================== Playwright 浏览器 ====================
# 安装后立刻清理 apt 缓存，减少镜像体积
RUN npx playwright install chromium --with-deps --only-shell &&     apt-get clean &&     rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache

# ==================== 复制 Web UI 构建产物 ====================
COPY --from=ui-builder /opt/hermes-web-ui /opt/hermes-web-ui

# ==================== 应用代码 ====================
WORKDIR /app

COPY src/ /app/src/
COPY entrypoint.sh /app/
COPY image-proxy.js /app/
COPY image-gen-siliconflow.ts /app/
COPY config/config.yaml /data/.hermes/config.yaml

# 创建数据目录
RUN mkdir -p /data/.hermes /data/.hermes-web-ui /app/logs /home/appuser/.hermes-web-ui/logs &&     chmod +x /app/entrypoint.sh

# 设置非 root 用户（Hugging Face Spaces 要求）
RUN useradd -m -u 1000 appuser &&     ln -sf /data/.hermes /home/appuser/.hermes &&     mkdir -p /home/appuser/.cache &&     chown -R appuser:appuser /data /opt/hermes-web-ui /app /home/appuser

USER appuser

# 运行时环境变量
ENV NODE_ENV=production

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3     CMD curl -f http://localhost:7860/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
