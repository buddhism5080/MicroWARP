# ==========================================
# 阶段 0：编译外层 SOCKS gate（可选 L7 惩罚）
# ==========================================
ARG GO_IMAGE=golang:1.22-alpine
ARG ALPINE_IMAGE=alpine:latest
FROM ${GO_IMAGE} AS gatebuilder
WORKDIR /src
COPY gate/ ./
RUN CGO_ENABLED=0 go test ./... \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /mw-gate .

# ==========================================
# 阶段 1：极速编译 MicroSOCKS 引擎
# ==========================================
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

# 仅安装必要的内核级 WireGuard、网络控制与单容器多实例 LB 工具
# haproxy: 统一 SOCKS 入口 + 仅转发健康实例
# iproute2: netns / veth（多实例隔离）
RUN apk add --no-cache wireguard-tools iptables iproute2 curl tzdata haproxy && \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && \
    echo "${TZ}" > /etc/timezone

# 打包 microsocks + mw-gate
COPY --from=builder /src/microsocks /usr/local/bin/microsocks
COPY --from=gatebuilder /mw-gate /usr/local/bin/mw-gate

WORKDIR /app
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# 启动引擎
CMD ["./entrypoint.sh"]
