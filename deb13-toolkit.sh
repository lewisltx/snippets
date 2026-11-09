#!/usr/bin/env bash
# =============================================================================
# deb13-toolkit.sh - Debian 13 多功能部署工具（交互菜单 + 参数两种运行方式）
# -----------------------------------------------------------------------------
# 能力：
#   1. 更新软件源并安装常用依赖                  【必选，其余步骤自动包含】
#   2. 安装 fscarmen/warp，提供 IPv4/IPv6 双栈  【可选，仅显式指定才执行】
#   3. 安装并配置 NGINX（默认首页 + ACME 目录）
#   4. 安装 acme.sh，申请并部署证书（HTTP-01 webroot）→ 可访问 HTTPS 首页
#   5. 安装 XTLS/Xray-core（VLESS + XHTTP），NGINX 443 路径反代 → 外部可访问
#
# 依赖链： 5 -> 4 -> 3 -> 1；2 可选；1 必选。脚本会自动补齐并按 1,2,3,4,5 顺序执行。
#
# 设计要点：
#   * 所有配置文件覆盖前都备份到 /var/backups/deb13-toolkit/<时间戳>/
#   * NGINX 变更前后都执行 nginx -t，失败自动回滚上一次的托管配置
#   * 步骤可重复执行（幂等），参数持久化在 /etc/deb13-toolkit.conf
#   * 仅托管 /etc/nginx/conf.d/toolkit.conf，不动发行版自带站点文件（只摘掉软链）
#
# 合规提示：仅在你拥有合法管理权限、且符合所在地法规与云服务商条款的服务器上使用。
# 编写环境：本脚本未在目标 Debian 13 主机上实测，请先用 --plan / --status 检查，
#           并在具备 VNC/控制台的机器上执行，尤其是步骤 2（会修改默认路由）。
# 用法：bash deb13-toolkit.sh --help
# =============================================================================

set -Eeuo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="1.0.0"
RUN_TAG="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="/var/log/deb13-toolkit.log"
# 非 root 环境（例如用 --help / --plan 预览时）退回临时目录，避免日志重定向报错
if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
  LOG_FILE="${TMPDIR:-/tmp}/deb13-toolkit.log"
  ( : >> "$LOG_FILE" ) 2>/dev/null || true
fi
CONF_FILE="/etc/deb13-toolkit.conf"
STATE_DIR="/var/lib/deb13-toolkit"
STATE_FILE="${STATE_DIR}/state"
BACKUP_ROOT="/var/backups/deb13-toolkit"
BACKUP_DIR="${BACKUP_ROOT}/${RUN_TAG}"
WARP_DIR="/opt/deb13-toolkit/warp"

WEBROOT="/var/www/html"
NGINX_CONF="/etc/nginx/conf.d/toolkit.conf"
SSL_DIR="/etc/nginx/ssl"
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_UNIT="/etc/systemd/system/xray.service"
XRAY_ASSET="/usr/local/share/xray"
WARP_RAW="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"

# -----------------------------------------------------------------------------
# 日志 / 出错处理
# -----------------------------------------------------------------------------
log() {
  local level="$1" msg ts color='' reset=$'\033[0m'
  shift
  msg="$*"
  ts="$(date '+%F %T')"
  case "$level" in
    INFO)  color=$'\033[36m' ;;
    OK)    color=$'\033[32m' ;;
    WARN)  color=$'\033[33m' ;;
    ERROR) color=$'\033[31m' ;;
    STEP)  color=$'\033[1;34m' ;;
  esac
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  if [[ -t 1 && -n "$color" ]]; then
    printf '[%s] [%s] %s%s%s\n' "$ts" "$level" "$color" "$msg" "$reset"
  else
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg"
  fi
}

on_err() {
  local rc=$? line="$1" cmd="$2" msg
  msg="$(date '+%F %T') [ERROR] line=${line} rc=${rc} cmd=${cmd}"
  printf '%s\n' "$msg" >&2
  printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
  printf '[ERROR] 日志: %s\n[ERROR] 本次备份: %s\n' "$LOG_FILE" "$BACKUP_DIR" >&2
  printf '[ERROR] 可回滚 NGINX: bash %s --rollback-nginx\n' "${0##*/}" >&2
  exit "$rc"
}
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

die() { log ERROR "$*"; exit 1; }
step_banner() { log STEP "========== $* =========="; }

confirm() {
  local prompt="$1" ans
  if [[ "$ASSUME_YES" == "1" ]]; then
    log INFO "自动确认: ${prompt}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "非交互环境需要 --yes 才能确认「${prompt}」"
  fi
  read -r -p "${prompt} [y/N]: " ans || true
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}

risk_note() {
  log WARN "⚠️ 风险提醒：$*"
}

# -----------------------------------------------------------------------------
# 配置 / 状态持久化（纯文本 KEY="VALUE"，不做 source，避免注入）
# -----------------------------------------------------------------------------
get_conf() {
  local key="$1" line val
  [[ -f "$CONF_FILE" ]] || return 1
  line="$(grep -m1 "^${key}=" "$CONF_FILE" 2>/dev/null)" || return 1
  val="${line#*=}"
  val="${val#\"}"; val="${val%\"}"
  printf '%s' "$val"
}

save_kv() {
  local key="$1" val="$2" tmp
  mkdir -p "$(dirname "$CONF_FILE")"
  [[ -f "$CONF_FILE" ]] || : > "$CONF_FILE"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$CONF_FILE" > "$tmp" || true
  printf '%s="%s"\n' "$key" "${val//\"/\\\"}" >> "$tmp"
  mv -f "$tmp" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

is_done() { [[ -f "$STATE_FILE" ]] && grep -q "^$1=" "$STATE_FILE" 2>/dev/null; }
mark_done() {
  local tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp)"
  if [[ -f "$STATE_FILE" ]]; then grep -v "^$1=" "$STATE_FILE" > "$tmp" || true; fi
  printf '%s=%s\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  chmod 644 "$STATE_FILE"
}

backup_file() {
  local f="$1"
  [[ -e "$f" || -L "$f" ]] || return 0
  mkdir -p "${BACKUP_DIR}$(dirname "$f")"
  cp -a -- "$f" "${BACKUP_DIR}${f}"
  printf '%s\n' "$BACKUP_DIR" > "${BACKUP_ROOT}/LATEST"
  log INFO "已备份: ${f} -> ${BACKUP_DIR}${f}"
}

