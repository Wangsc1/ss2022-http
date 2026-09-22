#!/usr/bin/env bash
# SS2022 + simple-obfs HTTP 一键管理脚本
# 仅提供一种模式：Shadowsocks 2022 + simple-obfs HTTP 伪装。
set -Eeuo pipefail
umask 077

readonly APP="ss2022-http"
readonly CONF_DIR="/etc/${APP}"
readonly CONF_FILE="${CONF_DIR}/config.json"
readonly ENV_FILE="${CONF_DIR}/server.env"
readonly SUB_DIR="${CONF_DIR}/subscribe"
readonly SS_BIN="/usr/local/bin/ssserver"
readonly OBFS_BIN="/usr/local/bin/obfs-server"
readonly SS_SERVICE="ss2022-http.service"
readonly OBFS_SERVICE="ss2022-http-obfs.service"
readonly LEGACY_SS_SERVICE="ss-rust.service"
readonly LEGACY_OBFS_SERVICE="ss-rust-obfs.service"
readonly METHOD="2022-blake3-aes-128-gcm"
readonly DEFAULT_HOST="www.microsoft.com"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行"; }
need_systemd() { command -v systemctl >/dev/null || die "仅支持使用 systemd 的 Linux"; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

pkg_init() {
  if command -v apt-get >/dev/null; then PKG=apt
  elif command -v dnf >/dev/null; then PKG=dnf
  elif command -v yum >/dev/null; then PKG=yum
  else die "仅支持 Debian/Ubuntu、RHEL/CentOS/Alma/Rocky Linux"; fi
}

install_deps() {
  info "安装运行与编译依赖…"
  case "$PKG" in
    apt)
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ca-certificates curl openssl xz-utils tar git build-essential autoconf automake \
        libtool pkg-config libssl-dev libev-dev libc-ares-dev >/dev/null
      ;;
    dnf|yum)
      "$PKG" install -y -q ca-certificates curl openssl xz tar git gcc gcc-c++ make \
        autoconf automake libtool pkgconf-pkg-config openssl-devel libev-devel \
        c-ares-devel >/dev/null
      ;;
  esac
}

arch_target() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64-unknown-linux-gnu ;;
    aarch64|arm64) echo aarch64-unknown-linux-gnu ;;
    armv7l|armv7) echo armv7-unknown-linux-gnueabihf ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

