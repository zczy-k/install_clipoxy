#!/bin/bash
set -e

echo "========================================="
echo "   CLIProxyAPIPlus 一键交互式安装脚本"
echo "   (Debian 11 低内存优化版)"
echo "========================================="

# 输入域名
read -p "请输入要使用的域名 (默认: cpa.studyzy.eu.org): " DOMAIN
DOMAIN=${DOMAIN:-cpa.studyzy.eu.org}

echo "即将使用的域名: $DOMAIN"
read -p "确认正确吗？(y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "安装已取消"
    exit 1
fi

# 1. 清理残留
echo "[1/8] 清理旧残留..."
systemctl --user stop cliproxyapi 2>/dev/null || true
systemctl --user disable cliproxyapi 2>/dev/null || true
rm -f ~/.config/systemd/user/cliproxyapi.service
rm -rf ~/ai-infra/CLIProxyAPIPlus
sudo rm -f /etc/nginx/sites-enabled/reverse-proxy
sudo rm -f /etc/nginx/sites-available/reverse-proxy
sudo certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true

# 2. 系统更新与工具
echo "[2/8] 安装必要工具..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git wget build-essential ca-certificates upx nginx certbot python3-certbot-nginx

# 3. 安装 Go
echo "[3/8] 安装 Go 1.24..."
cd /tmp
wget -q https://go.dev/dl/go1.24.1.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.24.1.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /root/.bashrc > /dev/null
echo 'export GOPATH=/root/go' >> /root/.bashrc
echo 'export PATH=$PATH:$GOPATH/bin' >> /root/.bashrc
source /root/.bashrc
go version

# 4. 编译项目
echo "[4/8] 编译 CLIProxyAPIPlus..."
mkdir -p ~/ai-infra && cd ~/ai-infra
git clone https://github.com/router-for-me/CLIProxyAPIPlus.git
cd CLIProxyAPIPlus

go build -trimpath -ldflags "-s -w" -o cliproxyapi ./cmd/server
upx --best --lzma cliproxyapi 2>/dev/null || true
chmod +x cliproxyapi

# 5. 配置 config.yaml（自动打开编辑）
echo "[5/8] 配置 config.yaml ..."

if [ -f "config.example.yaml" ]; then
    cp -f config.example.yaml config.yaml
    echo "已复制官方配置模板"
else
    cat > config.yaml << MINI
server:
  host: "0.0.0.0"
  port: 8317
debug: true
MINI
fi

# 确保端口正确
sed -i '/^server:/,/^[^ ]/d' config.yaml 2>/dev/null || true
cat >> config.yaml << EOF

# ==================== 脚本强制设置 ====================
server:
  host: "0.0.0.0"
  port: 8317
debug: true
EOF

echo "--------------------------------------------------"
echo "即将打开 nano 编辑 config.yaml"
echo "你可以在这里添加 OAuth、API Keys、管理面板密码等设置"
echo "编辑完成后：Ctrl+O 保存 → Enter → Ctrl+X 退出"
echo "--------------------------------------------------"

read -p "按 Enter 键打开编辑器..."

nano config.yaml

echo "配置编辑完成，继续安装..."

# 6. 创建 systemd 服务
echo "[6/8] 创建 systemd 服务..."
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

# 7. 配置 Nginx
echo "[7/8] 配置 Nginx..."
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
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Upgrade \$http_upgrade;
        client_max_body_size 50m;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/reverse-proxy /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# 8. 申请证书
echo "[8/8] 申请 HTTPS 证书..."
sudo certbot --nginx -d "$DOMAIN"

echo "========================================="
echo "安装完成！"
echo "访问地址: https://$DOMAIN"
echo "常用命令："
echo "  systemctl --user status cliproxyapi"
echo "  nano ~/ai-infra/CLIProxyAPIPlus/config.yaml"
echo "========================================="