# -----------------------------------------------------------------------------
# 校验 / 小工具
# -----------------------------------------------------------------------------
preflight() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "必须用 root 运行（当前仅开放 root 登录，可直接用 root 执行）"
  fi
  local os_id="" os_ver="" os_name=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"; os_ver="${VERSION_ID:-}"; os_name="${PRETTY_NAME:-unknown}"
  fi
  log INFO "系统: ${os_name} | 内核: $(uname -r) | 架构: $(uname -m)"
  if [[ "$os_id" != "debian" || "$os_ver" != "13" ]]; then
    if [[ "$FORCE_OS" == "1" ]]; then
      log WARN "非 Debian 13（--force 已跳过校验），命令与包名可能不兼容"
    else
      die "本脚本面向 Debian 13，检测到 ID=${os_id:-?} VERSION_ID=${os_ver:-?}；确认无误可加 --force"
    fi
  fi
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$(dirname "$SSL_DIR")" "$(dirname "$XRAY_CONFIG")"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  printf '%s\n' "$BACKUP_DIR" > "${BACKUP_ROOT}/LATEST"
  log INFO "日志文件: ${LOG_FILE}"
  log INFO "备份目录: ${BACKUP_DIR}"
  log WARN "合规提示：仅在合法授权且符合当地法规/云厂商条款的服务器上使用。"
}

has_ipv6() {
  # 注意：/proc/net/if_inet6 是 procfs（seq_file）虚拟文件，stat 得到的 st_size 恒为 0，
  # 因此 [[ -s ... ]] 永远为假，哪怕 cat 能读出多行地址。必须实际读取内容来判断。
  if [[ -r /proc/net/if_inet6 ]]; then
    if grep -qE '^[[:xdigit:]]{8}' /proc/net/if_inet6 2>/dev/null; then
      return 0
    fi
    return 1
  fi
  # 容器等场景可能不挂载 if_inet6：退而检查内核 IPv6 总开关
  local disabled
  disabled="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf '1')"
  if [[ "$disabled" == "0" ]]; then return 0; fi
  return 1
}

