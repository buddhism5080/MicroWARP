# ==========================================
# 阶段 1：编译 hev-socks5-server（C，TCP+UDP ASSOCIATE）
# ==========================================
ARG ALPINE_IMAGE=alpine:latest
FROM ${ALPINE_IMAGE} AS builder
RUN apk add --no-cache build-base git linux-headers
# 静态链接，避免运行时再带一份 musl 动态依赖
RUN git clone --recursive --depth 1 https://github.com/heiher/hev-socks5-server.git /src && \
    make -C /src -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" ENABLE_STATIC=1

# ==========================================
# 阶段 2：极净运行环境
# ==========================================
FROM ${ALPINE_IMAGE}
ENV TZ=Asia/Shanghai

# 仅安装必要的内核级 WireGuard、网络控制与单容器多实例 LB 工具
# haproxy: 统一 SOCKS 入口 + 仅转发健康实例
# iproute2: netns / veth（多实例隔离）
# openssl: admin HTTP HMAC
RUN apk add --no-cache wireguard-tools iptables iproute2 curl tzdata haproxy socat openssl && \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && \
    echo "${TZ}" > /etc/timezone

COPY --from=builder /src/bin/hev-socks5-server /usr/local/bin/hev-socks5-server

WORKDIR /app
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]
