#!/bin/bash
# ================================
# 脚本名称: openclaw.sh
# 脚本路径: ~/openclaw-docker/openclaw.sh
# 脚本描述: 一键部署openclaw
# 脚本作者: szb
# 脚本版本: 1.0
# 脚本时间: 2025-12-10 10:00:00
# 脚本备注: 
# ================================

# 开启错误退出模式
set -euo pipefail

# 默认配置
WORKSPACE_DIR="$HOME/openclaw-docker"
SOFTWARE_LIST=(
    "ca-certificates"
    "curl"
    "sudo"
    "ufw"
    "lsof"
    "wget"
    "jq"
)

# =========== 基础函数 ============
# 获取本机 IP
get_local_ip() {
    # 尝试多种方式获取 IP
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || \
               ip route get 1 2>/dev/null | awk '{print $7}' || \
               ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1 || \
               echo "localhost")
    echo "$LOCAL_IP"
}
# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}
# 生成随机 Token
generate_token() {
    if check_command openssl; then
        openssl rand -hex 16
    elif check_command tr; then
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32
    else
        echo "openclaw-$(date +%s)"
    fi
}
# 检查 Docker
check_docker() {
    if ! check_command docker; then
        echo -e "未检测到 Docker!"
        echo ""
        echo -e "请先安装 Docker"
        echo "  官网: https://docs.docker.com/get-docker/"
        echo ""
        exit 1
    fi
    
    # 检查 Docker 是否运行
    if ! docker info &> /dev/null; then
        echo -e "Docker 未运行"
        echo ""
        echo -e "请启动 Docker 服务后重试"
        exit 1
    fi
}

# ================================
# 检查系统软件包,不存在则安装
check_system_packages() {
    # 一次性获取已安装的包列表
    local installed_list
    installed_list=$(apt list --installed 2>/dev/null)

    # 检查是否存在缺失的包
    local missing_pkgs=()
    for pkg in "${SOFTWARE_LIST[@]}"; do
        if ! grep -q "^${pkg}/" <<< "$installed_list"; then
            missing_pkgs+=("$pkg")
        fi
    done

    # 如果有缺失的包，则安装它们
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        apt install -y "${missing_pkgs[@]}"
    fi
}

# 检查此目录下的docker compose是否运行,如果运行则停止
check_folder_docker_compose() {
    if [ -f "$WORKSPACE_DIR/docker-compose.yml" ]; then
        if docker-compose -f "$WORKSPACE_DIR/docker-compose.yml" ps &> /dev/null; then
            docker-compose -f "$WORKSPACE_DIR/docker-compose.yml" down
        fi
    fi
}

# 创建目录结构
create_folder() {
    # 检查文件夹是否存在,存在则删除,不存在则创建
    if [ -d "$WORKSPACE_DIR" ]; then
        rm -rf "$WORKSPACE_DIR"
    fi
    mkdir -p "$WORKSPACE_DIR"/{data,workspace,caddy_config,caddy_data,caddy_logs}
}