validate_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
validate_xray_path() { [[ "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]; }

require_domain() {
  local input=""
  if [[ -z "$DOMAIN" ]]; then
    if [[ "$ASSUME_YES" == "1" || ! -t 0 ]]; then
      die "步骤 4/5 必须提供域名：--domain example.com（交互模式会提示输入）"
    fi
    read -r -p "请输入已解析到本机的域名: " input || true
    DOMAIN="$input"
  fi
  validate_domain "$DOMAIN" || die "域名格式不合法: ${DOMAIN}"
  if [[ -z "$ACME_EMAIL" ]]; then ACME_EMAIL="admin@${DOMAIN}"; fi
  # 域名变化时同步证书路径，避免 NGINX 引用到旧域名证书
  CERT_FILE="/etc/nginx/ssl/${DOMAIN}.crt"
  KEY_FILE="/etc/nginx/ssl/${DOMAIN}.key"
  save_kv DOMAIN "$DOMAIN"
  save_kv ACME_EMAIL "$ACME_EMAIL"
  save_kv CERT_FILE "$CERT_FILE"
  save_kv KEY_FILE "$KEY_FILE"
  log INFO "使用域名: ${DOMAIN} | ACME 账户: ${ACME_EMAIL} | 证书: ${CERT_FILE}"
}

check_domain_dns() {
  local resolved="" public=""
  command -v curl >/dev/null 2>&1 || return 0
  resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
  public="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    log WARN "域名 ${DOMAIN} 未解析到 A 记录；签发前请确认 DNS 已生效"
  elif [[ -n "$public" && "$resolved" != "$public" ]]; then
    log WARN "域名 A 记录 ${resolved} 与本机公网 IPv4 ${public} 不一致（CDN/负载均衡属正常），请确认 80 端口能回源到本机"
  else
    log OK "域名解析检查通过: ${resolved}"
  fi
}

random_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' < /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
  fi
}

# -----------------------------------------------------------------------------
# NGINX 配置渲染（单一托管文件）
# -----------------------------------------------------------------------------
nginx_supports_http2_directive() {
  local v=""
  v="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [[ -n "$v" ]] || return 1
  [[ "$(printf '%s\n' "1.25.1" "$v" | sort -V | head -n1)" == "1.25.1" ]]
}

render_nginx_conf() {
  local tls=0 xray=0 tmp
  local listen6_80='' listen6_443='' http2_line='' redirect_line='' xray_location=''
  local server_name="${DOMAIN:-_}"

  if [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]]; then tls=1; fi
  if [[ -s "$XRAY_CONFIG" && -s "$XRAY_BIN" ]]; then xray=1; fi

  if has_ipv6; then
    listen6_80='    listen [::]:80 default_server;'
    listen6_443='    listen [::]:443 ssl default_server;'
  fi

  if (( tls )); then
    if nginx_supports_http2_directive; then http2_line='    http2 on;'; fi
    if (( REDIRECT_HTTP )); then
      # 单引号保证 $host/$request_uri 原样写入 nginx 配置
      redirect_line='        return 301 https://$host$request_uri;'
    fi
  fi

  if (( xray )); then
    xray_location=$(cat <<EOF
    # VLESS-XHTTP 入口：TLS 由 NGINX 终结，回源到本机明文 Xray
    location ^~ ${XRAY_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_PORT};
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # 清空 Connection，让 NGINX 以 HTTP/1.1 长连接回源；XHTTP 不需要 WebSocket Upgrade
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        client_max_body_size 0;
        client_body_timeout 300s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
    }
EOF
)
  fi

  tmp="$(mktemp /tmp/toolkit-nginx-XXXXXX)"
  {
    cat <<EOF
# ============================================================================
# 由 deb13-toolkit.sh 托管生成，请勿手工编辑；改动会被下一次执行覆盖。
# 回滚：bash deb13-toolkit.sh --rollback-nginx
# 生成时间: $(date '+%Y-%m-%dT%H:%M:%S%z')
# ============================================================================
server {
    listen 80 default_server;
${listen6_80}
    server_name ${server_name};

    root ${WEBROOT};
    index index.html index.htm;
    access_log /var/log/nginx/toolkit.access.log;
    error_log  /var/log/nginx/toolkit.error.log warn;

    client_max_body_size 64m;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    # acme.sh HTTP-01 webroot 验证 + 续期专用，禁止跳转到 HTTPS
    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location = /healthz {
        default_type text/plain;
        return 200 "ok";
    }

    location / {
${redirect_line}
        try_files \$uri \$uri/ =404;
    }
}
EOF
    if (( tls )); then
      cat <<EOF

server {
    listen 443 ssl default_server;
${listen6_443}
${http2_line}
    server_name ${server_name};

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root ${WEBROOT};
    index index.html index.htm;
    access_log /var/log/nginx/toolkit-ssl.access.log;
    error_log  /var/log/nginx/toolkit-ssl.error.log warn;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location = /healthz {
        default_type text/plain;
        return 200 "ok";
    }

${xray_location}

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi
  } > "$tmp"

  backup_file "$NGINX_CONF"
  if [[ -L /etc/nginx/sites-enabled/default || -e /etc/nginx/sites-enabled/default ]]; then
    backup_file /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default   # 仅摘掉发行版默认站点软链，源文件保留
  fi
  mkdir -p "$(dirname "$NGINX_CONF")"
  mv -f "$tmp" "$NGINX_CONF"
  chmod 644 "$NGINX_CONF"
  apply_nginx "生成 NGINX 配置"
}

# 回滚时恢复发行版默认站点：优先用备份里的软链；无备份且托管配置已移除时重建软链
restore_default_site() {
  local d="$1"
  if [[ -L "${d}/etc/nginx/sites-enabled/default" ]]; then
    mkdir -p /etc/nginx/sites-enabled
    cp -a -- "${d}/etc/nginx/sites-enabled/default" /etc/nginx/sites-enabled/
  elif [[ -e /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default && ! -e "$NGINX_CONF" ]]; then
    mkdir -p /etc/nginx/sites-enabled
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  fi
}

apply_nginx() {
  local why="${1:-应用 NGINX 配置}"
  if ! nginx -t 2>&1 | tee -a "$LOG_FILE"; then
    log ERROR "nginx -t 失败，开始回滚托管配置"
    if [[ -e "${BACKUP_DIR}${NGINX_CONF}" ]]; then
      mkdir -p "$(dirname "$NGINX_CONF")"
      cp -a -- "${BACKUP_DIR}${NGINX_CONF}" "$NGINX_CONF"
    else
      rm -f "$NGINX_CONF"
    fi
    restore_default_site "$BACKUP_DIR"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    die "NGINX 配置校验未通过（${why}），已回滚；详见 ${LOG_FILE}"
  fi
  systemctl reload nginx
  log OK "NGINX 配置已生效: ${why}"
}

ensure_ports() {
  log WARN "外部访问需在云厂商安全组放行 TCP 80/443（SSH 22 保持不变），脚本无法代改云平台规则。"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    if confirm "检测到 ufw 处于启用状态，是否自动放行 22/80/443（仅新增 allow 规则）?"; then
      backup_file /etc/ufw/user.rules
      ufw allow 22/tcp >/dev/null
      ufw allow 80/tcp >/dev/null
      ufw allow 443/tcp >/dev/null
      log OK "ufw 已放行 22/80/443"
    fi
  elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q '^table'; then
    log WARN "检测到 nftables 规则集，请自行确认 80/443 未被拦截（脚本不改写 nftables）"
  fi
}

# -----------------------------------------------------------------------------
# 步骤 1：更新源 + 常用依赖
# -----------------------------------------------------------------------------
set_apt_mirror() {
  risk_note "即将改写 /etc/apt 下的源地址（会先备份到 ${BACKUP_DIR}），错误的镜像会导致 apt 失败。"
  confirm "确认更换软件源为 ${MIRROR} ?" || { log WARN "跳过换源"; MIRROR=''; return 0; }
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    backup_file "$f"
    cp -a -- "$f" "${f}.bak-${RUN_TAG}"
    # DEB822 (Debian 13 默认)：URIs: http://deb.debian.org/debian(-security)
    sed -E -i "s|^(URIs:[[:space:]]*)https?://[^/]+|\1${MIRROR}|g" "$f"
    # 传统一行式：deb http://deb.debian.org/debian trixie main
    sed -E -i "s|^([[:space:]]*deb(-src)?[[:space:]]+)https?://[^/]+|\1${MIRROR}|g" "$f"
  done
  log OK "软件源已切换到 ${MIRROR}（原文件另存为 *.bak-${RUN_TAG}）"
}

step1_apt() {
  step_banner "步骤 1/5：更新软件源并安装常用依赖"
  command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get，请确认是 Debian 系系统"
  if [[ -n "$MIRROR" ]]; then set_apt_mirror; fi

  log INFO "apt-get update ..."
  apt-get update -o Acquire::Retries=3 2>&1 | tee -a "$LOG_FILE"

  local pkgs=(
    ca-certificates curl wget git jq unzip xz-utils tar openssl socat
    cron procps iproute2 gnupg lsb-release sudo
  )
  log INFO "安装依赖: ${pkgs[*]}"
  apt-get install -y --no-install-recommends "${pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"

  local c
  for c in curl wget git jq unzip openssl socat crontab ss; do
    command -v "$c" >/dev/null 2>&1 || die "依赖安装后仍缺少命令: ${c}"
  done
  systemctl enable --now cron >/dev/null 2>&1 || log WARN "cron 未能自动启动，acme.sh 自动续期可能失效"
  log OK "步骤 1 完成；软件源索引与常用依赖已就绪"
  mark_done 1
}

# -----------------------------------------------------------------------------
# 步骤 2：WARP 双栈（可选）
# -----------------------------------------------------------------------------
verify_dual_stack() {
  local v4='' v6=''
  command -v curl >/dev/null 2>&1 || return 0
  v4="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 10 https://ipv4.icanhazip.com 2>/dev/null || true)"
  v6="$(curl -6 -fsS --max-time 10 https://api6.ipify.org 2>/dev/null || curl -6 -fsS --max-time 10 https://ipv6.icanhazip.com 2>/dev/null || true)"
  log INFO "IPv4 出站: ${v4:-不可用} | IPv6 出站: ${v6:-不可用}"
  if [[ -n "$v4" && -n "$v6" ]]; then
    log OK "双栈访问验证通过：可访问 IPv4 only 与 IPv6 only 站点"
  else
    log WARN "当前不是完整双栈；可在菜单中重跑步骤 2，或手动执行: warp d / warp s d"
  fi
}

step2_warp() {
  step_banner "步骤 2/5（可选）：安装 fscarmen/warp，开启双栈访问"
  risk_note "WARP 会新建 WireGuard 接口并修改默认路由/DNS，存在 SSH 断连风险；务必先确保有云控制台(VNC)可登录。"
  risk_note "建议在 screen/tmux 中执行，且不要在业务高峰期操作；回滚由上游脚本提供（warp u 卸载）。"
  confirm "确认继续安装 WARP（模式 ${WARP_MODE}）?" || { log WARN "已跳过步骤 2"; return 0; }

  mkdir -p "$WARP_DIR"
  log INFO "下载 ${WARP_RAW}"
  curl -fL --retry 3 --connect-timeout 15 -o "${WARP_DIR}/menu.sh" "$WARP_RAW" \
    || die "WARP 脚本下载失败（GitLab 可达性问题）；可先确认网络或稍后重试"
  chmod +x "${WARP_DIR}/menu.sh"

  log INFO "执行 menu.sh ${WARP_MODE}（d=双栈 / 4=IPv4 / 6=IPv6；上游脚本首次运行可能询问语言）"
  ( cd "$WARP_DIR" && bash ./menu.sh "$WARP_MODE" ) 2>&1 | tee -a "$LOG_FILE"

  verify_dual_stack
  log INFO "后续管理：上游脚本安装后一般可用 warp d / warp s d / warp o / warp u"
  log OK "步骤 2 完成"
  mark_done 2
}

# -----------------------------------------------------------------------------
# 步骤 3：NGINX
# -----------------------------------------------------------------------------
write_index_page() {
  backup_file "${WEBROOT}/index.html"
  mkdir -p "$WEBROOT"
  cat > "${WEBROOT}/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${HOSTNAME:-Debian 13} · 站点就绪</title>
<style>
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f5f7fa;color:#1f2937}
  main{max-width:720px;margin:10vh auto;padding:32px;background:#fff;border-radius:12px;box-shadow:0 8px 28px rgba(0,0,0,.08)}
  h1{margin:0 0 12px;font-size:26px} code{background:#eef2f7;padding:2px 6px;border-radius:4px}
  .ok{color:#0f9d58;font-weight:600} footer{margin-top:24px;color:#6b7280;font-size:13px}
</style>
</head>
<body>
<main>
  <h1><span class="ok">●</span> NGINX 默认站点运行正常</h1>
  <p>此页面由 <code>deb13-toolkit.sh</code> 生成，用于验证 HTTP/HTTPS 与证书部署。</p>
  <p>主机：<code>$(hostname)</code> ｜ 生成时间：<code>$(date '+%Y-%m-%dT%H:%M:%S%z')</code></p>
  <footer>健康检查：<code>/healthz</code> ｜ 证书验证目录：<code>/.well-known/acme-challenge/</code></footer>
</main>
</body>
</html>
EOF
  chmod 644 "${WEBROOT}/index.html"
}

step3_nginx() {
  step_banner "步骤 3/5：安装并配置 NGINX 默认站点"
  apt-get install -y --no-install-recommends nginx 2>&1 | tee -a "$LOG_FILE"
  systemctl enable --now nginx 2>&1 | tee -a "$LOG_FILE"

  write_index_page
  render_nginx_conf
  ensure_ports

  local code=''
  code="$(curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || true)"
  [[ "$code" == "200" ]] || die "本机 HTTP 首页验证失败（code=${code:-无响应}），请检查 nginx -t 与 systemctl status nginx"
  curl -fsS --max-time 10 http://127.0.0.1/healthz 2>/dev/null | grep -q '^ok' \
    || log WARN "/healthz 未返回 ok（不影响首页）"
  systemctl is-active --quiet nginx || die "nginx 服务未处于 active 状态"
  log OK "步骤 3 完成：HTTP 首页返回 200，nginx 已设为开机自启"
  mark_done 3
}

# -----------------------------------------------------------------------------
# 步骤 4：acme.sh + 证书
# -----------------------------------------------------------------------------
step4_acme() {
  step_banner "步骤 4/5：安装 acme.sh，申请并部署 TLS 证书"
  require_domain
  command -v nginx >/dev/null 2>&1 || die "未找到 nginx，请先执行步骤 3"
  systemctl is-active --quiet nginx || die "nginx 未运行，请先执行步骤 3"
  check_domain_dns

  risk_note "证书签发依赖公网 80 端口可达 + 域名 A/AAAA 记录指向本机；Let's Encrypt 有速率限制，请勿反复强制重签。"

  if [[ ! -x "$ACME_BIN" ]]; then
    log INFO "安装 acme.sh 到 ${ACME_HOME}"
    curl -fsSL --retry 3 https://get.acme.sh | sh -s "email=${ACME_EMAIL}" 2>&1 | tee -a "$LOG_FILE"
  fi
  [[ -x "$ACME_BIN" ]] || die "acme.sh 安装失败：${ACME_BIN} 不存在"
  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 \
    || log WARN "设置默认 CA 未成功（不影响本次签发，已显式指定 --server letsencrypt）"

  mkdir -p "$SSL_DIR"; chmod 755 "$SSL_DIR"
  # 预创建目标文件以固定权限（acme.sh 会保留已有属主/权限）
  touch "$CERT_FILE" "$KEY_FILE"
  chmod 644 "$CERT_FILE"; chmod 600 "$KEY_FILE"

  local need_issue=1
  if [[ -s "$CERT_FILE" ]] && openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" >/dev/null 2>&1; then
    need_issue=0
    log INFO "检测到有效期 >30 天的现成证书，跳过签发（--force-cert 可强制重签）"
  fi
  if (( FORCE_CERT )); then need_issue=1; fi

  if (( need_issue )); then
    local -a issue_args=(--issue -d "$DOMAIN" -w "$WEBROOT" --server letsencrypt --keylength 2048)
    (( FORCE_CERT )) && issue_args+=(--force)
    log INFO "签发证书: ${issue_args[*]}"
    "$ACME_BIN" "${issue_args[@]}" 2>&1 | tee -a "$LOG_FILE"
  fi

  log INFO "部署证书到 ${CERT_FILE} / ${KEY_FILE}"
  "$ACME_BIN" --install-cert -d "$DOMAIN" \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CERT_FILE" \
    --reloadcmd "nginx -t && systemctl reload nginx" 2>&1 | tee -a "$LOG_FILE"
  chmod 644 "$CERT_FILE"; chmod 600 "$KEY_FILE"

  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || die "证书文件未生成：${CERT_FILE} / ${KEY_FILE}"
  openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates 2>&1 | tee -a "$LOG_FILE"
  crontab -l 2>/dev/null | grep -q 'acme.sh' \
    || log WARN "未检测到 acme.sh 定时任务，请检查 cron 服务与 ~/.acme.sh 安装日志（影响自动续期）"

  render_nginx_conf
  local code=''
  code="$(curl -fsS --max-time 15 --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null || true)"
  [[ "$code" == "200" ]] || die "HTTPS 首页验证失败（code=${code:-无响应}），请检查证书与 nginx error log"
  log OK "步骤 4 完成：HTTPS 首页返回 200，证书已由 acme.sh 自动续期管理"
  save_kv CERT_FILE "$CERT_FILE"
  save_kv KEY_FILE "$KEY_FILE"
  mark_done 4
}

# -----------------------------------------------------------------------------
# 步骤 5：Xray-core VLESS-XHTTP + NGINX 反代
# -----------------------------------------------------------------------------
install_xray_binary() {
  local arch asset url zip tmpdir alt='' api=''
  case "$(uname -m)" in
    x86_64|amd64)  asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "暂不支持架构 $(uname -m)，请手动下载对应 Xray 发布包放到 ${XRAY_BIN}" ;;
  esac
  if [[ "$XRAY_VERSION" == "latest" ]]; then
    url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
  else
    url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}"
  fi

  zip="$(mktemp /tmp/xray-XXXXXX)"
  log INFO "下载 Xray-core: ${url}"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$zip" "$url"; then
    log WARN "latest/download 直链失败，改用 GitHub API 查询 asset"
    api="$(curl -fsSL --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null || true)"
    alt="$(printf '%s' "$api" | jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .browser_download_url' 2>/dev/null | head -n1 || true)"
    [[ -n "$alt" && "$alt" != "null" ]] || die "无法获取 Xray 下载地址（GitHub 不可达？可先执行步骤 2 或配置网络）"
    curl -fL --retry 3 --connect-timeout 15 -o "$zip" "$alt" || die "Xray 备用地址下载失败"
  fi

  tmpdir="$(mktemp -d /tmp/xray-XXXXXX)"
  unzip -q -o "$zip" -d "$tmpdir"
  [[ -f "${tmpdir}/xray" ]] || die "发布包中未找到 xray 二进制"
  backup_file "$XRAY_BIN"
  install -m 755 "${tmpdir}/xray" "$XRAY_BIN"
  mkdir -p "$XRAY_ASSET" "$(dirname "$XRAY_CONFIG")" /var/log/xray
  local f
  for f in geoip.dat geosite.dat; do
    [[ -f "${tmpdir}/${f}" ]] && install -m 644 "${tmpdir}/${f}" "${XRAY_ASSET}/${f}"
  done
  chown -R nobody:nogroup /var/log/xray
  "$XRAY_BIN" version 2>&1 | tee -a "$LOG_FILE"
  if [[ "$tmpdir" == /tmp/xray-* ]]; then rm -rf -- "$tmpdir"; fi
  rm -f -- "$zip"
}

write_xray_config() {
  backup_file "$XRAY_CONFIG"
  local routing_json=''
  if [[ -s "${XRAY_ASSET}/geoip.dat" ]]; then
    routing_json=$(cat <<'EOF'
,
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" }
    ]
  }
EOF
)
  fi
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://dns.google/dns-query",
      "8.8.8.8"
    ]
  },
  "inbounds": [
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${XRAY_PATH}",
          "host": "${DOMAIN}",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ]${routing_json}
}
EOF
  jq empty "$XRAY_CONFIG" || die "Xray 配置不是合法 JSON"
  chown root:nogroup "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
}

