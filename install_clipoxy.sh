#!/bin/bash
set -euo pipefail

echo "========================================="
echo "   CLIProxyAPIPlus 完整管理工具 v2.1"
echo "   1. 安装 / 重新安装"
echo "   2. 修改域名"
echo "   3. 完全卸载"
echo "========================================="

read -p "请选择操作 (1/2/3): " CHOICE

PROJECT_DIR="$HOME/ai-infra/CLIProxyAPIPlus"

cleanup_full() {
    echo "🗑️  彻底清理所有文件和数据..."
    systemctl --user stop cliproxyapi 2>/dev/null || true
    systemctl --user disable cliproxyapi 2>/dev/null || true
    rm -f ~/.config/systemd/user/cliproxyapi.service
    rm -rf "$PROJECT_DIR"
    sudo rm -f /etc/nginx/sites-enabled/reverse-proxy
    sudo rm -f /etc/nginx/sites-available/reverse-proxy
    sudo certbot delete --cert-name "*" --non-interactive 2>/dev/null || true
    sudo systemctl restart nginx 2>/dev/null || true
}

cleanup_keep_data() {
    echo "🛡️  卸载服务，但保留用户数据..."
    systemctl --user stop cliproxyapi 2>/dev/null || true
    systemctl --user disable cliproxyapi 2>/dev/null || true
    rm -f ~/.config/systemd/user/cliproxyapi.service
    sudo rm -f /etc/nginx/sites-enabled/reverse-proxy
    sudo rm -f /etc/nginx/sites-available/reverse-proxy
    sudo certbot delete --cert-name "*" --non-interactive 2>/dev/null || true
    sudo systemctl restart nginx 2>/dev/null || true
}

# ====================== 1. 安装 / 重新安装 ======================
if [ "$CHOICE" = "1" ]; then
    echo "[安装 / 重新安装]"

    if [ -f "$PROJECT_DIR/config.yaml" ]; then
        echo "🔍 检测到旧数据"
        echo "1) 纯净安装（删除所有旧数据）"
        echo "2) 保留数据（复用之前的 config.yaml）"
        read -p "请选择 (1/2): " INSTALL_MODE
    else
        INSTALL_MODE=1
    fi

    read -p "请输入域名 (默认: cpa.studyzy.eu.org): " DOMAIN
    DOMAIN=${DOMAIN:-cpa.studyzy.eu.org}

    read -p "确认继续？(y/n): " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 1

    [ "$INSTALL_MODE" = "1" ] && cleanup_full || cleanup_keep_data

    echo "[1/8] 安装必要工具..."
    sudo apt update && sudo apt install -y curl git wget build-essential ca-certificates upx nginx certbot python3-certbot-nginx

    echo "[2/8] 安装 Go 1.24..."
    cd /tmp
    wget -q https://go.dev/dl/go1.24.1.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf go1.24.1.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /root/.bashrc > /dev/null
    echo 'export GOPATH=/root/go' >> /root/.bashrc
    echo 'export PATH=$PATH:$GOPATH/bin' >> /root/.bashrc
    source /root/.bashrc

    echo "[3/8] 下载/更新项目..."
    mkdir -p ~/ai-infra && cd ~/ai-infra
    if [ -d "CLIProxyAPIPlus" ] && [ "$INSTALL_MODE" = "2" ]; then
        cd CLIProxyAPIPlus && git pull
    else
        rm -rf CLIProxyAPIPlus
        git clone https://github.com/zczy-k/CLIProxyAPIPlus.git
        cd CLIProxyAPIPlus
    fi

    go build -trimpath -ldflags "-s -w" -o cliproxyapi ./cmd/server
    upx --best --lzma cliproxyapi 2>/dev/null || true
    chmod +x cliproxyapi

    echo "[4/8] 处理 config.yaml..."
    if [ "$INSTALL_MODE" = "2" ] && [ -f "config.yaml" ]; then
        echo "保留之前的 config.yaml"
    else
        cp -f config.example.yaml config.yaml 2>/dev/null || true
    fi

    sed -i '/^server:/,/^[^ ]/d' config.yaml 2>/dev/null || true
    cat >> config.yaml << EOF

server:
  host: "0.0.0.0"
  port: 8317
debug: true
EOF

    echo "即将打开 config.yaml 编辑（可配置 OAuth 等）"
    read -p "按 Enter 打开 nano..."
    nano config.yaml

    echo "[5/8] 创建 systemd 服务..."
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/cliproxyapi.service << 'EOL'
[Unit]
Description=CLIProxyAPIPlus Service (Port 8317)
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/ai-infra/CLIProxyAPIPlus
ExecStart=/root/ai-infra/CLIProxyAPIPlus/cliproxyapi --config config.yaml
Restart=always
RestartSec=5
MemoryMax=180M
MemoryHigh=150M
CPUQuota=30%
Nice=15
OOMPolicy=kill
PrivateTmp=true
LimitNOFILE=1024

[Install]
WantedBy=default.target
EOL

    systemctl --user daemon-reload
    systemctl --user enable --now cliproxyapi

    echo "[6/8] 配置 Nginx..."
    sudo tee /etc/nginx/sites-available/reverse-proxy > /dev/null << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:8317;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600;
        proxy_send_timeout 600;
        proxy_buffering off;
        client_max_body_size 50m;
    }
}
EOF

    sudo ln -sf /etc/nginx/sites-available/reverse-proxy /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl restart nginx

    echo "[7/8] 申请 HTTPS 证书..."
    sudo certbot --nginx -d "$DOMAIN"

    echo "🎉 安装完成！访问地址: https://$DOMAIN"

# ====================== 2. 修改域名 ======================
elif [ "$CHOICE" = "2" ]; then
    read -p "请输入新域名: " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && { echo "域名不能为空！"; exit 1; }

    sudo sed -i "s/server_name .*/server_name $NEW_DOMAIN;/" /etc/nginx/sites-available/reverse-proxy
    sudo nginx -t && sudo systemctl restart nginx
    sudo certbot --nginx -d "$NEW_DOMAIN" --force-renewal
    echo "✅ 域名修改完成！新地址: https://$NEW_DOMAIN"

# ====================== 3. 完全卸载 ======================
elif [ "$CHOICE" = "3" ]; then
    echo "1) 彻底卸载（删除所有数据）"
    echo "2) 卸载但保留数据（保留 config.yaml）"
    read -p "请选择 (1/2): " UNINSTALL_MODE

    [ "$UNINSTALL_MODE" = "1" ] && cleanup_full || cleanup_keep_data
    echo "✅ 卸载完成！"
else
    echo "❌ 无效选项！"
    exit 1
fi
EOF