fetch_public_ip() {
  local ip=''
  ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ip=$(curl -4fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "无法获取公网 IPv4"
  printf '%s\n' "$ip"
}

random_port() {
  local min=$1 max=$2 p
  while :; do
    p=$((min + RANDOM % (max - min + 1)))
    if ! command -v ss >/dev/null || ! ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${p}$"; then echo "$p"; return; fi
  done
}

generate_key() { openssl rand -base64 16; }

install_ss_rust() {
  local target latest url tmp sum_url
  target=$(arch_target)
  latest=$(curl -fsSL --max-time 15 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
  [[ $latest =~ ^v[0-9] ]] || die "无法获取 shadowsocks-rust 最新版本"
  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.${target}.tar.xz"
  sum_url="${url}.sha256"
  tmp=$(mktemp -d); trap 'rm -rf "${tmp:-}"' RETURN
  info "安装 shadowsocks-rust ${latest} (${target})…"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 "$url" -o "$tmp/ss.tar.xz"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "$sum_url" -o "$tmp/ss.tar.xz.sha256"
  (cd "$tmp" && sed -E 's#([ *])[^ ]+$#\1ss.tar.xz#' ss.tar.xz.sha256 | sha256sum -c - >/dev/null) \
    || die "shadowsocks-rust 校验失败"
  tar -xJf "$tmp/ss.tar.xz" -C "$tmp"
  [[ -x "$tmp/ssserver" ]] || die "发布包中未找到 ssserver"
  install -m 0755 "$tmp/ssserver" "$SS_BIN"
  "$SS_BIN" --version >/dev/null || die "ssserver 安装验证失败"
}

install_simple_obfs() {
  local tmp log
  tmp=$(mktemp -d); trap 'rm -rf "${tmp:-}"' RETURN
  log="$tmp/build.log"
  info "编译安装 simple-obfs HTTP 插件…"
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/shadowsocks/simple-obfs.git "$tmp/src" >>"$log" 2>&1 \
    || die "下载 simple-obfs 失败"
  [[ -f "$tmp/src/libcork/Makefile.am" ]] || die "simple-obfs 子模块 libcork 缺失"
  (cd "$tmp/src" && ./autogen.sh && ./configure --disable-documentation \
    && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && make install) >>"$log" 2>&1 \
    || { tail -n 25 "$log" >&2; die "simple-obfs 编译失败"; }
  if command -v ldconfig >/dev/null; then ldconfig || true; fi
  [[ -x "$OBFS_BIN" ]] || die "obfs-server 安装验证失败"
}

quote_env() { printf '%q' "$1"; }
load_env() {
  [[ -r "$ENV_FILE" ]] || die "尚未安装，请先运行：bash $0 install"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

write_config() {
  local port=$1 backend=$2 key=$3 host=$4 udp=$5
  mkdir -p "$CONF_DIR" "$SUB_DIR"
  chmod 700 "$CONF_DIR" "$SUB_DIR"
  cat >"$ENV_FILE" <<EOF
PUBLIC_PORT=$(quote_env "$port")
BACKEND_PORT=$(quote_env "$backend")
PASSWORD=$(quote_env "$key")
OBFS_HOST=$(quote_env "$host")
ENABLE_UDP=$(quote_env "$udp")
EOF
  chmod 600 "$ENV_FILE"
  PORT="$port" BACKEND="$backend" KEY="$key" UDP="$udp" python3 - "$CONF_FILE" <<'PY'
import json, os, sys
p=int(os.environ['PORT']); b=int(os.environ['BACKEND']); udp=os.environ['UDP']=='1'
k=os.environ['KEY']; servers=[{'server':'127.0.0.1','server_port':b,'method':'2022-blake3-aes-128-gcm','password':k,'timeout':300,'mode':'tcp_only'}]
if udp:
    servers.append({'server':'0.0.0.0','server_port':p,'method':'2022-blake3-aes-128-gcm','password':k,'timeout':300,'mode':'udp_only'})
with open(sys.argv[1], 'w') as f: json.dump({'servers':servers}, f, indent=2)
PY
  chmod 600 "$CONF_FILE"
}

write_services() {
  load_env
  cat >"/etc/systemd/system/$SS_SERVICE" <<EOF
[Unit]
Description=Shadowsocks 2022 Server for HTTP Obfuscation
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_BIN} -c ${CONF_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=${CONF_DIR}

[Install]
WantedBy=multi-user.target
EOF
  cat >"/etc/systemd/system/$OBFS_SERVICE" <<EOF
[Unit]
Description=simple-obfs HTTP Frontend for Shadowsocks 2022
After=network-online.target ${SS_SERVICE}
Requires=${SS_SERVICE}

[Service]
Type=simple
ExecStart=${OBFS_BIN} -s 0.0.0.0 -p ${PUBLIC_PORT} -r 127.0.0.1:${BACKEND_PORT} --obfs http --obfs-host ${OBFS_HOST} --http-method GET
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

open_firewall() {
  load_env
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PUBLIC_PORT}/tcp" >/dev/null
    [[ $ENABLE_UDP == 1 ]] && ufw allow "${PUBLIC_PORT}/udp" >/dev/null
    info "已放行 UFW 端口 ${PUBLIC_PORT}/tcp$([[ $ENABLE_UDP == 1 ]] && echo ',udp')"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PUBLIC_PORT}/tcp" >/dev/null
    [[ $ENABLE_UDP == 1 ]] && firewall-cmd --permanent --add-port="${PUBLIC_PORT}/udp" >/dev/null
    firewall-cmd --reload >/dev/null
    info "已放行 firewalld 端口 ${PUBLIC_PORT}/tcp$([[ $ENABLE_UDP == 1 ]] && echo ',udp')"
  else
    warn "未检测到启用中的 UFW/firewalld；请在云防火墙放行 ${PUBLIC_PORT}/TCP$([[ $ENABLE_UDP == 1 ]] && echo ' 和 UDP')"
  fi
}

urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
generate_outputs() {
  load_env
  local ip auth plugin uri udp=false
  mkdir -p "$SUB_DIR"; chmod 700 "$SUB_DIR"
  ip=$(fetch_public_ip)
  auth=$(printf '%s:%s' "$METHOD" "$PASSWORD" | base64 | tr -d '\n')
  plugin=$(urlencode "obfs-local;obfs=http;obfs-host=${OBFS_HOST}")
  uri="ss://${auth}@${ip}:${PUBLIC_PORT}/?plugin=${plugin}#SS2022-HTTP"
  [[ $ENABLE_UDP == 1 ]] && udp=true
  printf '%s\n' "$uri" >"$SUB_DIR/uri.txt"
  printf '%s\n' "$uri" | base64 | tr -d '\n' >"$SUB_DIR/subscribe.txt"; printf '\n' >>"$SUB_DIR/subscribe.txt"
  cat >"$SUB_DIR/surge.conf" <<EOF
[Proxy]
SS2022-HTTP = ss, ${ip}, ${PUBLIC_PORT}, encrypt-method=${METHOD}, password=${PASSWORD}, obfs=http, obfs-host=${OBFS_HOST}, udp-relay=${udp}
EOF
  cat >"$SUB_DIR/clash.yaml" <<EOF
proxies:
  - name: SS2022-HTTP
    type: ss
    server: ${ip}
    port: ${PUBLIC_PORT}
    cipher: ${METHOD}
    password: "${PASSWORD}"
    udp: ${udp}
    plugin: obfs
    plugin-opts:
      mode: http
      host: ${OBFS_HOST}
EOF
  chmod 600 "$SUB_DIR"/*
}

show_info() {
  load_env; generate_outputs
  local ip state udp_label=关闭
  ip=$(fetch_public_ip); state=$(systemctl is-active "$SS_SERVICE" 2>/dev/null || true)
  [[ $ENABLE_UDP == 1 ]] && udp_label=开启
  printf '\n%b══ SS2022 + HTTP obfs ══%b\n' "$CYAN" "$NC"
  printf '状态: %s\n地址: %s\n端口: %s\n加密: %s\n密码: %s\nHTTP Host: %s\nUDP: %s\n\n' \
    "$state" "$ip" "$PUBLIC_PORT" "$METHOD" "$PASSWORD" "$OBFS_HOST" "$udp_label"
  printf '%bSS 链接：%b\n' "$GREEN" "$NC"; cat "$SUB_DIR/uri.txt"
  printf '\n文件：%s\n' "$SUB_DIR"
}

prompt_value() { local __v=$1 text=$2 def=$3 val; read -r -p "$text [$def]: " val; printf -v "$__v" '%s' "${val:-$def}"; }
install_all() {
  pkg_init; install_deps; install_ss_rust; install_simple_obfs
  if systemctl is-active --quiet "$LEGACY_SS_SERVICE" 2>/dev/null || systemctl is-active --quiet "$LEGACY_OBFS_SERVICE" 2>/dev/null; then
    warn "检测到旧版 ss-rust 服务，将停用以避免端口或配置冲突"
    systemctl disable --now "$LEGACY_OBFS_SERVICE" "$LEGACY_SS_SERVICE" 2>/dev/null || true
  fi
  local port backend key host udp_answer udp=1
  prompt_value port "对外端口" "$(random_port 20000 39999)"
  valid_port "$port" || die "无效对外端口：$port"
  while :; do backend=$(random_port 40000 59999); [[ $backend != "$port" ]] && break; done
  prompt_value backend "后端本地端口" "$backend"
  if ! valid_port "$backend" || [[ $backend == "$port" ]]; then
    die "后端端口无效或与对外端口相同"
  fi
  prompt_value key "SS2022 密钥" "$(generate_key)"
  [[ $(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c) -eq 16 ]] || die "AES-128-GCM 密钥必须是 16 字节 Base64（建议直接回车自动生成）"
  prompt_value host "HTTP 伪装 Host" "$DEFAULT_HOST"
  [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || die "Host 格式无效"
  read -r -p "启用 UDP？[Y/n]: " udp_answer; [[ ${udp_answer:-Y} =~ ^[Yy]$ ]] || udp=0
  write_config "$port" "$backend" "$key" "$host" "$udp"
  write_services
  systemctl enable --now "$SS_SERVICE" "$OBFS_SERVICE" >/dev/null
  sleep 1
  systemctl is-active --quiet "$SS_SERVICE" || { journalctl -u "$SS_SERVICE" -n 20 --no-pager; die "SS 服务启动失败"; }
  systemctl is-active --quiet "$OBFS_SERVICE" || { journalctl -u "$OBFS_SERVICE" -n 20 --no-pager; die "obfs 服务启动失败"; }
  open_firewall; show_info
}

reset_key() {
  load_env; local key=${1:-$(generate_key)}
  [[ $(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c) -eq 16 ]] || die "密钥格式无效"
  write_config "$PUBLIC_PORT" "$BACKEND_PORT" "$key" "$OBFS_HOST" "$ENABLE_UDP"
  systemctl restart "$SS_SERVICE" "$OBFS_SERVICE"; show_info
}

change_port() {
  load_env; local port=${1:-}
  [[ -n $port ]] || read -r -p "新对外端口: " port
  valid_port "$port" || die "端口无效"
  write_config "$port" "$BACKEND_PORT" "$PASSWORD" "$OBFS_HOST" "$ENABLE_UDP"
  write_services; systemctl restart "$SS_SERVICE" "$OBFS_SERVICE"; open_firewall; show_info
}

uninstall_all() {
  local answer=${1:-}
  [[ $answer == --yes ]] || { read -r -p "确认卸载 SS2022 + HTTP？输入 yes: " answer; [[ $answer == yes ]] || exit 0; }
  systemctl disable --now "$OBFS_SERVICE" "$SS_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$OBFS_SERVICE" "/etc/systemd/system/$SS_SERVICE" "$SS_BIN" "$OBFS_BIN" /usr/local/bin/obfs-local
  rm -rf "$CONF_DIR"; systemctl daemon-reload
  info "已卸载（编译依赖未自动删除）"
}

usage() {
  cat <<EOF
用法: bash $0 [命令]
  install          安装/重新安装（唯一模式：SS2022 + HTTP obfs）
  info|show        查看节点与链接
  port [端口]      修改对外端口
  reset [密钥]     重置密钥
  start|stop|restart
  logs             查看日志
  uninstall        卸载
EOF
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; return ;;
  esac
  need_root; need_systemd
  case "${1:-}" in
    install) install_all ;;
    info|show) show_info ;;
    port) change_port "${2:-}" ;;
    reset) reset_key "${2:-}" ;;
    start|stop|restart) systemctl "$1" "$SS_SERVICE" "$OBFS_SERVICE"; systemctl --no-pager --full status "$SS_SERVICE" "$OBFS_SERVICE" || true ;;
    logs) journalctl -u "$SS_SERVICE" -u "$OBFS_SERVICE" -n 100 --no-pager ;;
    uninstall|remove) uninstall_all "${2:-}" ;;
    '')
      if [[ -f $ENV_FILE ]]; then show_info; else install_all; fi
      ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"