write_xray_unit() {
  backup_file "$XRAY_UNIT"
  cat > "$XRAY_UNIT" <<'EOF'
[Unit]
Description=Xray Service (VLESS-XHTTP, managed by deb13-toolkit)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNPROC=10000
LimitNOFILE=1000000
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$XRAY_UNIT"
}

step5_xray() {
  step_banner "步骤 5/5：安装 Xray-core（VLESS-XHTTP）+ NGINX 反代"
  require_domain
  [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] \
    || die "未找到证书（步骤 4 的产物）；依赖链应已自动执行步骤 4，请检查其报错"
  validate_port "$XRAY_PORT" || die "Xray 本地端口不合法: ${XRAY_PORT}"
  validate_xray_path "$XRAY_PATH" || die "XHTTP 路径不合法（须以 / 开头且只含字母数字 ._~-）: ${XRAY_PATH}"
  if [[ -z "$UUID" ]]; then UUID="$(random_uuid)"; fi

  risk_note "Xray 会在本机 ${XRAY_PORT} 监听并对外提供代理入口；UUID/路径等同凭据，请勿外泄。"
  risk_note "请确保符合所在地法规与云服务商条款；证书私钥 ${KEY_FILE} 权限为 600，勿纳入版本库。"

  install_xray_binary
  write_xray_config
  write_xray_unit

  systemctl daemon-reload
  systemctl enable --now xray 2>&1 | tee -a "$LOG_FILE"
  sleep 1
  systemctl is-active --quiet xray || {
    journalctl -u xray -n 40 --no-pager 2>&1 | tee -a "$LOG_FILE" || true
    die "xray 服务未启动，请查看上方日志与 ${XRAY_CONFIG}"
  }
  ss -tlnp 2>/dev/null | grep -q ":${XRAY_PORT} " || log WARN "未在 ss 中看到 ${XRAY_PORT} 监听，请人工复核"

  render_nginx_conf
  local code=''
  code="$(curl -sS --max-time 15 --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}${XRAY_PATH}" 2>/dev/null || true)"
  log INFO "经 NGINX 访问 XHTTP 路径的 HTTP 状态码: ${code:-无响应}（非 404/301 即说明已转发到 Xray）"

  save_kv UUID "$UUID"
  save_kv XRAY_PORT "$XRAY_PORT"
  save_kv XRAY_PATH "$XRAY_PATH"
  log OK "步骤 5 完成：Xray 仅监听 127.0.0.1:${XRAY_PORT}，外部统一经 NGINX 443 访问"
  mark_done 5
  print_info
}