# 写入配置文件
write_config_file() {
    LOCAL_IP=$(get_local_ip)

    # 创建caddy配置文件
    cat > "$WORKSPACE_DIR/caddyfile" << 'EOF'
# HTTP 重定向到 HTTPS
:80 {
    redir https://{host}{uri}
}

# 虚拟域名
openclaw.local {
    # 使用内置私有 CA(internal CA)签发证书
    tls internal

    # 反向代理到 OpenClaw 容器,Caddy 在同一个 Compose 网络中可以直接通过服务名访问
    reverse_proxy openclaw-gateway:18789

    # 配置 Caddy 日志
    log {
        output file /var/log/caddy/access.log {
            roll_size 10mb
            roll_keep 3
        }
    }
}
EOF

    # 创建openclaw配置文件
    cat > "$WORKSPACE_DIR/data/openclaw.json" << EOF
{
    "gateway": {
        "bind": "lan",
        "trustedProxies": [
            "172.18.0.0/16"
        ],
        "controlUi": {
            "allowInsecureAuth": true,
            "dangerouslyDisableDeviceAuth": true,
            "dangerouslyAllowHostHeaderOriginFallback": true,
            "allowedOrigins": [
                "http://localhost:18789",
                "http://127.0.0.1:18789",
                "http://${LOCAL_IP}",
                "https://${LOCAL_IP}"
            ]
        }
    }
}

EOF

    # 创建.env文件
    cat > "$WORKSPACE_DIR/.env" << EOF
# =========================
# OpenClaw 基础
# =========================
NODE_ENV=production

# Gateway 认证 Token
OPENCLAW_GATEWAY_TOKEN=$(generate_token)

# 日志等级
OPENCLAW_LOG_LEVEL=info

# =========================
# Shell 环境导入
# =========================
OPENCLAW_LOAD_SHELL_ENV=1
OPENCLAW_SHELL_ENV_TIMEOUT_MS=15000

# =========================
# 路径
# =========================
OPENCLAW_HOME=/home/node/.openclaw
OPENCLAW_STATE_DIR=/home/node/.openclaw

# =========================
# 时区
# =========================
TZ=Asia/Shanghai
EOF

    # 创建docker-compose.yml文件
    cat > "$WORKSPACE_DIR/docker-compose.yml" << EOF
# 定义通用的日志配置模板，避免重复编写
x-logging: &default-logging
  logging:
    driver: "json-file"
    options:
      max-size: "10m"   # 每个日志文件最大 10MB
      max-file: "3"     # 最多保留 3 个日志文件（旧的会被自动清理）

services:
  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: openclaw-gateway
    restart: unless-stopped
    expose:
      - "18789"
    volumes:
      - $WORKSPACE_DIR/data:/home/node/.openclaw
      - $WORKSPACE_DIR/workspace:/home/node/.openclaw/workspace
    env_file:
      - .env
    environment:
      - NODE_ENV=production
      # 网关安全校验降级
      #- GATEWAY_CONTROLUI_ALLOWINSECUREAUTH=true
      # 跳过访问来源验证
      #- GATEWAY_CONTROLUI_SKIPORIGINCHECK=true
      # 跳过设备校验
      #- GATEWAY_CONTROLUI_SKIPDEVICECHECK=true
      # OpenClaw 网关的环境配置变量
      - OPENCLAW_GATEWAY_BIND=lan
    # --- 健康检查 ---
    healthcheck:
      test: [
          "CMD",
          "node",
          "-e",
          "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))",
        ] # OpenClaw 开放的监控端口
      interval: 30s   # 每 10 秒检查一次
      timeout: 5s     # 超时时间
      retries: 5      # 重试 3 次失败才算不健康
      start_period: 20s # 容器启动后的前 10 秒即使失败也不计入重试
    # --- 硬件资源限制 ---
    mem_limit: 2g
    cpus: 2
    # --- 日志限制 ---
    <<: *default-logging

  openclaw-cli:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: openclaw-cli
    network_mode: "service:openclaw-gateway"
    volumes:
      - $WORKSPACE_DIR/data:/home/node/.openclaw
      - $WORKSPACE_DIR/workspace:/home/node/.openclaw/workspace
    stdin_open: true
    tty: true
    init: true
    profiles:
      - tools
    # --- 日志限制 ---
    <<: *default-logging

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - $WORKSPACE_DIR/caddyfile:/etc/caddy/Caddyfile
      - $WORKSPACE_DIR/caddy_data:/data
      - $WORKSPACE_DIR/caddy_config:/config
      # 映射 Caddy 自身的访问日志目录
      - $WORKSPACE_DIR/caddy_logs:/var/log/caddy
    # --- 依赖关系：必须等 openclaw-gateway 处于 healthy (健康) 状态才启动 ---
    depends_on:
      openclaw-gateway:
        condition: service_healthy
    # --- 硬件资源限制 ---
    mem_limit: 512m
    cpus: 0.5
    # --- 日志限制 ---
    <<: *default-logging
EOF

}

# 如果是root用户,创建的文件和文件夹需要修改用户和用户组,权限
is_permissions() {
    if [ "$(id -u)" -eq 0 ]; then
        chown -R 1000:1000 "$WORKSPACE_DIR/data" "$WORKSPACE_DIR/workspace" "$WORKSPACE_DIR/caddy_config" "$WORKSPACE_DIR/caddy_data" "$WORKSPACE_DIR/caddy_logs"
        chmod -R 755 "$WORKSPACE_DIR/data" "$WORKSPACE_DIR/workspace" "$WORKSPACE_DIR/caddy_config" "$WORKSPACE_DIR/caddy_data" "$WORKSPACE_DIR/caddy_logs"
    fi
}


main() {
    # 检查并安装系统依赖
    check_system_packages

    # 检查容器
    check_docker

    # 检查docker compose 是否运行,如果运行则停止
    check_folder_docker_compose

    # 创建必备文件夹
    create_folder

    # 写入配置文件
    write_config_file

    # 检查配置文件权限
    is_permissions

    # 
    echo "准备完成, 请运行"
    echo "docker compose run --rm --entrypoint node openclaw-gateway dist/index.js onboard --mode local --no-install-daemon"
    echo "完成OpenClaw初始化"
    echo "请运行"
    echo "docker compose up -d"
    echo "启动OpenClaw"

    echo "注意: 宿主机需要配置虚拟域名"

    echo "apt install ca-certificates curl sudo ufw"
}

# 仅在直接执行时运行 main，被 source 时不执行（用于测试）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi