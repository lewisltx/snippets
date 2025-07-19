#!/bin/bash
set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Function to check command execution status
check_status() {
  if [ $? -ne 0 ]; then
    echo "Error: $1 failed"
    exit 1
  fi
}

# Parse domain parameter
while getopts "d:" opt; do
  case $opt in
    d) DOMAIN=$OPTARG ;;
    *) echo "Usage: $0 -d <domain>"; exit 1 ;;
  esac
done

process_key_value() {
    local key_value="$1"

    if [[ "$key_value" == domain=* ]]; then
        DOMAIN="${key_value#domain=}"
    fi
}

for key_value in "$@"; do
    process_key_value "$key_value"
done

if [ -z "$DOMAIN" ]; then
  echo "Domain parameter is required."
  echo "Usage: $0 -d <domain> or $0 domain=<domain>"
  exit 1
fi

# 1. System update, disable firewall and SELinux
echo "Updating system and disabling firewall/SELinux..."
dnf update -y
check_status "System update"
systemctl disable --now firewalld
check_status "Disable firewalld"
setenforce 0 || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
check_status "Disable SELinux"

# 2. Optimize system limits (ulimit)
echo "Optimizing system limits..."
cat <<EOF > /etc/security/limits.d/90-custom.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
check_status "Set ulimit parameters"

# 3. Optimize kernel parameters
echo "Optimizing kernel parameters..."
cat <<EOF > /etc/sysctl.d/90-custom.conf
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p /etc/sysctl.d/90-custom.conf
check_status "Apply kernel parameters"

# 4. Install and configure V2Ray
echo "Installing and configuring V2Ray..."
curl -sL https://github.com/v2fly/fhs-install-v2ray/raw/master/install-release.sh | bash
check_status "V2Ray installation"
VMESS_ID=$(v2ray uuid)
mkdir -p /usr/local/etc/v2ray
cat <<EOF > /usr/local/etc/v2ray/config.json
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 50808,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$VMESS_ID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ],
  "dns": {
    "servers": [
      "https://dns.google/dns-query",
      "https://cloudflare-dns.com/dns-query"
    ]
  },
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
check_status "V2Ray configuration"
systemctl enable --now v2ray
check_status "V2Ray service start"

# 5. Install Nginx and acme.sh, apply SSL certificate
echo "Installing Nginx and acme.sh, applying SSL certificate..."
dnf install -y nginx
check_status "Nginx installation"
systemctl enable --now nginx
check_status "Nginx service start"
curl -sL https://get.acme.sh | sh -s email=webmaster@$DOMAIN
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$DOMAIN" -w /usr/share/nginx/html --keylength 2048
check_status "SSL certificate issuance"
mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/"$DOMAIN".key \
  --fullchain-file /etc/nginx/ssl/"$DOMAIN".crt \
  --reloadcmd "systemctl reload nginx"
check_status "SSL certificate installation"

# 6. Configure Nginx reverse proxy
echo "Configuring Nginx reverse proxy..."

# fix nginx 1.25.0 http2 direction
NGINX_VERSION=$(nginx -v 2>&1 | grep -Eo '\d+\.\d+\.\d+')
if [[ "$(printf '%s\n' "$NGINX_VERSION" "1.25.0" | sort -V | head -n1)" == "1.25.0" ]]; then
    NGINX_SSL_LISTEN="listen 443 ssl; listen [::]:443 ssl; http2 on;"
else
    NGINX_SSL_LISTEN="listen 443 ssl http2; listen [::]:443 ssl http2;"
fi

curl -s https://ssl-config.mozilla.org/ffdhe2048.txt > /etc/nginx/dhparam.pem

cat <<EOF > /etc/nginx/conf.d/$DOMAIN.conf
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    $NGINX_SSL_LISTEN
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_dhparam /etc/nginx/dhparam.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    location /vmess {
        proxy_pass http://127.0.0.1:50808;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location / {
        root /usr/share/nginx/html;
        index index.html index.htm;
    }
}
EOF
check_status "Nginx configuration"
systemctl restart nginx
check_status "Nginx service restart"

# Output Messages
echo "Setup completed successfully!"
echo "=============================================="
echo "VMess ID: $VMESS_ID"
echo "Server: $DOMAIN"
echo "Port: 443"
echo "Transport: WebSocket"
echo "Path: /vmess"
echo "TLS: Enabled"
echo "=============================================="