# -----------------------------------------------------------------------------
# 输出 / 查询
# -----------------------------------------------------------------------------
share_link() {
  local d="$1" u="$2" p="$3"
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=xhttp&mode=auto&host=%s&path=%%2F%s&alpn=h2%%2Chttp%%2F1.1#%s-xhttp' \
    "$u" "$d" "$d" "$d" "${p#/}" "$d"
}

print_info() {
  local d u p port cert=''
  d="$(get_conf DOMAIN 2>/dev/null || true)"
  u="$(get_conf UUID 2>/dev/null || true)"
  p="$(get_conf XRAY_PATH 2>/dev/null || true)"
  port="$(get_conf XRAY_PORT 2>/dev/null || true)"
  cert="$(get_conf CERT_FILE 2>/dev/null || true)"
  cat <<EOF

------------------------------ 连接信息 --------------------------------
域名 (SNI/Host) : ${d:-未配置}
UUID            : ${u:-未配置}
XHTTP 路径      : ${p:-未配置}
Xray 本地端口   : ${port:-未配置}（仅 127.0.0.1，不对外监听）
外部入口        : https://${d:-DOMAIN}${p:-/PATH}  (TCP 443)
协议            : VLESS + XHTTP(mode=auto) + TLS，flow 留空
分享链接        :
$(if [[ -n "$d" && -n "$u" && -n "$p" ]]; then share_link "$d" "$u" "$p"; else printf '%s' '（尚未部署步骤 5）'; fi)

证书            : ${cert:-未配置}
------------------------------------------------------------------------
EOF
  if [[ -n "$cert" && -s "$cert" ]]; then
    openssl x509 -in "$cert" -noout -dates 2>/dev/null || true
  fi
}

