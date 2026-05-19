FROM python:3.11-slim

LABEL maintainer="Hermes Agent Community"
LABEL version="0.10.0"
LABEL description="Hermes Agent v0.10.0 with Web UI on Hugging Face Spaces"

# ==================== 环境变量 ====================
ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive
ENV HERMES_HOME=/data/.hermes
ENV PYTHONPATH=/app

# BFF Server 环境变量（构建阶段）
ENV PORT=7860
ENV UPSTREAM=http://127.0.0.1:8642
ENV HERMES_BIN=/usr/local/bin/hermes
# 注意：NODE_ENV=production 不能在此设置！
# npm install 在 NODE_ENV=production 时会跳过 devDependencies，
# 导致 vue-tsc 等构建工具缺失。NODE_ENV 在运行时阶段再设置。

# ==================== 系统依赖 + Node.js 23 + Bun + yq ====================
# 合并为一层，减少镜像体积和构建时间
RUN apt-get update && apt-get install -y --no-install-recommends     build-essential     ffmpeg     git     curl     unzip     ca-certificates     && curl -fsSL https://deb.nodesource.com/setup_23.x | bash -     && apt-get install -y nodejs     && node --version     && npm --version     && curl -fsSL https://bun.sh/install | bash     && cp /root/.bun/bin/bun /usr/local/bin/bun     && chmod +x /usr/local/bin/bun     && bun --version     && curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/bin/yq     && chmod +x /usr/bin/yq     && apt-get clean     && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# bun 必须在运行时 PATH 中可用（agent 子进程通过 bun 调用 baoyu-skills）
# /usr/local/bin 已在默认 PATH 中，所有用户均可访问

# ==================== baoyu-skills 脚本预置 ====================
# 将完整的 baoyu-imagine 脚本预置到 ~/.baoyu-skills/ 目录
# 此目录是 main.ts loadExtendConfig() 的查找路径之一
# 避免依赖 Web UI 技能安装（可能只下载编译产物而丢失 .ts 源文件）
RUN mkdir -p /home/appuser/.baoyu-skills/baoyu-imagine &&     git clone --depth 1 https://github.com/JimLiu/baoyu-skills.git /tmp/baoyu-skills &&     cp -r /tmp/baoyu-skills/skills/baoyu-imagine/scripts           /home/appuser/.baoyu-skills/baoyu-imagine/scripts &&     rm -rf /tmp/baoyu-skills

# ==================== Python 依赖 ====================
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm -f /tmp/requirements.txt

# ==================== Hermes Agent ====================
# 克隆并安装 Hermes Agent（不再构建内置 Dashboard 前端，由 hermes-web-ui 替代）
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /tmp/hermes-agent &&     pip install --no-cache-dir /tmp/hermes-agent[all] &&     rm -rf /tmp/hermes-agent /root/.cache/pip

# Playwright 浏览器（Hermes Agent 工具调用需要）
RUN npx playwright install chromium --with-deps --only-shell &&     apt-get clean &&     rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache

# ==================== Hermes Web UI ====================
# 克隆、构建、精简 hermes-web-ui（单层，避免中间态占用空间）
RUN git clone --depth 1 https://github.com/EKKOLearnAI/hermes-web-ui.git /tmp/hermes-web-ui &&     cd /tmp/hermes-web-ui &&     npm pkg delete scripts.prepare &&     npm install &&     npm run build &&     npm prune --omit=dev &&     mkdir -p /opt/hermes-web-ui &&     cp -r dist node_modules package.json /opt/hermes-web-ui/ &&     cd / &&     rm -rf /tmp/hermes-web-ui /root/.npm /root/.cache /tmp/*

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

# ==================== 运行时环境变量 ====================
# 构建阶段不设 NODE_ENV=production（会导致 npm install 跳过 devDependencies）
# 此处设置，仅影响运行时行为
ENV NODE_ENV=production

# 7860: BFF Server (Web UI 入口，HF Spaces 要求)
# 8642: Gateway API Server (BFF 的上游代理目标，仅容器内部)
EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3     CMD curl -f http://localhost:7860/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
