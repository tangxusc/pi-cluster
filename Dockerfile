ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

ARG PI_VERSION=0.85.1

# pi 的 bash 工具会用到 git / rg 等常用命令，缺了会频繁报错
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep jq less procps \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @earendil-works/pi-coding-agent@${PI_VERSION} \
 && npm cache clean --force

ENV HOME=/root \
    PI_CODING_AGENT_DIR=/root/.pi/agent \
    PI_TELEMETRY=0

# 卷挂在 /root/.pi 上会覆盖镜像里同路径内容，这里只保证 agent 子目录存在
RUN mkdir -p /root/.pi/agent

WORKDIR /workspace

# 容器常驻，交互通过 docker exec -it <container> pi 进入
CMD ["sleep", "infinity"]