show_status() {
  local n
  printf '\n------------------------- 步骤完成状态 -------------------------\n'
  for n in 1 2 3 4 5; do
    if is_done "$n"; then
      printf '  步骤 %s: [完成] %s\n' "$n" "$(grep -m1 "^${n}=" "$STATE_FILE" | cut -d= -f2-)"
    else
      printf '  步骤 %s: [未执行]\n' "$n"
    fi
  done
  printf '  持久化配置: %s\n' "$CONF_FILE"
  printf '  最近备份  : %s\n' "$(cat "${BACKUP_ROOT}/LATEST" 2>/dev/null || printf '无')"
  printf '\n------------------------- 运行态 -------------------------\n'
  local svc
  for svc in nginx xray cron; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      printf '  %-8s: %s (enabled=%s)\n' "$svc" \
        "$(systemctl is-active "$svc" 2>/dev/null || printf 'unknown')" \
        "$(systemctl is-enabled "$svc" 2>/dev/null || printf 'unknown')"
    fi
  done
  printf '  监听端口:\n'
  ss -tlnp 2>/dev/null | grep -E ':(22|80|443|18080) ' || printf '    (无匹配)\n'
  printf '  acme.sh : %s\n' "$([[ -x "$ACME_BIN" ]] && printf '已安装' || printf '未安装')"
  printf '  Xray    : %s\n' "$("$XRAY_BIN" version 2>/dev/null | head -n1 || printf '未安装')"
  printf '  NGINX   : %s\n' "$(nginx -v 2>&1 || printf '未安装')"
  if command -v curl >/dev/null 2>&1; then verify_dual_stack; fi
  printf '\n'
}

health_check() {
  log STEP "========== 健康检查 =========="
  nginx -t 2>&1 || true
  systemctl is-active --quiet nginx && log OK "nginx: active" || log WARN "nginx: 未运行"
  systemctl is-active --quiet xray && log OK "xray: active" || log INFO "xray: 未运行（未执行步骤 5 时属正常）"
  systemctl is-active --quiet cron && log OK "cron: active" || log WARN "cron: 未运行（影响证书自动续期）"
  local code
  code="$(curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || true)"
  log INFO "HTTP  首页: ${code:-无响应}"
  local d
  d="$(get_conf DOMAIN 2>/dev/null || true)"
  if [[ -n "$d" && -s "$CERT_FILE" ]]; then
    code="$(curl -fsS --max-time 15 --resolve "${d}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${d}/" 2>/dev/null || true)"
    log INFO "HTTPS 首页: ${code:-无响应}"
    openssl x509 -checkend 2592000 -noout -in "$CERT_FILE" >/dev/null 2>&1 \
      && log OK "证书有效期 >30 天" || log WARN "证书缺失或将在 30 天内到期"
  fi
  if [[ -s "$XRAY_CONFIG" ]]; then jq empty "$XRAY_CONFIG" && log OK "Xray 配置 JSON 合法"; fi
  show_status
}

rollback_nginx() {
  local d=''
  d="$(cat "${BACKUP_ROOT}/LATEST" 2>/dev/null || true)"
  [[ -n "$d" && -d "$d" ]] || die "没有可用备份（${BACKUP_ROOT}/LATEST）"
  risk_note "回滚会覆盖 /etc/nginx 下被托管的文件，并移除 ${NGINX_CONF}；不会卸载 Xray、不会删除证书。"
  confirm "确认回滚到备份 ${d} ?" || { log WARN "已取消"; return 0; }
  if [[ -e "${d}/etc/nginx/conf.d/toolkit.conf" ]]; then
    cp -a -- "${d}/etc/nginx/conf.d/toolkit.conf" "$NGINX_CONF"
  else
    rm -f "$NGINX_CONF"
  fi
  restore_default_site "$d"
  if [[ -e "${d}${WEBROOT}/index.html" ]]; then
    cp -a -- "${d}${WEBROOT}/index.html" "${WEBROOT}/index.html"
  fi
  nginx -t 2>&1 | tee -a "$LOG_FILE" || die "回滚后 nginx -t 仍失败，请手动检查 /etc/nginx"
  systemctl reload nginx
  log OK "NGINX 配置已回滚到 ${d}"
}

# -----------------------------------------------------------------------------
# 依赖解析 / 执行
# -----------------------------------------------------------------------------
DEPS[2]="1"
DEPS[3]="1"
DEPS[4]="1 3"
DEPS[5]="1 3 4"

resolve_steps() {
  local -a requested=()
  local n d changed=1
  WANT=(0 0 0 0 0 0)
  if (( ALL )); then
    requested=(1 3 4 5)
  else
    IFS=',' read -r -a requested <<< "$STEPS_CSV"
    [[ ${#requested[@]} -gt 0 ]] || die "--step 需要一个步骤列表，例如 --step 1,2,5"
  fi
  # 显式 --with-warp 时追加可选步骤 2（重复编号无副作用，WANT 是集合）
  if (( WITH_WARP )); then requested+=(2); fi
  for n in "${requested[@]}"; do
    n="${n//[[:space:]]/}"
    [[ "$n" =~ ^[1-5]$ ]] || die "无效步骤编号: '${n}'（只允许 1-5）"
    WANT[10#$n]=1
  done
  # 不动点迭代补齐依赖
  while (( changed )); do
    changed=0
    for n in 1 2 3 4 5; do
      if (( WANT[n] )); then
        for d in ${DEPS[$n]:-}; do
          if (( ! WANT[d] )); then WANT[d]=1; changed=1; fi
        done
      fi
    done
  done
  PLAN=()
  for n in 1 2 3 4 5; do
    if (( WANT[n] )); then PLAN+=("$n"); fi
  done
  return 0
}

run_step() {
  case "$1" in
    1) step1_apt ;;
    2) step2_warp ;;
    3) step3_nginx ;;
    4) step4_acme ;;
    5) step5_xray ;;
  esac
}

