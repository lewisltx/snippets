# v2ray nginx

## 目录结构

```text
v2ray-nginx/
├── docker-compose.yml          # 一键启动
├── Dockerfile.v2ray            # V2Ray 镜像
├── scripts/
│   ├── acme.sh-issue.sh        # 启动时申请证书
│   └── v2ray-gen-config.sh     # 生成 v2ray 配置
└── conf/
    ├── nginx.conf.template     # nginx 配置模板
    └── v2ray.json.template     # v2ray 配置模板
```

## 一键部署

```shell
# 克隆仓库
git clone https://github.com/lewisltx/snippets.git && cd snippets/v2ray-nginx

# 生成 .env
cat > .env <<EOF
DOMAIN=<domain>
VMESS_UUID=
CF_Email=<email>
CF_Key=<key>
EOF

# 申请证书，仅需执行一次
docker compose run acme-sh issue.sh

# 启动所有服务
docker-compose up -d --build
```

## 常用命令

| 需求   | 命令示例                                                     |
| ---- |----------------------------------------------------------|
| 查看日志 | `docker-compose logs -f nginx`                           |
| 更新镜像 | `docker-compose build --no-cache && docker-compose up -d` |
| 手动续签 | `docker exec acme.sh acme.sh --renew`                    |

## 命名卷

- v2ray-config: v2ray 配置
- nginx-config: nginx 配置
- acme-sh-home: acme.sh 配置
- acme-sh-ssl: HTTPS 证书