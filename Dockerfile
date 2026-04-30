# ==========================================
# 阶段 1：极速编译 MicroSOCKS 引擎
# ==========================================
ARG ALPINE_IMAGE=alpine:latest
FROM ${ALPINE_IMAGE} AS builder
# 安装 C 语言编译环境
RUN apk add --no-cache build-base git
# 从官方仓库拉取源码并编译 (只需 2 秒)
RUN git clone https://github.com/rofl0r/microsocks.git /src && \
    cd /src && make

# ==========================================
# 阶段 2：极净运行环境
# ==========================================
FROM ${ALPINE_IMAGE}
ENV TZ=Asia/Shanghai

# 仅安装必要的内核级 WireGuard 和网络控制工具
RUN apk add --no-cache wireguard-tools iptables iproute2 curl tzdata && \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && \
    echo "${TZ}" > /etc/timezone

# 打包microsocks
COPY --from=builder /src/microsocks /usr/local/bin/microsocks

WORKDIR /app
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]