print_plan() {
  local n
  log STEP "========== 执行计划（依赖已自动补齐） =========="
  for n in "${PLAN[@]}"; do
    case "$n" in
      1) printf '  1) 更新源 + 安装依赖 (mirror=%s)\n' "${MIRROR:-默认官方源}" ;;
      2) printf '  2) WARP 双栈 (mode=%s)\n' "$WARP_MODE" ;;
      3) printf '  3) NGINX 默认站点\n' ;;
      4) printf '  4) acme.sh 证书 (domain=%s email=%s)\n' "${DOMAIN:-<必填>}" "${ACME_EMAIL:-admin@DOMAIN}" ;;
      5) printf '  5) Xray VLESS-XHTTP (port=%s path=%s)\n' "$XRAY_PORT" "$XRAY_PATH" ;;
    esac
  done
  printf '  依赖已自动补齐；顺序固定为 1 -> 2(可选) -> 3 -> 4 -> 5\n'
  if [[ ${PLAN[*]:-} == *4* || ${PLAN[*]:-} == *5* ]]; then
    [[ -n "$DOMAIN" ]] || log WARN "计划包含步骤 4/5，但未提供 --domain，正式运行时会报错"
  fi
  log INFO "提示：XHTTP 路径默认随机生成；如需固定请加 --xray-path /yourpath，部署后会持久化"
}

execute_plan() {
  local n
  log INFO "本次执行步骤: ${PLAN[*]}"
  for n in "${PLAN[@]}"; do
    run_step "$n" || die "步骤 ${n} 执行失败，后续步骤已中止；已完成步骤不受影响"
  done
  log OK "全部步骤执行完毕"
  log INFO "建议执行: bash ${0##*/} --check 做一次完整健康检查"
  log INFO "回滚 NGINX: bash ${0##*/} --rollback-nginx（备份 ${BACKUP_DIR}）"
}

# -----------------------------------------------------------------------------
# 交互菜单
# -----------------------------------------------------------------------------
draw_menu() {
  local marks='' n
  for n in 1 2 3 4 5; do is_done "$n" && marks="${marks}${n}√ " || marks="${marks}${n}· "; done
  cat <<EOF

==================== Debian 13 多功能部署工具 v${SCRIPT_VERSION} ====================
 步骤状态: ${marks}   (1 必选 / 2 可选 / 5→4→3→1)
 当前域名: ${DOMAIN:-<未设置>}    当前备份: ${BACKUP_DIR}

  1) 更新软件源并安装常用依赖            [必选]
  2) 安装 WARP，开启 IPv4/IPv6 双栈     [可选，⚠️ 改路由]
  3) 安装并配置 NGINX 默认站点
  4) 安装 acme.sh 并申请/部署证书        [自动补齐 1,3]
  5) 安装 Xray-core (VLESS-XHTTP)       [自动补齐 1,3,4]
  ------------------------------------------------------------------
  a) 一键全流程            1 → 3 → 4 → 5
  b) 一键全流程 + WARP     1 → 2 → 3 → 4 → 5
  s) 查看步骤状态           c) 健康检查
  i) 查看连接信息/分享链接   r) 回滚 NGINX 配置
  0) 退出
======================================================================
EOF
}

menu_loop() {
  [[ -t 0 ]] || die "当前不是交互终端；请使用参数模式，例如 --all --domain example.com --yes"
  local choice=''
  while true; do
    draw_menu
    read -r -p "请选择 [0-5/a/b/s/c/i/r]: " choice || { printf '\n'; return 0; }
    ALL=0; WITH_WARP=0; STEPS_CSV=''
    case "$choice" in
      1|2|3|4|5) STEPS_CSV="$choice" ;;
      a|A) ALL=1 ;;
      b|B) ALL=1; WITH_WARP=1 ;;
      s|S) show_status; read -r -p "按回车返回菜单..." _ || true; continue ;;
      c|C) health_check; read -r -p "按回车返回菜单..." _ || true; continue ;;
      i|I) print_info; read -r -p "按回车返回菜单..." _ || true; continue ;;
      r|R) rollback_nginx; read -r -p "按回车返回菜单..." _ || true; continue ;;
      0|q|Q|quit|exit) log INFO "已退出"; return 0 ;;
      *) log WARN "无效选择: ${choice}"; continue ;;
    esac
    resolve_steps
    printf '\n'
    print_plan
    if confirm "按上述计划执行?"; then
      execute_plan || true
    else
      log WARN "已取消本次执行"
    fi
    read -r -p "按回车返回菜单..." _ || true
  done
}

# -----------------------------------------------------------------------------
# 用法
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
deb13-toolkit.sh v${SCRIPT_VERSION} — Debian 13 多功能部署工具

运行方式一（交互式，默认）:
  bash deb13-toolkit.sh
  bash deb13-toolkit.sh --menu

运行方式二（参数式）:
  bash deb13-toolkit.sh --step 1
  bash deb13-toolkit.sh --step 2 --warp-mode d --yes
  bash deb13-toolkit.sh --step 4 --domain example.com --yes
  bash deb13-toolkit.sh --all --domain example.com --yes
  bash deb13-toolkit.sh --all --with-warp --domain example.com --yes
  bash deb13-toolkit.sh --plan --step 5 --domain example.com   # 只预览依赖链

参数模式选项:
  --menu                 进入交互菜单
  --all                  必选全流程 1→3→4→5
  --step LIST            指定步骤，逗号分隔，如 1,2 / 5；自动补齐依赖并按序执行
  --with-warp            附带可选步骤 2（可与 --all 或 --step 组合）
  --domain DOMAIN        证书/HTTPS/Xray 使用域名（步骤 4/5 必需）
  --email EMAIL          acme.sh 账户邮箱（默认 admin@DOMAIN）
  --mirror URL           可选换源，如 https://mirrors.tuna.tsinghua.edu.cn
  --warp-mode d|4|6      WARP 模式，默认 d（双栈）
  --xray-port N          Xray 本地监听端口，默认 18080（仅 127.0.0.1）
  --xray-path PATH       XHTTP 路径，默认随机 /x<16位hex>
  --uuid UUID            自定义 UUID，默认随机生成
  --xray-version TAG     指定 Xray 版本，默认 latest
  --force-cert           --issue 加 --force 强制重签证书
  --no-redirect          部署证书后不把 HTTP 301 跳到 HTTPS
  --yes, -y              非交互自动确认（含 WARP 风险提示）
  --force                跳过 Debian 13 版本校验
  --plan                 只打印执行计划与依赖链，不做任何修改
  --status               查看步骤完成状态与运行态
  --check                健康检查（nginx -t / 服务 / HTTP(S) / 证书 / 双栈）
  --info                 打印 Xray 连接参数与分享链接
  --rollback-nginx       从最近一次备份回滚 NGINX 配置
  -h, --help             显示本帮助

依赖关系:
  5 需要 4；4 需要 3；3 需要 1；2 可选但同样需要 1；1 为必选。
  例：--step 5 实际执行 1 → 3 → 4 → 5；--step 2 实际执行 1 → 2。

重要路径:
  日志      ${LOG_FILE}
  配置      ${CONF_FILE}
  状态      ${STATE_FILE}
  备份      ${BACKUP_ROOT}/<时间戳>/（LATEST 指向最近一次）
  NGINX     ${NGINX_CONF}（唯一托管文件）
  证书      ${CERT_FILE} / ${KEY_FILE}
  Xray      ${XRAY_CONFIG} / ${XRAY_UNIT}

⚠️ 风险提醒:
  * 步骤 2 会改默认路由，可能造成 SSH 断连，务必先准备云控制台。
  * 步骤 4/5 要求公网 TCP 80/443 可达、域名解析到本机；云安全组需自行放行。
  * 所有被覆盖的配置都会先备份；nginx -t 失败会自动回滚托管配置。
EOF
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
main() {
  # 默认值（可由 --domain 等参数或持久化配置覆盖）
  MODE='menu'
  ALL=0
  WITH_WARP=0
  STEPS_CSV=''
  ASSUME_YES=0
  FORCE_OS=0
  FORCE_CERT=0
  PLAN_ONLY=0
  REDIRECT_HTTP=1
  MIRROR=''
  WARP_MODE="$(get_conf WARP_MODE 2>/dev/null || printf 'd')"
  XRAY_VERSION='latest'
  DOMAIN="$(get_conf DOMAIN 2>/dev/null || printf '')"
  ACME_EMAIL="$(get_conf ACME_EMAIL 2>/dev/null || printf '')"
  UUID="$(get_conf UUID 2>/dev/null || printf '')"
  XRAY_PORT="$(get_conf XRAY_PORT 2>/dev/null || printf '18080')"
  XRAY_PATH="$(get_conf XRAY_PATH 2>/dev/null || printf '')"
  CERT_FILE="$(get_conf CERT_FILE 2>/dev/null || printf '/etc/nginx/ssl/server.crt')"
  KEY_FILE="$(get_conf KEY_FILE 2>/dev/null || printf '/etc/nginx/ssl/server.key')"
  PLAN=()
  WANT=(0 0 0 0 0 0)
  declare -a DEPS=()
  DEPS[2]="1"; DEPS[3]="1"; DEPS[4]="1 3"; DEPS[5]="1 3 4"

  while (( $# )); do
    case "$1" in
      --menu|-m)            MODE='menu'; shift ;;
      --all)                MODE='run'; ALL=1; shift ;;
      --step)               [[ $# -ge 2 ]] || die "--step 缺少参数"; MODE='run'; STEPS_CSV="$2"; shift 2 ;;
      --with-warp)          WITH_WARP=1; shift ;;
      --domain)             [[ $# -ge 2 ]] || die "--domain 缺少参数"; DOMAIN="$2"; shift 2 ;;
      --email)              [[ $# -ge 2 ]] || die "--email 缺少参数"; ACME_EMAIL="$2"; shift 2 ;;
      --mirror)             [[ $# -ge 2 ]] || die "--mirror 缺少参数"; MIRROR="${2%/}"; shift 2 ;;
      --warp-mode)          [[ $# -ge 2 ]] || die "--warp-mode 缺少参数"; WARP_MODE="$2"; shift 2 ;;
      --xray-port)          [[ $# -ge 2 ]] || die "--xray-port 缺少参数"; XRAY_PORT="$2"; shift 2 ;;
      --xray-path)          [[ $# -ge 2 ]] || die "--xray-path 缺少参数"; XRAY_PATH="$2"; shift 2 ;;
      --uuid)               [[ $# -ge 2 ]] || die "--uuid 缺少参数"; UUID="$2"; shift 2 ;;
      --xray-version)       [[ $# -ge 2 ]] || die "--xray-version 缺少参数"; XRAY_VERSION="$2"; shift 2 ;;
      --force-cert)         FORCE_CERT=1; shift ;;
      --no-redirect)        REDIRECT_HTTP=0; shift ;;
      --yes|-y)             ASSUME_YES=1; shift ;;
      --force)              FORCE_OS=1; shift ;;
      --plan)               PLAN_ONLY=1; shift ;;
      --status)             MODE='status'; shift ;;
      --check)              MODE='check'; shift ;;
      --info)               MODE='info'; shift ;;
      --rollback-nginx)     MODE='rollback'; shift ;;
      -h|--help|help)       usage; exit 0 ;;
      *)                    die "未知参数: $1（见 --help）" ;;
    esac
  done

  # 参数合法性
  [[ "$WARP_MODE" =~ ^(d|4|6)$ ]] || die "--warp-mode 只能是 d|4|6"
  validate_port "$XRAY_PORT" || die "Xray 端口不合法: ${XRAY_PORT}"
  if [[ -n "$MIRROR" ]]; then
    [[ "$MIRROR" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._/-]*)?$ ]] \
      || die "--mirror 格式不合法（示例 https://mirrors.tuna.tsinghua.edu.cn）"
  fi
  if [[ -n "$DOMAIN" ]]; then validate_domain "$DOMAIN" || die "域名格式不合法: ${DOMAIN}"; fi
  if [[ -z "$XRAY_PATH" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      XRAY_PATH="/x$(openssl rand -hex 8)"
    else
      XRAY_PATH="/x$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
  fi
  validate_xray_path "$XRAY_PATH" || die "XHTTP 路径不合法: ${XRAY_PATH}"
  if [[ "$CERT_FILE" == "/etc/nginx/ssl/server.crt" && -n "$DOMAIN" ]]; then
    CERT_FILE="/etc/nginx/ssl/${DOMAIN}.crt"
    KEY_FILE="/etc/nginx/ssl/${DOMAIN}.key"
  fi

  # --plan 单独使用（未指定 --step/--all）时，默认预览必选全流程；预览不做系统检查与修改
  if (( PLAN_ONLY )); then
    [[ "$MODE" == "menu" ]] && { MODE='run'; ALL=1; }
    if [[ "$MODE" == "run" ]]; then
      resolve_steps
      print_plan
      log INFO "--plan 模式：仅预览，未修改任何系统配置"
      return 0
    fi
  fi

  preflight

  case "$MODE" in
    menu)     menu_loop ;;
    status)   show_status ;;
    check)    health_check ;;
    info)     print_info ;;
    rollback) rollback_nginx ;;
    run)
      resolve_steps
      print_plan
      if confirm "确认开始执行上述步骤?"; then execute_plan; else log WARN "已取消"; fi
      ;;
  esac
}

# 允许 source 本文件以做函数级测试；直接执行时才进入 main
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
