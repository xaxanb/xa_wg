#!/bin/bash

# ============================================================
# WireGuard 安装管理脚本 (单文件)
# 支持自动/手动安装、Web UI、流量限制、备份恢复、CLI 管理
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 品牌信息（base64 存储，运行时解码；仅本重制版自有标识）
_xa_dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }
XA_NAME="$(_xa_dec 'eGEg6YeN5Yi254mI')"
XA_REPO="$(_xa_dec 'aHR0cHM6Ly9naXRodWIuY29tL3hheGFuYi94YV93Zw==')"
XA_TITLE="$(_xa_dec 'V2lyZUd1YXJkIOWuieijheiEmuacrCDCtyB4YSDph43liLbniYg=')"

WG_CONF="/etc/wireguard/wg0.conf"
WG_DIR="/etc/wireguard"
WEB_DIR="/opt/wireguard-web"
WGD_BIN="/usr/local/bin/wgd"
ENV_FILE="$WEB_DIR/.env"

auto=0; assume_yes=0; add_client=0; list_clients=0
remove_client=0; show_client_qr=0; remove_wg=0
public_ip=""; server_addr=""; server_port=""; first_client_name=""
unsanitized_client=""; client=""; dns=""; dns1=""; dns2=""
ip=""; port="53"; os=""; os_version=""; ip6=""
firewall=""; use_dns_name=0; deploy_web=0
web_username=""; web_password=""; web_expose=0; web_disabled=0
web_port=5666; trust_proxy=0
rollback_files=()

exiterr() { echo "错误：$1" >&2; exit 1; }
exiterr2() { exiterr "apt-get install 命令执行失败。"; }
exiterr3() { exiterr "yum install 命令执行失败。"; }
exiterr4() { exiterr "zypper install 命令执行失败。"; }

# ---------- 回滚 ----------
rollback_cleanup() {
  echo "检测到错误，正在回滚..." >&2
  for f in "${rollback_files[@]}"; do
    [ -e "$f" ] && rm -rf "$f" 2>/dev/null
  done
  rm -f /etc/wireguard/wg.sh
  systemctl disable --now wg-quick@wg0.service 2>/dev/null
  systemctl disable --now wg-web.service 2>/dev/null
  rm -f /etc/systemd/system/wg-web.service
  restore_dns 2>/dev/null
  echo "回滚完成" >&2
}

# ---------- 校验函数 ----------
check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_pvt_ip() {
  IPP_REGEX='^(10|127|172\.(1[6-9]|2[0-9]|3[0-1])|192\.168|169\.254)\.'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IPP_REGEX"
}

check_dns_name() {
  FQDN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$FQDN_REGEX"
}

check_root() {
  if [ "$(id -u)" != 0 ]; then
    exiterr "此安装脚本必须以 root 用户身份运行。请尝试执行 sudo bash $0"
  fi
}

check_shell() {
  if readlink /proc/$$/exe | grep -q "dash"; then
    exiterr "此安装脚本需使用 bash 执行，不可使用 sh。"
  fi
}

check_kernel() {
  if [[ $(uname -r | cut -d "." -f 1) -eq 2 ]]; then
    exiterr "当前系统运行的内核版本过旧，与本安装脚本不兼容。"
  fi
}

check_os() {
  if grep -qs "ubuntu" /etc/os-release; then
    os="ubuntu"
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
  elif [[ -e /etc/debian_version ]]; then
    os="debian"
    os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
  elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
    os="centos"
    os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
  elif [[ -e /etc/fedora-release ]]; then
    os="fedora"
    os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
  elif [[ -e /etc/SUSE-brand && "$(head -1 /etc/SUSE-brand)" == "openSUSE" ]]; then
    os="openSUSE"
    os_version=$(tail -1 /etc/SUSE-brand | grep -oE '[0-9\\.]+')
  else
    exiterr "此安装脚本似乎运行在不支持的操作系统上。"
  fi
}

check_os_ver() {
  if [[ "$os" == "ubuntu" && "$os_version" -lt 2004 ]]; then
    exiterr "本安装脚本要求 Ubuntu 20.04 或更高版本。"
  fi
  if [[ "$os" == "debian" && "$os_version" -lt 11 ]]; then
    exiterr "本安装脚本要求 Debian 11 或更高版本。"
  fi
  if [[ "$os" == "centos" && "$os_version" -lt 8 ]]; then
    exiterr "本安装脚本要求 CentOS 8 或更高版本。"
  fi
}

check_container() {
  if systemd-detect-virt -cq 2>/dev/null; then
    exiterr "当前系统运行在容器环境中，本安装脚本不支持容器。"
  fi
}

check_nftables() {
  if [ "$os" = "centos" ]; then
    if grep -qs "hwdsl2 VPN脚本" /etc/sysconfig/nftables.conf 2>/dev/null ||
      systemctl is-active --quiet nftables 2>/dev/null; then
      exiterr "当前系统已启用 nftables，本安装脚本不支持。"
    fi
  fi
}

set_client_name() {
  client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<<"$unsanitized_client" | cut -c-15)
}

# ---------- 端口冲突检测 ----------
# ---------- DNS 工具 ----------
DNS_BAK="/etc/wireguard/.resolv.conf.orig"
DNS_BAK_DONE=0

resolve_ok() {
  getent hosts mirrors.cloud.aliyuncs.com >/dev/null 2>&1 ||
    getent hosts deb.debian.org >/dev/null 2>&1 ||
    getent hosts archive.ubuntu.com >/dev/null 2>&1 ||
    getent hosts www.google.com >/dev/null 2>&1
}

write_static_dns() {
  local rescued="$1"
  chattr -i /etc/resolv.conf 2>/dev/null
  rm -f /etc/resolv.conf
  {
    [ -n "$rescued" ] && printf '%s\n' "$rescued" | awk 'NF{print "nameserver "$0}'
    echo "nameserver 100.100.2.148"   # 阿里云内网 DNS（非阿里云无效但不影响）
    echo "nameserver 223.5.5.5"
    echo "nameserver 223.6.6.6"
    echo "nameserver 1.1.1.1"
  } > /etc/resolv.conf
}

# 备份原始 DNS 配置（仅一次）
backup_dns() {
  [ "$DNS_BAK_DONE" = 1 ] && return 0
  mkdir -p /etc/wireguard
  if [ ! -f "$DNS_BAK" ]; then
    {
      # 记录 resolv.conf 类型（符号链接目标）
      if [ -L /etc/resolv.conf ]; then
        echo "# SYMLINK=$(readlink /etc/resolv.conf)"
      fi
      # 记录真实可用的上游 DNS（排除 stub 127.0.0.53）
      local src="/etc/resolv.conf"
      [ -r /run/systemd/resolve/resolv.conf ] && src="/run/systemd/resolve/resolv.conf"
      awk '/^nameserver/{print $2}' "$src" 2>/dev/null | grep -v '127.0.0.53' | awk '{print "nameserver "$0}'
      awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | grep -v '127.0.0.53' | awk '{print "nameserver "$0}'
    } | awk '!seen[$0]++ || /^#/' > "$DNS_BAK" 2>/dev/null
    # 去掉注释行后若为空，说明没救到上游
    if [ "$(grep -c '^nameserver' "$DNS_BAK" 2>/dev/null)" = 0 ]; then
      echo "nameserver 223.5.5.5" >> "$DNS_BAK"
      echo "nameserver 223.6.6.6" >> "$DNS_BAK"
    fi
  fi
  DNS_BAK_DONE=1
}

# 还原 DNS 配置（卸载 / 回滚时）
restore_dns() {
  # 移除我们写入的 drop-in，恢复 resolved 的 53 监听
  if [ -f /etc/systemd/resolved.conf.d/99-wireguard.conf ]; then
    rm -f /etc/systemd/resolved.conf.d/99-wireguard.conf
    rmdir /etc/systemd/resolved.conf.d 2>/dev/null
    systemctl restart systemd-resolved 2>/dev/null
    sleep 1
  fi
  # 恢复原始 resolv.conf
  if [ -f "$DNS_BAK" ]; then
    chattr -i /etc/resolv.conf 2>/dev/null
    rm -f /etc/resolv.conf
    cp "$DNS_BAK" /etc/resolv.conf 2>/dev/null || true
  fi
  # 还原后若 DNS 仍不可用，写入可用的静态 DNS 兜底
  if ! resolve_ok; then
    local cur=""
    cur=$(awk '/^nameserver/{print $2}' "$DNS_BAK" 2>/dev/null | grep -v '127.0.0.53')
    write_static_dns "$cur"
  fi
}

# 释放 53 端口（不破坏系统 DNS）
release_port_53() {
  backup_dns

  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    # 收集 resolved 的真实上游 DNS（含阿里云内网 100.100.2.148）
    local upstream=""
    [ -r /run/systemd/resolve/resolv.conf ] && \
      upstream=$(awk '/^nameserver/{print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null | grep -v '127.0.0.53')

    # 禁用 stub listener（resolved 继续运行，仅不再监听 53）
    echo "禁用 systemd-resolved 的 53 端口监听..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/99-wireguard.conf <<'RESOLVEDEOF'
[Resolve]
DNSStubListener=no
RESOLVEDEOF
    systemctl restart systemd-resolved 2>/dev/null
    sleep 1

    # resolv.conf 指向 resolved 的真实上游
    if [ -r /run/systemd/resolve/resolv.conf ]; then
      chattr -i /etc/resolv.conf 2>/dev/null
      rm -f /etc/resolv.conf
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi

    # 验证 DNS，失败则静态兜底
    if ! resolve_ok; then
      echo "DNS 解析异常，写入静态 DNS..."
      write_static_dns "$upstream"
    fi
  else
    # resolved 未运行：直接确保 resolv.conf 可用
    if ! resolve_ok; then
      local cur=""
      cur=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | grep -v '127.0.0.53')
      write_static_dns "$cur"
    fi
  fi
}

check_port_conflict() {
  local p=${1:-53}
  ss -tuln 2>/dev/null | grep -q ":$p " || return 0

  echo "检测到端口 $p 已被占用，正在处理..."
  if ss -tulnp 2>/dev/null | grep ":${p} " | grep -q "systemd-resolve"; then
    release_port_53
  else
    echo "端口 $p 被非 systemd-resolved 程序占用："
    ss -tulnp 2>/dev/null | grep ":${p} " || true
    if [ "$auto" = 0 ]; then
      printf "是否继续安装（WireGuard 可能无法监听该端口）？[y/N] "
      read -r ans
      case $ans in [yY]*) : ;; *) echo "已中止。"; exit 1 ;; esac
    else
      echo "警告：继续安装，WireGuard 可能启动失败。"
    fi
  fi

  if ss -tuln 2>/dev/null | grep -q ":$p "; then
    echo "警告：端口 $p 仍被占用，请手动检查。"
  fi
}

# 安装/更新前确保 DNS 可用
ensure_dns() {
  if ! resolve_ok; then
    echo "DNS 解析异常，尝试修复..."
    local cur=""
    cur=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | grep -v '127.0.0.53')
    write_static_dns "$cur"
    if resolve_ok; then
      echo "DNS 已修复。"
    else
      echo "警告：DNS 仍不可用，软件包安装可能失败。"
    fi
  fi
}

# ---------- DNS ----------
# ---------- 区域识别（决定使用国内/海外 DNS） ----------
detect_region() {
  local geo=""
  # 1) 云厂商元数据（内网地址，不走公网 DNS，最可靠）
  geo=$(curl -s --max-time 3 http://100.100.100.200/latest/meta-data/region-id 2>/dev/null)                      # 阿里云
  [ -z "$geo" ] && geo=$(curl -s --max-time 3 http://metadata.tencentyun.com/latest/meta-data/placement/region 2>/dev/null)  # 腾讯云
  [ -z "$geo" ] && geo=$(curl -s --max-time 3 -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/region 2>/dev/null)  # GCP
  [ -z "$geo" ] && geo=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)          # 通用/AWS 兼容
  printf '%s' "$geo" | tr -d '\r\n'
}

overseas_reachable() {
  # 真实访问海外站点（非 ICMP ping），任一成功即视为可访问海外
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://www.google.com/generate_204 2>/dev/null)
  [ "$code" = "204" ] && return 0
  curl -s -o /dev/null --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null && return 0
  curl -s -o /dev/null --max-time 5 https://www.youtube.com 2>/dev/null && return 0
  return 1
}

# 判定是否为中国大陆：返回 0=大陆, 1=非大陆
is_mainland() {
  local g="${1:-}"
  [ -z "$g" ] && return 1
  # 先排除港澳台等地区（cn-hongkong 含 cn-，必须优先判定）
  case "$g" in
    *[Hh]ong[Kk]ong*|*hongkong*|*[Mm]acao*|*macau*|*[Tt]aiwan*|*[Tt]aipei*|*asia-east*|*asia-southeast*) return 1 ;;
  esac
  # 再判定大陆
  case "$g" in
    CN|cn|*"cn-"*|*[Cc]hina*|*[Bb]eijing*|*[Ss]hanghai*|*[Gg]uangzhou*|*[Ss]henzhen*|*[Hh]angzhou*|*[Cc]hengdu*) return 0 ;;
  esac
  return 1
}

auto_detect_dns() {
  dns=""
  local region; region=$(detect_region)

  if [ -n "$region" ]; then
    if is_mainland "$region"; then
      dns="223.5.5.5"
      echo "检测到中国大陆环境（$region），DNS 设置为 223.5.5.5（阿里云）"
    else
      dns="1.1.1.1"
      echo "检测到海外环境（$region），DNS 设置为 1.1.1.1"
    fi
  elif overseas_reachable; then
    dns="1.1.1.1"
    echo "可访问海外站点，DNS 设置为 1.1.1.1"
  else
    dns="223.5.5.5"
    echo "无法访问海外站点，DNS 设置为 223.5.5.5（阿里云）"
  fi

  # 兜底：系统现有 DNS
  if [ -z "$dns" ]; then
    dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | grep -v '127.0.0.53' | head -2 | paste -sd', ')
    [ -n "$dns" ] && echo "使用系统 DNS：$dns"
  fi
  [ -z "$dns" ] && echo "DNS 自动检测失败"
}

select_dns() {
  auto_detect_dns
  if [ -z "$dns" ]; then
    echo "无法自动检测 DNS 服务器，请手动输入。"
    read -rp "首选 DNS 服务器（例如 223.5.5.5）：" dns1
    until check_ip "$dns1"; do
      echo "无效。"; read -rp "首选 DNS 服务器：" dns1
    done
    read -rp "备用 DNS 服务器（按回车键跳过）：" dns2
    until [ -z "$dns2" ] || check_ip "$dns2"; do
      echo "无效。"; read -rp "备用 DNS 服务器：" dns2
    done
    if [ -n "$dns2" ]; then dns="$dns1, $dns2"; else dns="$dns1"; fi
  fi
}

# ---------- 显示 ----------
show_header() { printf '\n%s\n%s\n' "$XA_TITLE" "$XA_REPO"; }
show_header2() { printf '\n%s\n\n' "欢迎使用 WireGuard 服务器安装脚本！"; }
show_header3() { printf '\n%s\n%s\n%s\n' "版权所有 (c) 2022-2025 林松" "版权所有 (c) 2020-2023 Nyr" "$XA_NAME · $XA_REPO"; }

show_usage() {
  if [ -n "$1" ]; then echo "错误：$1" >&2; fi
  show_header; show_header3
  cat 1>&2 <<EOF

用法：bash $0 [选项]

选项：
  --addclient [名称]      添加新客户端
  --dns1 [IP]             首选 DNS（可选）
  --dns2 [IP]             备用 DNS（可选）
  --listclients           列出所有客户端
  --removeclient [名称]   删除客户端
  --showclientqr [名称]   显示客户端 QR 码
  --uninstall             卸载 WireGuard
  -y, --yes               默认回答"是"
  -h, --help              显示帮助

安装选项：
  --auto                  自动安装（端口53，自动 DNS，部署并暴露 Web UI）
  --auto --<端口>         自动安装并指定监听端口（例如 --auto --7777）
  --serveraddr [DNS/IP]   服务器地址
  --port [端口]           监听端口（默认：53）
  --clientname [名称]     第一个客户端名称（默认：client）
  --dns1 [IP]             首选 DNS
  --dns2 [IP]             备用 DNS
  --no-web                不部署 Web UI
  --web-port [端口]       Web UI/API 端口（默认：5666）
  --trust-proxy           信任反向代理的 X-Forwarded-For（仅反代后使用）
EOF
  exit 1
}

# ---------- 参数解析 ----------
parse_args() {
  while [ "$#" -gt 0 ]; do
    case $1 in
    --auto) auto=1; shift ;;
    --addclient) add_client=1; unsanitized_client="$2"; shift 2 ;;
    --listclients) list_clients=1; shift ;;
    --removeclient) remove_client=1; unsanitized_client="$2"; shift 2 ;;
    --showclientqr) show_client_qr=1; unsanitized_client="$2"; shift 2 ;;
    --uninstall) remove_wg=1; shift ;;
    --serveraddr) server_addr="$2"; shift 2 ;;
    --port) server_port="$2"; shift 2 ;;
    --clientname) first_client_name="$2"; shift 2 ;;
    --dns1) dns1="$2"; shift 2 ;;
    --dns2) dns2="$2"; shift 2 ;;
    --no-web) deploy_web=0; web_disabled=1; shift ;;
    --web-port) web_port="$2"; shift 2 ;;
    --trust-proxy) trust_proxy=1; shift ;;
    --do-backup) do_backup "$2"; exit 0 ;;
    --do-restore) do_restore "$2"; exit 0 ;;
    -y|--yes) assume_yes=1; shift ;;
    -h|--help) show_usage ;;
    --[0-9][0-9]*) server_port="${1#--}"; shift ;;
    *) show_usage "未知参数：$1" ;;
    esac
  done
}

check_args() {
  if [ "$auto" != 0 ] && [ -e "$WG_CONF" ]; then
    show_usage "参数无效 '--auto'。此服务器已配置 WireGuard，不可重复执行自动安装。"
  fi
  if [ "$((add_client + list_clients + remove_client + show_client_qr))" -gt 1 ]; then
    show_usage "参数无效。仅可指定以下参数之一：--addclient、--listclients、--removeclient 或 --showclientqr。"
  fi
  if [ "$remove_wg" = 1 ]; then
    if [ "$((add_client + list_clients + remove_client + show_client_qr + auto))" -gt 0 ]; then
      show_usage "参数无效。--uninstall 不可与其他参数同时指定。"
    fi
  fi
  if [ ! -e "$WG_CONF" ]; then
    st_text="需先配置 WireGuard，然后才能"
    [ "$add_client" = 1 ] && exiterr "$st_text 添加客户端。"
    [ "$list_clients" = 1 ] && exiterr "$st_text 列出客户端。"
    [ "$remove_client" = 1 ] && exiterr "$st_text 删除客户端。"
    [ "$show_client_qr" = 1 ] && exiterr "$st_text 显示客户端 QR 码。"
    [ "$remove_wg" = 1 ] && exiterr "无法卸载 WireGuard，因为此服务器尚未配置 WireGuard。"
  fi
  if [ "$((add_client + remove_client + show_client_qr))" = 1 ] && [ -n "$first_client_name" ]; then
    show_usage "参数无效。--clientname 仅可在安装 WireGuard 时指定。"
  fi
  if [ -n "$server_addr" ] || [ -n "$server_port" ] || [ -n "$first_client_name" ]; then
    if [ -e "$WG_CONF" ]; then
      show_usage "参数无效。此服务器已配置 WireGuard，不可重复指定服务器信息。"
    elif [ "$auto" = 0 ]; then
      show_usage "参数无效。使用这些参数时必须指定 --auto（自动安装模式）。"
    fi
  fi
  if [ "$add_client" = 1 ]; then
    set_client_name
    if [ -z "$client" ]; then
      exiterr "客户端名称无效。仅可使用单个单词，特殊字符仅支持 - 和 _。"
    elif grep -q "^# BEGIN_PEER $client$" "$WG_CONF"; then
      exiterr "$client：名称无效。该客户端已存在。"
    fi
  fi
  if [ "$remove_client" = 1 ] || [ "$show_client_qr" = 1 ]; then
    set_client_name
    if [ -z "$client" ] || ! grep -q "^# BEGIN_PEER $client$" "$WG_CONF"; then
      exiterr "客户端名称无效，或该客户端不存在。"
    fi
  fi
  if [ -n "$server_addr" ] && { ! check_dns_name "$server_addr" && ! check_ip "$server_addr"; }; then
    exiterr "服务器地址无效。必须是完全限定域名（FQDN）或 IPv4 地址。"
  fi
  if [ -n "$first_client_name" ]; then
    unsanitized_client="$first_client_name"
    set_client_name
    if [ -z "$client" ]; then
      exiterr "客户端名称无效。仅可使用单个单词，特殊字符仅支持 - 和 _。"
    fi
  fi
  if [ -n "$server_port" ]; then
    if [[ ! "$server_port" =~ ^[0-9]+$ || "$server_port" -lt 1 || "$server_port" -gt 65535 ]]; then
      exiterr "端口无效。必须是 1-65535 之间的整数。"
    fi
  fi
  if [ -n "$web_port" ]; then
    if [[ ! "$web_port" =~ ^[0-9]+$ || "$web_port" -lt 1 || "$web_port" -gt 65535 ]]; then
      exiterr "Web 端口无效。必须是 1-65535 之间的整数。"
    fi
  fi
  if [ -n "$dns1" ]; then
    if [ -e "$WG_CONF" ] && [ "$add_client" = 0 ]; then
      show_usage "参数无效。自定义 DNS 服务器仅可在安装 WireGuard 或添加客户端时指定。"
    fi
  fi
  if { [ -n "$dns1" ] && ! check_ip "$dns1"; } || { [ -n "$dns2" ] && ! check_ip "$dns2"; }; then
    exiterr "DNS 服务器地址无效。"
  fi
  if [ -z "$dns1" ] && [ -n "$dns2" ]; then
    show_usage "DNS 参数无效。指定 --dns2 前必须先指定 --dns1。"
  fi
  if [ -n "$dns1" ] && [ -n "$dns2" ]; then
    dns="$dns1, $dns2"
  elif [ -n "$dns1" ]; then
    dns="$dns1"
  fi
}

# ---------- IP 检测 ----------
find_public_ip() {
  get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<<"$(wget -T 10 -t 1 -4qO- http://ipv4.icanhazip.com 2>/dev/null || curl -m 10 -4Ls http://ipv4.icanhazip.com 2>/dev/null)")
  if ! check_ip "$get_public_ip"; then
    get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<<"$(wget -T 10 -t 1 -4qO- http://ip1.dynupdate.no-ip.com 2>/dev/null || curl -m 10 -4Ls http://ip1.dynupdate.no-ip.com 2>/dev/null)")
  fi
}

detect_ip() {
  if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
    ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
  else
    ip=$(ip -4 route get 1 2>/dev/null | sed 's/ uid .*//' | awk '{print $NF;exit}' 2>/dev/null)
    if ! check_ip "$ip"; then
      find_public_ip; ip_match=0
      if [ -n "$get_public_ip" ]; then
        ip_list=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
        while IFS= read -r line; do [ "$line" = "$get_public_ip" ] && ip_match=1 && ip="$line"; done <<<"$ip_list"
      fi
      if [ "$ip_match" = 0 ]; then
        if [ "$auto" = 0 ]; then
          echo; echo "请选择要使用的 IPv4 地址："
          num_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
          ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
          read -rp "IPv4 地址 [1]：" ip_num
          until [[ -z "$ip_num" || "$ip_num" =~ ^[0-9]+$ && "$ip_num" -le "$num_of_ip" ]]; do
            echo "$ip_num：选择无效。"; read -rp "IPv4 地址 [1]：" ip_num
          done
          [[ -z "$ip_num" ]] && ip_num=1
        else
          ip_num=1
        fi
        ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ip_num"p)
      fi
    fi
  fi
  if ! check_ip "$ip"; then
    echo "错误：无法检测该服务器的 IP 地址。" >&2
    echo "已中止。未修改任何系统配置。" >&2; exit 1
  fi
}

check_nat_ip() {
  if check_pvt_ip "$ip"; then
    find_public_ip
    if ! check_ip "$get_public_ip"; then
      if [ "$auto" = 0 ]; then
        echo; echo "该服务器位于 NAT 之后，请输入其公网 IPv4 地址："
        read -rp "公网 IPv4 地址：" public_ip
        until check_ip "$public_ip"; do echo "输入无效。"; read -rp "公网 IPv4 地址：" public_ip; done
      else
        echo "错误：无法检测该服务器的公网 IP。" >&2
        echo "已中止。未修改任何系统配置。" >&2; exit 1
      fi
    else
      public_ip="$get_public_ip"
    fi
  fi
}

enter_server_address() {
  echo; printf "是否使用 DNS 名称（如 vpn.example.com）连接？[y/N] "; read -r response
  case $response in [yY][eE][sS]|[yY]) use_dns_name=1; echo ;; *) use_dns_name=0 ;; esac
  if [ "$use_dns_name" = 1 ]; then
    read -rp "请输入该 VPN 服务器的 DNS 名称：" server_addr_i
    until check_dns_name "$server_addr_i"; do
      echo "DNS 名称无效。必须输入完全域名（FQDN）。"
      read -rp "请输入该 VPN 服务器的 DNS 名称：" server_addr_i
    done
    ip="$server_addr_i"
    echo "注意：请确保 DNS 名称 '$ip' 已正确解析到该服务器的 IPv4 地址。"
  else
    detect_ip
    check_nat_ip
  fi
}

detect_ipv6() {
  ip6=""
  if [[ $(ip -6 addr | grep -c 'inet6 [23]') -ne 0 ]]; then
    ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n 1p)
  fi
}

select_port() {
  if [ "$auto" = 0 ]; then
    echo; echo "请选择 WireGuard 的监听端口："
    read -rp "端口 [53]：" port
    until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; do
      echo "$port：端口无效。"; read -rp "端口 [53]：" port
    done
    [[ -z "$port" ]] && port=53
  else
    [ -n "$server_port" ] && port="$server_port" || port=53
  fi
}

enter_first_client_name() {
  if [ "$auto" = 0 ]; then
    echo; echo "请为第一个客户端输入名称："
    read -rp "名称 [client]：" unsanitized_client
    set_client_name
    [[ -z "$client" ]] && client=client
  else
    if [ -n "$first_client_name" ]; then
      unsanitized_client="$first_client_name"
      set_client_name
    else
      client=client
    fi
  fi
}

# ---------- 备份 ----------
do_backup() {
  local path="${1:-/root/wg-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  local tmp="/tmp/wg-bk-$$"
  mkdir -p "$tmp/wireguard" "$tmp/clients" "$tmp/web/data" "$tmp/systemd"
  [ -f "$WG_CONF" ] && cp "$WG_CONF" "$tmp/wireguard/"
  local wgdir="/etc/wireguard"
  for f in "$wgdir"/wg*.conf; do [ -f "$f" ] && cp "$f" "$tmp/wireguard/"; done
  for f in /root/*.conf; do [ -f "$f" ] && cp "$f" "$tmp/clients/"; done
  [ -f "$ENV_FILE" ] && cp "$ENV_FILE" "$tmp/web/.env"
  [ -d "$WEB_DIR/data" ] && for f in "$WEB_DIR/data"/*; do [ -f "$f" ] && cp "$f" "$tmp/web/data/"; done
  for u in /etc/systemd/system/wg-web.service /etc/systemd/system/wg-limiter.service /etc/systemd/system/wg-limiter.timer /etc/systemd/system/wg-health.service /etc/systemd/system/wg-health.timer; do
    [ -f "$u" ] && cp "$u" "$tmp/systemd/"
  done
  [ -f "$WEB_DIR/scripts/wg-limiter.sh" ] && { mkdir -p "$tmp/web/scripts"; cp "$WEB_DIR/scripts/wg-limiter.sh" "$tmp/web/scripts/"; }
  tar czf "$path" -C "$tmp" . 2>/dev/null
  rm -rf "$tmp"
  if [ -f "$path" ]; then echo "备份完成：$path"; return 0; else echo "备份失败"; return 1; fi
}

do_restore() {
  local path="$1"
  [ ! -f "$path" ] && echo "备份文件不存在" && return 1
  local tmp="/tmp/wg-rs-$$"
  mkdir -p "$tmp"
  tar xzf "$path" -C "$tmp" 2>/dev/null
  systemctl stop wg-quick@wg0 2>/dev/null
  # 兼容旧格式（wg/ + confs/）与新格式（wireguard/ + clients/）
  if [ -f "$tmp/wireguard/wg0.conf" ]; then
    cp "$tmp/wireguard/"wg*.conf /etc/wireguard/ 2>/dev/null
  elif [ -f "$tmp/wg/wg0.conf" ]; then
    cp "$tmp/wg/wg0.conf" "$WG_CONF"
  fi
  chmod 600 /etc/wireguard/wg*.conf 2>/dev/null
  if [ -d "$tmp/clients" ]; then
    for f in "$tmp"/clients/*.conf; do [ -f "$f" ] && cp "$f" /root/; done
  elif [ -d "$tmp/confs" ]; then
    for f in "$tmp"/confs/*.conf; do [ -f "$f" ] && cp "$f" /root/; done
  fi
  # 恢复 Web 配置与数据
  [ -f "$tmp/web/.env" ] && { cp "$tmp/web/.env" "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
  if [ -d "$tmp/web/data" ]; then
    mkdir -p "$WEB_DIR/data"
    for f in "$tmp"/web/data/*; do [ -f "$f" ] && cp "$f" "$WEB_DIR/data/"; done
  fi
  [ -f "$tmp/web/scripts/wg-limiter.sh" ] && { mkdir -p "$WEB_DIR/scripts"; cp "$tmp/web/scripts/wg-limiter.sh" "$WEB_DIR/scripts/"; chmod +x "$WEB_DIR/scripts/wg-limiter.sh"; }
  rm -rf "$tmp"
  systemctl start wg-quick@wg0 2>/dev/null
  echo "恢复完成"
}

# ---------- Python 依赖与解释器 ----------
PYTHON_BIN=""

# 探测具备 flask/werkzeug/qrcode 的解释器（优先系统 python，systemd 友好）
detect_python() {
  local cands="/usr/bin/python3 /usr/local/bin/python3"
  local p
  p=$(command -v python3 2>/dev/null) && cands="$cands $p"
  for py in $cands; do
    [ -x "$py" ] || continue
    if "$py" -c 'import flask, werkzeug, qrcode' 2>/dev/null; then
      echo "$py"; return 0
    fi
  done
  return 1
}

install_python_deps() {
  echo "安装 Python 依赖库..."
  local pipmirror="https://pypi.tuna.tsinghua.edu.cn/simple"

  if [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    (set -x; apt-get -yqq -o Dpkg::Options::=--force-confold update >/dev/null 2>&1 || true
     apt-get -yqq -o Dpkg::Options::=--force-confold install python3 python3-flask python3-werkzeug python3-qrcode python3-pil >/dev/null 2>&1) || true
    # 若 dpkg 处于半配置状态，先修复再重试
    if ! detect_python >/dev/null 2>&1; then
      dpkg --configure -a --force-confold >/dev/null 2>&1 || true
      apt-get -yqq -o Dpkg::Options::=--force-confold install python3-flask python3-werkzeug python3-qrcode python3-pil >/dev/null 2>&1 || true
    fi
  elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
    if [[ "$os" == "fedora" ]]; then
      (set -x; dnf install -y python3 python3-flask python3-werkzeug python3-qrcode python3-pillow >/dev/null 2>&1) || true
    else
      (set -x; yum -y -q install python3 python3-flask python3-werkzeug python3-qrcode python3-pillow >/dev/null 2>&1) || true
    fi
  elif [[ "$os" == "openSUSE" ]]; then
    (set -x; zypper install -y python3 python3-Flask python3-Werkzeug python3-qrcode python3-Pillow >/dev/null 2>&1) || true
  fi

  # 若 apt/yum 未成功提供依赖，降级 pip
  if ! detect_python >/dev/null 2>&1; then
    echo "尝试通过 pip 安装 Flask 依赖..."
    local py="/usr/bin/python3"
    [ -x "$py" ] || py=$(command -v python3 2>/dev/null)
    if [ -n "$py" ]; then
      "$py" -m pip install --break-system-packages -i "$pipmirror" flask werkzeug 'qrcode[pil]' >/dev/null 2>&1 || \
      "$py" -m pip install --break-system-packages flask werkzeug 'qrcode[pil]' >/dev/null 2>&1 || \
      "$py" -m pip install -i "$pipmirror" flask werkzeug 'qrcode[pil]' >/dev/null 2>&1 || \
      "$py" -m pip install flask werkzeug 'qrcode[pil]' >/dev/null 2>&1 || \
      echo "警告：pip 安装 Python 依赖失败"
    fi
    # 清理 pip 缓存的二进制使 import 立即生效
    hash -r 2>/dev/null || true
  fi
}

# apt 安装失败时切换镜像源重试
apt_mirror_fallback() {
  local lists="/etc/apt/sources.list"
  [ -f "$lists" ] || lists=""
  local files="$lists"
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && files="$files $f"
  done
  [ -z "$files" ] && return 1

  local changed=0
  for f in $files; do
    if grep -q 'mirrors.cloud.aliyuncs.com' "$f" 2>/dev/null; then
      sed -i 's|mirrors.cloud.aliyuncs.com|mirrors.aliyun.com|g' "$f" && changed=1
    fi
    if grep -q 'mirrorlist.centos.org\|mirrors.aliyun.com' "$f" 2>/dev/null; then
      :
    fi
  done
  [ "$changed" = 1 ] || return 1
  echo "已切换阿里云公网镜像源，重试 apt-get update..."
  apt-get -yqq update >/dev/null 2>&1
}

# ---------- 部署 Web UI ----------
deploy_web_ui() {
  mkdir -p "$WEB_DIR/templates" "$WEB_DIR/static" "$WEB_DIR/scripts" "$WEB_DIR/data"
  rollback_files+=("$WEB_DIR")

  # 始终使用内嵌内容，保证 wg.sh 为单文件部署
  cat > "$WEB_DIR/app.py" << 'EMBEDPYEOF'
#!/usr/bin/env python3
import os, re, io, subprocess, json, time, tarfile, zipfile, glob, secrets
from pathlib import Path
from datetime import datetime, timedelta
from flask import Flask, render_template, request, jsonify, session, redirect, url_for, send_file, abort, Response, make_response
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
ENV_FILE = Path("/opt/wireguard-web/.env")
WG_CONF = Path("/etc/wireguard/wg0.conf")
DATA_DIR = Path("/opt/wireguard-web/data")
TRAFFIC_FILE = DATA_DIR / "traffic.json"
STATUS_FILE = DATA_DIR / "status.json"
SERVER_LIMIT_FILE = DATA_DIR / "server_limit.json"
IDENTITIES_FILE = DATA_DIR / "identities.json"
QOS_FILE = DATA_DIR / "qos.json"
API_VERSION = "1.0"
MBPS_FACTOR = 8388608   # 1 MB/s = 1024*1024 字节/秒 = 8388608 bit/s

login_attempts = {}
_pub_cache = {"ip": None, "ts": 0}
_env_cache = {"mtime": None, "data": {}}
WEB_PORT = 5666

def load_env(force=False):
    """读取 .env（按 mtime 缓存，避免每请求读盘）"""
    try:
        mt = ENV_FILE.stat().st_mtime if ENV_FILE.exists() else None
    except Exception:
        mt = None
    if not force and _env_cache["mtime"] == mt and _env_cache["data"]:
        return _env_cache["data"]
    data = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    _env_cache["mtime"] = mt; _env_cache["data"] = data
    return data

env = load_env()
app.secret_key = env.get("SECRET_KEY", os.urandom(24).hex())
try: WEB_PORT = int(env.get("WEB_PORT", "5666"))
except Exception: WEB_PORT = 5666
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)

def client_ip():
    """真实客户端 IP。仅当 TRUST_PROXY=1 时才信任 X-Forwarded-For，防伪造。"""
    trust = (load_env().get("TRUST_PROXY", "0") == "1")
    if trust:
        fwd = request.headers.get("X-Forwarded-For", "")
        if fwd:
            for part in fwd.split(","):
                cand = part.strip()
                if cand:
                    return cand
        real = request.headers.get("X-Real-IP", "").strip()
        if real:
            return real
    return request.remote_addr or "unknown"

@app.before_request
def _csrf_origin_check():
    """状态变更请求校验同源（Origin/Referer 存在时必须匹配 Host）"""
    if request.method in ("POST", "PUT", "DELETE", "PATCH"):
        host = request.host
        origin = request.headers.get("Origin")
        referer = request.headers.get("Referer")
        src = origin or referer
        if src:
            from urllib.parse import urlparse
            try: netloc = urlparse(src).netloc
            except Exception: netloc = ""
            if netloc and netloc != host:
                return jsonify({"error": "跨站请求被拒绝"}), 403

def is_authenticated():
    return session.get("authenticated", False)

# ---------- API v1 认证层（管理员 token / 客户端订阅 token / Cookie） ----------
def _client_tokens():
    """返回 {token: name} 映射，仅取合法 32 位十六进制 token"""
    out = {}
    for cp in parse_conf_peers():
        t = (cp.get("token") or "").strip()
        if t and re.match(r'^[a-f0-9]{32}$', t):
            out[t] = cp["name"]
    return out

def bearer_token():
    """从 Authorization 头或 identity 参数取值"""
    h = request.headers.get("Authorization", "")
    if h.startswith("Bearer "):
        return h[7:].strip()
    return (request.args.get("token", "") or "").strip()

def resolve_identity():
    """返回 (role, name, raw_token)；未认证时为 (None, None, None)"""
    if is_authenticated():
        return "admin", session.get("username", "admin"), None
    tok = bearer_token()
    if not tok:
        return None, None, None
    admin_token = (load_env().get("ADMIN_TOKEN") or "").strip()
    if admin_token and secrets.compare_digest(tok, admin_token):
        return "admin", "admin", tok
    name = _client_tokens().get(tok)
    if name:
        return "client", name, tok
    return None, None, None

def identity_id():
    """通信身份 ID：优先请求头，兼容查询参数"""
    iid = (request.headers.get("X-Identity-Id") or request.args.get("identity") or "").strip()
    return iid[:64]

def load_identities():
    if IDENTITIES_FILE.exists():
        try: return json.loads(IDENTITIES_FILE.read_text())
        except Exception: return {}
    return {}

def save_identities(d):
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        IDENTITIES_FILE.write_text(json.dumps(d, ensure_ascii=False))
        os.chmod(IDENTITIES_FILE, 0o600)
    except Exception:
        pass

def touch_identity(token, name):
    """登记客户端 token 使用的身份 ID；同 token 多身份 → 审计告警"""
    iid = identity_id()
    if not iid or not token:
        return
    d = load_identities()
    rec = d.setdefault(token, {})
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if iid in rec:
        rec[iid]["last_seen"] = now
        rec[iid]["count"] = int(rec[iid].get("count", 0)) + 1
    else:
        rec[iid] = {"first_seen": now, "last_seen": now, "count": 1}
        rec[iid]["name"] = name
        if len(rec) > 1:
            append_audit("疑似 token 泄露", f"{name}: {len(rec)} 个身份使用同一 token（新身份 {iid}）",
                         request.remote_addr or "")
    save_identities(d)

def api_error(msg, code=400):
    return jsonify({"error": msg}), code

def require_admin(fn):
    import functools
    @functools.wraps(fn)
    def wrapper(*a, **k):
        role, name, tok = resolve_identity()
        if role is None:
            return api_error("未认证", 401)
        if role != "admin":
            return api_error("权限不足：需要管理员令牌", 403)
        return fn(*a, **k)
    return wrapper

def require_self_or_admin(fn):
    """自助接口：客户端只能访问自己；管理员可通过 ?name= 指定目标"""
    import functools
    @functools.wraps(fn)
    def wrapper(*a, **k):
        role, name, tok = resolve_identity()
        if role is None:
            return api_error("未认证", 401)
        if role == "client":
            if tok:
                touch_identity(tok, name)
            return fn(name=name, **k)
        # admin
        target = (request.args.get("name") or "").strip()
        return fn(name=target, **k)
    return wrapper

def run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return r.stdout.strip(), r.stderr.strip(), r.returncode
    except Exception as e:
        return "", str(e), -1

def fmt_bytes(b):
    if b >= 1099511627776: return f"{b/1099511627776:.2f} TiB"
    if b >= 1073741824: return f"{b/1073741824:.2f} GiB"
    if b >= 1048576: return f"{b/1048576:.1f} MiB"
    if b >= 1024: return f"{b/1024:.1f} KiB"
    return f"{b} B"

def check_rate_limit(key):
    now = datetime.now()
    # 定期清理过期条目
    for k in list(login_attempts.keys()):
        if now - login_attempts[k]["first"] > timedelta(minutes=5):
            login_attempts.pop(k, None)
    if key in login_attempts:
        if login_attempts[key]["count"] >= 5:
            wait = 300 - int((now - login_attempts[key]["first"]).total_seconds())
            return False, max(0, wait)
        return True, 0
    return True, 0

def rate_key(username):
    """限流键：客户端 IP + 用户名，避免反代下所有人共用一个桶"""
    return f"{client_ip()}|{(username or '').strip().lower()}"

def get_wg_status():
    out, _, _ = run(["wg", "show", "wg0"])
    return out

def public_ip():
    now = time.time()
    if _pub_cache["ip"] and now - _pub_cache["ts"] < 300:
        return _pub_cache["ip"]
    pub, _, _ = run(["curl", "-s", "--max-time", "5", "http://ipv4.icanhazip.com"])
    if not pub:
        pub, _, _ = run(["curl", "-s", "--max-time", "5", "http://ip1.dynupdate.no-ip.com"])
    ip = pub.strip() or "未知"
    _pub_cache["ip"] = ip
    _pub_cache["ts"] = now
    return ip

def parse_traffic(s):
    if not s: return 0
    u = s.split()[-1].lower(); v = float(s.split()[0])
    if u == "kib": return int(v * 1024)
    if u == "mib": return int(v * 1048576)
    if u == "gib": return int(v * 1073741824)
    return int(v)

def load_status():
    """读取 limiter 写入的在线状态"""
    if STATUS_FILE.exists():
        try:
            return json.loads(STATUS_FILE.read_text())
        except Exception:
            return {}
    return {}

def load_qos():
    d = {"algo": "htb", "total_down": 0, "total_up": 0, "enabled": False}
    if QOS_FILE.exists():
        try:
            x = json.loads(QOS_FILE.read_text())
            d.update({k: x[k] for k in d if k in x})
        except Exception: pass
    if d["algo"] not in ("htb", "tbf"): d["algo"] = "htb"
    return d

def qos_apply():
    """调用 wg-qos.sh 重新下发限速规则"""
    script = "/opt/wireguard-web/scripts/wg-qos.sh"
    if Path(script).exists():
        run(["bash", script, "apply"])

def set_peer_rates(name, rates):
    """更新某 peer 的 # RATE_* 注释并下发（仅触碰传入的字段）"""
    if not WG_CONF.exists(): return False, "配置不存在"
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(name) + r"$", content, re.M):
        return False, "客户端不存在"
    want = {}
    for k in ("rate_down", "rate_up", "over_quota_rate"):
        if k in rates:
            try: want[k] = max(0, int(rates[k]))
            except Exception: pass
    if not want: return False, "无有效字段"
    lines = content.split("\n"); out = []; cur = None; seen = set()
    for ln in lines:
        m = re.match(r"^# BEGIN_PEER (.+)", ln)
        if m:
            cur = m.group(1); seen = set(); out.append(ln)
            if cur == name:
                for k, v in want.items():
                    out.append(f"# {k.upper()}={v}"); seen.add(k)
            continue
        if cur == name:
            mk = re.match(r"^# (RATE_DOWN|RATE_UP|OVER_QUOTA_RATE)=", ln)
            if mk:
                key = mk.group(1).lower()
                if key in want:
                    continue          # 由上方新增行替代
                out.append(ln); continue  # 未指定的字段原样保留
        if re.match(r"^# END_PEER", ln): cur = None
        out.append(ln)
    WG_CONF.write_text("\n".join(out))
    run(["chmod", "600", str(WG_CONF)])
    qos_apply()
    return True, "已更新"

def load_server_limit():
    cur = datetime.now().strftime("%Y-%m")
    if SERVER_LIMIT_FILE.exists():
        try:
            d = json.loads(SERVER_LIMIT_FILE.read_text())
            d.setdefault("limit", 0); d.setdefault("used", 0)
            d.setdefault("period", cur); d.setdefault("blocked", False)
            if d["period"] != cur:      # 跨月自动重置
                d["period"] = cur; d["used"] = 0; d["blocked"] = False
            return d
        except Exception:
            pass
    return {"limit": 0, "used": 0, "period": cur, "blocked": False}

AUDIT_FILE = DATA_DIR / "audit.log"
AUDIT_MAX = 500

def append_audit(action, detail="", ip=""):
    """记录审计日志（最多保留 AUDIT_MAX 条）"""
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        entry = json.dumps({
            "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "action": action, "detail": detail, "ip": ip
        }, ensure_ascii=False)
        lines = []
        if AUDIT_FILE.exists():
            try: lines = AUDIT_FILE.read_text().splitlines()
            except Exception: lines = []
        lines.append(entry)
        if len(lines) > AUDIT_MAX:
            lines = lines[-AUDIT_MAX:]
        AUDIT_FILE.write_text("\n".join(lines) + "\n")
    except Exception:
        pass

def read_audit(limit=100):
    if not AUDIT_FILE.exists(): return []
    try:
        lines = AUDIT_FILE.read_text().splitlines()
    except Exception:
        return []
    out = []
    for ln in lines[-limit:]:
        try: out.append(json.loads(ln))
        except Exception: pass
    out.reverse()
    return out

def sys_resources():
    """采集服务器资源：CPU/内存/磁盘/负载/运行时长"""
    info = {"cpu": 0.0, "mem_used": 0, "mem_total": 0, "mem_pct": 0.0,
            "disk_used": 0, "disk_total": 0, "disk_pct": 0.0,
            "load": [0.0, 0.0, 0.0], "uptime": 0, "cpu_count": 1}
    try:
        # CPU 使用率（两次采样间隔 0.2s）
        def read_cpu():
            parts = open("/proc/stat").readline().split()[1:]
            vals = list(map(int, parts))
            idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
            return sum(vals), idle
        t1, i1 = read_cpu(); time.sleep(0.2); t2, i2 = read_cpu()
        dt, di = t2 - t1, i2 - i1
        if dt > 0: info["cpu"] = round((1 - di / dt) * 100, 1)
    except Exception: pass
    try:
        mem = {}
        for ln in open("/proc/meminfo"):
            k, v = ln.split(":", 1)
            mem[k.strip()] = int(v.strip().split()[0]) * 1024
        total = mem.get("MemTotal", 0)
        avail = mem.get("MemAvailable", mem.get("MemFree", 0))
        info["mem_total"] = total; info["mem_used"] = total - avail
        if total > 0: info["mem_pct"] = round(info["mem_used"] / total * 100, 1)
    except Exception: pass
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize; free = st.f_bavail * st.f_frsize
        info["disk_total"] = total; info["disk_used"] = total - free
        if total > 0: info["disk_pct"] = round(info["disk_used"] / total * 100, 1)
    except Exception: pass
    try:
        info["load"] = [round(x, 2) for x in os.getloadavg()]
    except Exception: pass
    try:
        info["uptime"] = int(float(open("/proc/uptime").read().split()[0]))
    except Exception: pass
    try:
        import multiprocessing; info["cpu_count"] = multiprocessing.cpu_count()
    except Exception: pass
    return info

def parse_conf_peers():
    """解析 wg0.conf 中所有 peer 区块元数据"""
    peers = []
    if not WG_CONF.exists(): return peers
    section = None
    for line in WG_CONF.read_text().splitlines():
        m = re.match(r"^# BEGIN_PEER (.+)", line)
        if m:
            if section: peers.append(section)
            section = {"name": m.group(1), "ip": "", "disabled": False, "limit": 0,
                       "expire": "", "cycle_start": "", "used": 0, "cycle": "30d", "token": "", "pubkey": "",
                       "remark": "", "dns": "", "rate_down": 0, "rate_up": 0, "over_quota_rate": 0,
                       "throttled": False}
            continue
        if section is None: continue
        if "# DISABLED" in line: section["disabled"] = True
        m = re.match(r"\s*AllowedIPs\s*=\s*(\S+)", line)
        if m and not section["ip"]: section["ip"] = m.group(1).split(",")[0].strip()
        m = re.match(r"\s*PublicKey\s*=\s*(\S+)", line)
        if m: section["pubkey"] = m.group(1)
        m = re.match(r"^# TRAFFIC_LIMIT=(.*)", line)
        if m:
            try: section["limit"] = int(m.group(1))
            except Exception: pass
        m = re.match(r"^# EXPIRE=(.*)", line)
        if m: section["expire"] = m.group(1).strip()
        m = re.match(r"^# CYCLE_START=(.*)", line)
        if m: section["cycle_start"] = m.group(1).strip()
        m = re.match(r"^# TRAFFIC_USED=(.*)", line)
        if m:
            try: section["used"] = int(m.group(1))
            except Exception: pass
        m = re.match(r"^# RESET_CYCLE=(.*)", line)
        if m: section["cycle"] = m.group(1).strip() or "30d"
        m = re.match(r"^# REMARK=(.*)", line)
        if m: section["remark"] = m.group(1).strip()
        m = re.match(r"^# DNS=(.*)", line)
        if m: section["dns"] = m.group(1).strip()
        m = re.match(r"^# RATE_DOWN=(.*)", line)
        if m:
            try: section["rate_down"] = int(m.group(1))
            except Exception: pass
        m = re.match(r"^# RATE_UP=(.*)", line)
        if m:
            try: section["rate_up"] = int(m.group(1))
            except Exception: pass
        m = re.match(r"^# OVER_QUOTA_RATE=(.*)", line)
        if m:
            try: section["over_quota_rate"] = int(m.group(1))
            except Exception: pass
        if line.strip() == "# THROTTLED": section["throttled"] = True
        m = re.match(r"^# TOKEN=(.*)", line)
        if m: section["token"] = m.group(1).strip()
        m = re.match(r"^# END_PEER", line)
        if m: peers.append(section); section = None
    if section: peers.append(section)
    return peers

def _sanitize_dns(v):
    return re.sub(r'[^0-9a-fA-F:., ]', '', str(v or ''))[:120].strip()

def apply_peer_dns(lines, name, dns):
    """在指定 peer 块内设置 # DNS= 行（不存在则插入）。lines 为字符串列表。"""
    d = _sanitize_dns(dns)
    out = []; cur = None; in_block = False; done = False
    for ln in lines:
        m = re.match(r"^# BEGIN_PEER (.+)", ln)
        if m:
            cur = m.group(1); in_block = (cur == name)
            out.append(ln)
            if in_block:
                out.append(f"# DNS={d}"); done = True
            continue
        if re.match(r"^# END_PEER", ln):
            cur = None; in_block = False; out.append(ln); continue
        if in_block and ln.startswith("# DNS="):
            continue  # 由插入的新行替代
        out.append(ln)
    if done:
        # 同步更新客户端配置文件中的 DNS 行
        for p in [f"/root/{name}.conf", f"/home/{name}.conf"]:
            fp = Path(p)
            if fp.exists():
                try:
                    c = fp.read_text()
                    if d:
                        if re.search(r"(?m)^DNS\s*=", c):
                            c = re.sub(r"(?m)^DNS\s*=.*$", f"DNS = {d}", c)
                        else:
                            c = re.sub(r"(?m)^\[Interface\]", f"[Interface]\nDNS = {d}", c, count=1)
                    else:
                        c = re.sub(r"(?m)^DNS\s*=.*\n?", "", c)
                    fp.write_text(c); run(["chmod","600",p])
                except Exception: pass
    return out if done else lines

def rename_peer(old, new):
    """重命名客户端：conf 注释、客户端文件、traffic/status 数据。返回 (ok, msg)"""
    if not WG_CONF.exists(): return False, "配置不存在"
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(old) + r"$", content, re.M):
        return False, "客户端不存在"
    if re.search(r"^# BEGIN_PEER " + re.escape(new) + r"$", content, re.M):
        return False, "新名称已存在"
    content = re.sub(r"(?m)^# BEGIN_PEER " + re.escape(old) + r"$", f"# BEGIN_PEER {new}", content)
    content = re.sub(r"(?m)^# END_PEER " + re.escape(old) + r"$", f"# END_PEER {new}", content)
    WG_CONF.write_text(content)
    run(["chmod","600",str(WG_CONF)])
    # 客户端配置文件
    for d in ["/root", "/home"]:
        src = Path(f"{d}/{old}.conf"); dst = Path(f"{d}/{new}.conf")
        if src.exists():
            dst.write_text(src.read_text())
            run(["chmod","600",str(dst)])
            src.unlink()
    # traffic 数据
    oldtf = DATA_DIR / f"traffic_{old}.json"; newtf = DATA_DIR / f"traffic_{new}.json"
    if oldtf.exists():
        try:
            newtf.write_text(oldtf.read_text()); oldtf.unlink()
        except Exception: pass
    # status.json 键
    try:
        st = load_status()
        if old in st: st[new] = st.pop(old)
        STATUS_FILE.write_text(json.dumps(st))
    except Exception: pass
    return True, "重命名完成"

def parse_wg_status(raw, conf_peers, status_data):
    port = 53; sent_total = 0; received_total = 0; peers = []
    for line in raw.splitlines():
        m = re.match(r"listening port:?\s*(\d+)", line.strip())
        if m: port = int(m.group(1))
    p = re.compile(r"peer: (\S+)"); current = None
    for line in raw.splitlines():
        m = p.match(line)
        if m:
            current = {"pubkey": m.group(1), "ip": "", "sent": 0, "received": 0,
                       "online": False, "endpoint": "", "handshake": "从未"}
            peers.append(current); continue
        if current is None: continue
        m = re.match(r"\s+endpoint:\s*(\S+)", line)
        if m: current["endpoint"] = m.group(1).rstrip(")")
        m = re.match(r"\s+allowed ips:\s*(\S+)", line)
        if m: current["ip"] = m.group(1).split(",")[0].strip()
        m = re.match(r"\s+latest handshake:\s*(.+)", line)
        if m:
            hs = m.group(1).strip().rstrip(",")
            current["handshake"] = hs
            # 仅用于握手时间显示；在线状态以 limiter 的 status.json 为准
        m = re.match(r"\s+transfer:\s*([\d.]+ \w+) received,\s*([\d.]+ \w+) sent", line)
        if m:
            current["received"] = m.group(1); current["sent"] = m.group(2)
            try:
                sent_total += parse_traffic(m.group(2))
                received_total += parse_traffic(m.group(1))
            except: pass

    result_peers = []
    for cp in conf_peers:
        ip_addr = cp["ip"].split("/")[0]
        # 优先按 PublicKey 精确匹配（避免 10.7.0.2 误配 10.7.0.20）
        matched = [p for p in peers if cp.get("pubkey") and p.get("pubkey") == cp["pubkey"]]
        if not matched and ip_addr:
            matched = [p for p in peers if p.get("ip", "").split("/")[0] == ip_addr]
        online = False
        sent = "0 B"; received = "0 B"; endpoint = ""; hs = "从未"
        if matched:
            m = matched[0]
            sent = m["sent"]; received = m["received"]
            endpoint = m["endpoint"]; hs = m["handshake"]
        # 在线状态完全以 limiter 的 status.json 为准，并做时效校验
        st = status_data.get(cp["name"])
        if st and "online" in st:
            age = time.time() - st.get("ts", 0)
            online = bool(st["online"]) and age < 180
        # 不在 status 中或状态过期 → 离线（不回退握手判断）
        limit = cp["limit"]; used = cp["used"]
        pct = round(used / limit * 100, 1) if limit > 0 else 0
        days_left = None
        if cp["expire"]:
            try:
                exp = datetime.strptime(cp["expire"].strip(), "%Y-%m-%d").date()
                days_left = (exp - datetime.now().date()).days
            except Exception:
                days_left = None
        result_peers.append({
            "name": cp["name"], "ip": cp["ip"], "online": online, "disabled": cp["disabled"],
            "sent": sent, "received": received, "endpoint": endpoint, "handshake": hs,
            "limit": limit, "used": used, "used_fmt": fmt_bytes(used),
            "limit_fmt": fmt_bytes(limit) if limit > 0 else "无限制",
            "percent": pct, "expire": cp["expire"], "cycle": cp["cycle"],
            "cycle_start": cp["cycle_start"], "has_token": bool(cp["token"]),
            "remark": cp.get("remark", ""), "pubkey": cp.get("pubkey", ""),
            "days_left": days_left,
            "rate_down": cp.get("rate_down", 0), "rate_up": cp.get("rate_up", 0),
            "over_quota_rate": cp.get("over_quota_rate", 0),
            "throttled": cp.get("throttled", False)
        })
    return port, sent_total, received_total, result_peers

# ---------- 路由 ----------

@app.route("/login", methods=["GET","POST"])
def login():
    if request.method == "GET": return render_template("login.html", error=None)
    username = request.form.get("username",""); password = request.form.get("password","")
    ip = client_ip()
    key = rate_key(username)
    ok, wait = check_rate_limit(key)
    if not ok:
        return render_template("login.html", error=f"登录失败次数过多，请 {wait} 秒后再试"), 429
    e = load_env()
    if username == e.get("USERNAME") and check_password_hash(e.get("PASSWORD_HASH",""), password):
        session["authenticated"] = True; session["username"] = username
        login_attempts.pop(key, None)
        append_audit("登录成功", username, ip)
        return redirect(url_for("dashboard"))
    login_attempts.setdefault(key, {"count": 0, "first": datetime.now()})
    login_attempts[key]["count"] += 1
    append_audit("登录失败", f"用户: {username}", ip)
    return render_template("login.html", error="用户名或密码错误")

@app.route("/")
def index():
    if is_authenticated(): return redirect(url_for("dashboard"))
    return redirect(url_for("login"))

@app.route("/dashboard")
def dashboard():
    if not is_authenticated(): return redirect(url_for("login"))
    return render_template("dashboard.html", username=session.get("username",""))

@app.route("/logout")
def logout():
    if is_authenticated():
        append_audit("登出", session.get("username", ""), request.remote_addr or "")
    session.clear(); return redirect(url_for("login"))

# ---------- 公开订阅（凭 token，无需登录） ----------
@app.route("/sub/<token>")
def sub(token):
    if not re.match(r'^[a-f0-9]{32}$', token or ""):
        return "Not Found", 404
    for cp in parse_conf_peers():
        if cp["token"] and secrets.compare_digest(cp["token"], token):
            for p in [f"/root/{cp['name']}.conf", f"/home/{cp['name']}.conf"]:
                if Path(p).exists():
                    return send_file(p, mimetype="text/plain", as_attachment=False,
                                     download_name=f"{cp['name']}.conf")
            return "配置不存在", 404
    return "无效订阅", 404

# ---------- API ----------

@app.route("/api/status")
def api_status():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    try:
        raw = get_wg_status()
        conf_peers = parse_conf_peers()
        port, st, rt, peers = parse_wg_status(raw, conf_peers, load_status())
        active = run(["systemctl","is-active","wg-quick@wg0"])[0]
        sl = load_server_limit()
        return jsonify({
            "running": active == "active", "port": port, "public_ip": public_ip(),
            "client_count": len(peers), "peers": peers,
            "sent_total": st, "received_total": rt,
            "sent_total_fmt": fmt_bytes(st), "received_total_fmt": fmt_bytes(rt),
            "server_limit": sl["limit"], "server_used": sl["used"],
            "server_used_fmt": fmt_bytes(sl["used"]),
            "server_limit_fmt": fmt_bytes(sl["limit"]) if sl["limit"] > 0 else "无限制",
            "server_percent": round(sl["used"] / sl["limit"] * 100, 1) if sl["limit"] > 0 else 0,
            "server_blocked": sl["blocked"], "server_period": sl["period"]
        })
    except Exception as e:
        return jsonify({"error": str(e), "running": False, "peers": []})

@app.route("/api/clients")
def api_clients():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    try:
        raw = get_wg_status()
        conf_peers = parse_conf_peers()
        _, _, _, peers = parse_wg_status(raw, conf_peers, load_status())
        cmap = {c["name"]: c for c in conf_peers}
        for p in peers:
            cp = cmap.get(p["name"], {})
            p["remark"] = cp.get("remark", "")
            p["dns"] = cp.get("dns", "")
        return jsonify(peers)
    except Exception as e:
        return jsonify({"error": str(e), "peers": []})

@app.route("/api/clients", methods=["POST"])
def api_add_client():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    name = (request.get_json(silent=True) or {}).get("name","").strip()
    if not name: return jsonify({"error":"名称不能为空"}), 400
    if not re.match(r'^[a-zA-Z0-9_-]+$', name): return jsonify({"error":"名称仅允许字母、数字、下划线和短横线"}), 400
    if len(name) > 15: return jsonify({"error":"名称最长15个字符"}), 400
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return jsonify({"error":"未找到 wg.sh"}), 500
    out, err, code = run(["bash", s, "--addclient", name])
    if code != 0: return jsonify({"error":err or out}), 500
    return jsonify({"success":True,"message":f"客户端 {name} 已添加"})

@app.route("/api/clients/batch-delete", methods=["POST"])
def api_batch_delete():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    names = (request.get_json(silent=True) or {}).get("names", [])
    if not names: return jsonify({"error":"名称列表为空"}), 400
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return jsonify({"error":"未找到 wg.sh"}), 500
    errors = []
    for name in names:
        out, err, code = run(["bash", s, "--removeclient", name, "-y"])
        if code != 0: errors.append(f"{name}: {err or out}")
    return jsonify({"success":True, "deleted": len(names)-len(errors), "errors": errors})

@app.route("/api/clients/<name>", methods=["DELETE"])
def api_delete_client(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return jsonify({"error":"未找到 wg.sh"}), 500
    out, err, code = run(["bash", s, "--removeclient", name, "-y"])
    if code != 0: return jsonify({"error":err or out}), 500
    qos_apply()
    return jsonify({"success":True,"message":f"客户端 {name} 已删除"})

@app.route("/api/clients/<name>/config")
def api_get_config(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    for p in [f"/root/{name}.conf", f"/home/{name}.conf"]:
        if Path(p).exists(): return send_file(p, as_attachment=True, download_name=f"{name}.conf")
    return jsonify({"error":"配置文件不存在"}), 404

@app.route("/api/clients/<name>/config/raw")
def api_get_config_raw(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    for p in [f"/root/{name}.conf", f"/home/{name}.conf"]:
        if Path(p).exists(): return jsonify({"content": Path(p).read_text()})
    return jsonify({"error":"配置文件不存在"}), 404

@app.route("/api/clients/<name>/qrcode")
def api_qr_code(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    conf = None
    for p in [f"/root/{name}.conf", f"/home/{name}.conf"]:
        if Path(p).exists(): conf = p; break
    if not conf: return jsonify({"error":"配置文件不存在"}), 404
    try:
        import qrcode; img = qrcode.make(Path(conf).read_text()); buf = io.BytesIO()
        img.save(buf, format="PNG"); buf.seek(0)
        return send_file(buf, mimetype="image/png")
    except ImportError:
        import tempfile
        fd, tmp = tempfile.mkstemp(suffix=".png"); os.close(fd)
        try:
            out, err, code = run(["qrencode","-t","PNG","-o",tmp,"-r",conf])
            if code != 0 or not Path(tmp).exists(): return jsonify({"error":"QR码生成失败"}), 500
            return send_file(io.BytesIO(Path(tmp).read_bytes()), mimetype="image/png")
        finally:
            try: os.unlink(tmp)
            except Exception: pass

@app.route("/api/clients/<name>/detail")
def api_client_detail(name):
    """客户端连接详情"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    raw = get_wg_status()
    conf_peers = parse_conf_peers()
    port, _, _, peers = parse_wg_status(raw, conf_peers, load_status())
    me = next((p for p in peers if p["name"] == name), None)
    if not me: return jsonify({"error":"客户端不存在"}), 404
    detail = dict(me)
    detail["server_port"] = port
    detail["public_ip"] = public_ip()
    detail["handshake_raw"] = me["handshake"]
    _cp = next((c for c in conf_peers if c["name"] == name), {})
    detail["remark"] = _cp.get("remark", "")
    detail["dns"] = _cp.get("dns", "")
    detail["sub_url"] = f"http://{public_ip()}:{WEB_PORT}/sub/{next((c['token'] for c in conf_peers if c['name']==name and c['token']), '')}" if me.get("has_token") else ""
    detail["exists_conf"] = any(Path(p).exists() for p in [f"/root/{name}.conf", f"/home/{name}.conf"])
    return jsonify(detail)

@app.route("/api/clients/<name>/reset", methods=["POST"])
def api_client_reset(name):
    """手动重置客户端流量"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    out, err, code = run(["wgd","reset",name])
    if code != 0: return jsonify({"error":err or out}), 500
    append_audit("重置流量", name, request.remote_addr or "")
    return jsonify({"success":True, "message":f"{name} 流量已重置"})

@app.route("/api/clients/<name>/remark", methods=["POST"])
def api_client_remark(name):
    """设置客户端备注"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    remark = (request.get_json(silent=True) or {}).get("remark", "") or ""
    remark = remark.replace("\n", " ").replace("\r", " ")[:40]
    if not WG_CONF.exists(): return jsonify({"error":"配置不存在"}), 500
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(name) + r"$", content, re.M):
        return jsonify({"error":"客户端不存在"}), 404
    lines = content.split("\n")
    out = []; cur = None; replaced = False
    for ln in lines:
        m = re.match(r"^# BEGIN_PEER (.+)", ln)
        if m: cur = m.group(1)
        if cur == name and ln.startswith("# REMARK="):
            out.append(f"# REMARK={remark}"); replaced = True; continue
        out.append(ln)
        if ln.strip() == f"# BEGIN_PEER {name}" and not replaced:
            out.append(f"# REMARK={remark}"); replaced = True
    WG_CONF.write_text("\n".join(out))
    run(["chmod", "600", str(WG_CONF)])
    append_audit("修改备注", f"{name} → {remark}", request.remote_addr or "")
    return jsonify({"success":True})

@app.route("/api/clients/batch-add", methods=["POST"])
def api_batch_add():
    """批量添加客户端"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    names = (request.get_json(silent=True) or {}).get("names", [])
    if not names: return jsonify({"error":"名称列表为空"}), 400
    if len(names) > 50: return jsonify({"error":"单次最多 50 个"}), 400
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return jsonify({"error":"未找到 wg.sh"}), 500
    added, errors = [], []
    for raw in names:
        nm = re.sub(r'[^a-zA-Z0-9_-]', '_', str(raw).strip())[:15]
        if not nm: continue
        out, err, code = run(["bash", s, "--addclient", nm])
        if code == 0: added.append(nm)
        else: errors.append(f"{nm}: {err or out}")
    append_audit("批量添加", f"成功 {len(added)} 个", request.remote_addr or "")
    return jsonify({"success":True, "added": added, "errors": errors})

@app.route("/api/clients/export-all")
def api_export_all():
    """一键导出全部配置（conf + 二维码 PNG）"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        for cp in parse_conf_peers():
            nm = cp["name"]
            conf_path = None
            for p in [f"/root/{nm}.conf", f"/home/{nm}.conf"]:
                if Path(p).exists(): conf_path = p; break
            if not conf_path: continue
            zf.writestr(f"{nm}/{nm}.conf", Path(conf_path).read_text())
            try:
                import qrcode
                img = qrcode.make(Path(conf_path).read_text())
                b = io.BytesIO(); img.save(b, format="PNG")
                zf.writestr(f"{nm}/{nm}.png", b.getvalue())
            except Exception:
                out, err, code = run(["qrencode","-t","PNG","-o","/tmp/_qr.png","-r",conf_path])
                if code == 0 and Path("/tmp/_qr.png").exists():
                    zf.writestr(f"{nm}/{nm}.png", Path("/tmp/_qr.png").read_bytes())
    buf.seek(0)
    append_audit("导出全部", "", request.remote_addr or "")
    return send_file(buf, mimetype="application/zip", as_attachment=True,
                     download_name=f"wireguard-all-{datetime.now().strftime('%Y%m%d')}.zip")

@app.route("/api/resources")
def api_resources():
    """服务器资源信息"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    r = sys_resources()
    r["mem_used_fmt"] = fmt_bytes(r["mem_used"])
    r["mem_total_fmt"] = fmt_bytes(r["mem_total"])
    r["disk_used_fmt"] = fmt_bytes(r["disk_used"])
    r["disk_total_fmt"] = fmt_bytes(r["disk_total"])
    return jsonify(r)

@app.route("/api/audit")
def api_audit():
    """审计日志"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    limit = request.args.get("limit", "100")
    if not re.match(r'^\d+$', limit): limit = "100"
    return jsonify(read_audit(int(limit)))

@app.route("/api/clients/<name>/enable", methods=["POST"])
def api_enable_client(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    out, err, code = run(["wgd","enable",name])
    if code != 0: return jsonify({"error":err or out}), 500
    return jsonify({"success":True})

@app.route("/api/clients/<name>/disable", methods=["POST"])
def api_disable_client(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    out, err, code = run(["wgd","disable",name])
    if code != 0: return jsonify({"error":err or out}), 500
    return jsonify({"success":True})

@app.route("/api/clients/<name>/settings", methods=["POST"])
def api_client_settings(name):
    """更新流量上限/到期时间/重置周期"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    if not WG_CONF.exists(): return jsonify({"error":"配置不存在"}), 500
    data = request.get_json(silent=True) or {}
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(name) + r"$", content, re.M):
        return jsonify({"error":"客户端不存在"}), 404
    lines = content.split("\n")
    out = []; cur = None
    for ln in lines:
        m = re.match(r"^# BEGIN_PEER (.+)", ln)
        if m: cur = m.group(1)
        if cur == name:
            if "limit" in data and ln.startswith("# TRAFFIC_LIMIT="):
                try: ln = f"# TRAFFIC_LIMIT={int(data['limit'])}"
                except Exception: pass
            if "expire" in data and ln.startswith("# EXPIRE="):
                ln = f"# EXPIRE={data['expire']}"
            if "cycle" in data and ln.startswith("# RESET_CYCLE="):
                c = data["cycle"] if data["cycle"] in ("natural","30d","none") else "30d"
                ln = f"# RESET_CYCLE={c}"
        out.append(ln)
    if "dns" in data:
        out = apply_peer_dns(out, name, data["dns"])
    WG_CONF.write_text("\n".join(out))
    run(["chmod","600",str(WG_CONF)])
    append_audit("修改设置", name, request.remote_addr or "")
    return jsonify({"success":True,"message":"设置已更新"})

@app.route("/api/clients/<name>/traffic")
def api_client_traffic(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    f = DATA_DIR / f"traffic_{name}.json"
    if f.exists():
        try: return jsonify(json.loads(f.read_text()))
        except Exception: pass
    return jsonify([])

@app.route("/api/clients/<name>/rename", methods=["POST"])
def api_client_rename(name):
    """重命名客户端"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    new = ((request.get_json(silent=True) or {}).get("new_name") or "").strip()
    if not re.match(r'^[a-zA-Z0-9_-]+$', new or ""): return jsonify({"error":"新名称仅允许字母、数字、下划线和短横线"}), 400
    if len(new) > 15: return jsonify({"error":"名称最长15个字符"}), 400
    ok, msg = rename_peer(name, new)
    if not ok: return jsonify({"error": msg}), 400
    append_audit("重命名客户端", f"{name} → {new}", request.remote_addr or "")
    return jsonify({"success": True, "old_name": name, "new_name": new})

@app.route("/api/clients/batch-settings", methods=["POST"])
def api_batch_settings():
    """批量修改限额/到期/周期"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    data = request.get_json(silent=True) or {}
    names = data.get("names", [])
    if not names: return jsonify({"error":"名称列表为空"}), 400
    if not WG_CONF.exists(): return jsonify({"error":"配置不存在"}), 500
    fields = {k: data[k] for k in ("limit", "expire", "cycle") if k in data}
    if not fields:
        return jsonify({"error":"未提供任何要修改的字段"}), 400
    changed = 0; errors = []
    for nm in names:
        if not re.match(r'^[a-zA-Z0-9_-]+$', str(nm) or ""): errors.append(f"{nm}: 名称无效"); continue
        content = WG_CONF.read_text()
        if not re.search(r"^# BEGIN_PEER " + re.escape(nm) + r"$", content, re.M):
            errors.append(f"{nm}: 不存在"); continue
        lines = content.split("\n"); out = []; cur = None
        for ln in lines:
            m = re.match(r"^# BEGIN_PEER (.+)", ln)
            if m: cur = m.group(1)
            if cur == nm:
                if "limit" in fields and ln.startswith("# TRAFFIC_LIMIT="):
                    try: ln = f"# TRAFFIC_LIMIT={int(fields['limit'])}"
                    except Exception: pass
                if "expire" in fields and ln.startswith("# EXPIRE="):
                    ln = f"# EXPIRE={fields['expire']}"
                if "cycle" in fields and ln.startswith("# RESET_CYCLE="):
                    c = fields["cycle"] if fields["cycle"] in ("natural","30d","none") else "30d"
                    ln = f"# RESET_CYCLE={c}"
            out.append(ln)
        WG_CONF.write_text("\n".join(out))
        changed += 1
    run(["chmod","600",str(WG_CONF)])
    append_audit("批量修改设置", f"成功 {changed} 个", request.remote_addr or "")
    return jsonify({"success": True, "changed": changed, "errors": errors})

@app.route("/api/clients/<name>/token", methods=["POST"])
def api_client_token(name):
    """生成或获取订阅 token"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    if not WG_CONF.exists(): return jsonify({"error":"配置不存在"}), 500
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(name) + r"$", content, re.M):
        return jsonify({"error":"客户端不存在"}), 404
    m = re.search(r"^# BEGIN_PEER " + re.escape(name) + r"\n(?:(?!# END_PEER).*\n)*?# TOKEN=([a-f0-9]{32})", content, re.M)
    if m:
        token = m.group(1)
    else:
        token = secrets.token_hex(16)
        content = re.sub(r"(?m)(^# BEGIN_PEER " + re.escape(name) + r"$)",
                         r"\1\n# TOKEN=" + token, content, count=1)
        WG_CONF.write_text(content)
        run(["chmod","600",str(WG_CONF)])
    return jsonify({"token": token, "url": f"http://{public_ip()}:{WEB_PORT}/sub/{token}"})

@app.route("/api/clients/batch-export", methods=["POST"])
def api_batch_export():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    names = (request.get_json(silent=True) or {}).get("names", [])
    if not names: return jsonify({"error":"名称列表为空"}), 400
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        for name in names:
            for p in [f"/root/{name}.conf", f"/home/{name}.conf"]:
                if Path(p).exists():
                    zf.write(p, f"{name}.conf"); break
    buf.seek(0)
    return send_file(buf, mimetype="application/zip", as_attachment=True, download_name="wireguard-clients.zip")

@app.route("/api/restart", methods=["POST"])
def api_restart():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    # 防抖：短时间内重复重启直接拒绝，避免快速连续重启触发 systemd start-limit-hit
    now = time.time()
    last = getattr(app, "_last_restart_ts", 0)
    if now - last < 5:
        append_audit("忽略重启请求", "5 秒内重复请求", client_ip())
        return jsonify({"success": True, "message": "重启请求过于频繁，已忽略（5 秒内仅一次）"})
    app._last_restart_ts = now
    append_audit("重启 WireGuard", "Web 重启", client_ip())
    run(["systemctl","reset-failed","wg-quick@wg0"])
    out, err, code = run(["systemctl","restart","wg-quick@wg0"])
    if code != 0: return jsonify({"error":err or out}), 500
    return jsonify({"success":True,"message":"WireGuard 已重启"})

@app.route("/api/uninstall", methods=["POST"])
def api_uninstall():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if (request.get_json(silent=True) or {}).get("confirm","") != "YES": return jsonify({"error":"请输入YES确认卸载"}), 400
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if Path(s).exists(): run(["bash", s, "--uninstall", "-y"])
    return jsonify({"success":True,"message":"WireGuard 已卸载"})

@app.route("/api/limits")
def api_limits():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    result = []
    for cp in parse_conf_peers():
        result.append({"name": cp["name"], "limit": cp["limit"], "expire": cp["expire"],
                       "cycle_start": cp["cycle_start"], "used": cp["used"],
                       "disabled": cp["disabled"], "cycle": cp["cycle"]})
    return jsonify(result)

@app.route("/api/clients/<name>/limit", methods=["POST"])
def api_set_limit(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    limit = (request.get_json(silent=True) or {}).get("limit", 0)
    run(["wgd","limit",name,str(limit)])
    return jsonify({"success":True})

@app.route("/api/clients/<name>/expire", methods=["POST"])
def api_set_expire(name):
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    expire = (request.get_json(silent=True) or {}).get("expire", "")
    run(["wgd","expire",name,expire or "clear"])
    return jsonify({"success":True})

@app.route("/api/server-limit", methods=["GET","POST"])
def api_server_limit():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if request.method == "GET":
        return jsonify(load_server_limit())
    data = request.get_json(silent=True) or {}
    sl = load_server_limit()
    sl["period"] = datetime.now().strftime("%Y-%m")
    if "limit" in data:
        try: sl["limit"] = max(0, int(data["limit"]))
        except Exception: return jsonify({"error":"limit 无效"}), 400
        if sl["limit"] > 0:
            sl["blocked"] = sl["used"] >= sl["limit"]
        else:
            sl["blocked"] = False
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    SERVER_LIMIT_FILE.write_text(json.dumps(sl))
    return jsonify({"success":True, **sl})

@app.route("/api/logs")
def api_logs():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    lines = request.args.get("lines", "100")
    if not re.match(r'^\d+$', lines): lines = "100"
    out, _, _ = run(["journalctl", "-u", "wg-quick@wg0", "--no-pager", "-n", lines, "--output=cat"])
    return jsonify({"logs": out.split("\n") if out else []})

@app.route("/api/traffic/history")
def api_traffic_history():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if TRAFFIC_FILE.exists():
        try:
            data = json.loads(TRAFFIC_FILE.read_text())
            return jsonify(data[-168:] if len(data) > 168 else data)
        except: pass
    return jsonify([])

def _safe_extract(tar, dest):
    """安全解包：拒绝路径穿越、绝对路径、非常规成员"""
    dest = Path(dest).resolve()
    for m in tar.getmembers():
        mp = Path(m.name)
        if mp.is_absolute() or ".." in mp.parts:
            raise ValueError(f"非法成员路径：{m.name}")
        if m.issym() or m.islnk():
            raise ValueError(f"非法链接成员：{m.name}")
        target = (dest / mp).resolve()
        if not str(target).startswith(str(dest) + os.sep) and target != dest:
            raise ValueError(f"越界成员：{m.name}")
    if hasattr(tarfile, "data_filter"):
        tar.extractall(path=dest, filter="data")
    else:
        tar.extractall(path=dest)

def _do_backup_archive(backup_path):
    """打包完整状态：wg 配置 + 客户端 + .env + data + systemd + 限流脚本"""
    with tarfile.open(backup_path, "w:gz") as tar:
        if WG_CONF.exists(): tar.add(WG_CONF, arcname="wireguard/wg0.conf")
        for p in Path("/root").glob("*.conf"):
            if p.is_file(): tar.add(p, arcname=f"clients/{p.name}")
        if ENV_FILE.exists(): tar.add(ENV_FILE, arcname="web/.env")
        if DATA_DIR.exists():
            for p in sorted(DATA_DIR.glob("*")):
                if p.is_file(): tar.add(p, arcname=f"web/data/{p.name}")
        for unit in ["/etc/systemd/system/wg-web.service",
                     "/etc/systemd/system/wg-limiter.service",
                     "/etc/systemd/system/wg-limiter.timer"]:
            if Path(unit).exists(): tar.add(unit, arcname=f"systemd/{Path(unit).name}")
        lim = Path("/opt/wireguard-web/scripts/wg-limiter.sh")
        if lim.exists(): tar.add(lim, arcname="web/scripts/wg-limiter.sh")

@app.route("/api/backup", methods=["POST"])
def api_backup():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    backup_name = f"wg-backup-{datetime.now().strftime('%Y%m%d-%H%M%S')}.tar.gz"
    backup_path = f"/root/{backup_name}"
    try:
        _do_backup_archive(backup_path)
        append_audit("创建备份", backup_name, request.remote_addr or "")
        return jsonify({"success":True, "path": backup_path, "name": backup_name})
    except Exception as e:
        return jsonify({"error":f"备份失败: {e}"}), 500

@app.route("/api/backup/list")
def api_backup_list():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    backups = []
    for f in sorted(glob.glob("/root/wg-backup-*.tar.gz"), reverse=True):
        p = Path(f)
        backups.append({"name": p.name, "size": p.stat().st_size,
                        "mtime": datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")})
    return jsonify(backups)

@app.route("/api/restore", methods=["POST"])
def api_restore():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    name = (request.get_json(silent=True) or {}).get("name", "")
    if not re.match(r'^wg-backup-[\d-]+\.tar\.gz$', name or ""):
        return jsonify({"error":"文件名无效"}), 400
    path = f"/root/{name}"
    if not Path(path).exists(): return jsonify({"error":"备份文件不存在"}), 404
    try:
        import shutil
        tmp = Path("/tmp/wg-restore")
        if tmp.exists(): shutil.rmtree(tmp)
        tmp.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, "r:gz") as tar:
            _safe_extract(tar, tmp)
        run(["systemctl","stop","wg-quick@wg0"])
        if (tmp / "wireguard/wg0.conf").exists():
            shutil.copy(str(tmp / "wireguard/wg0.conf"), str(WG_CONF))
            run(["chmod","600",str(WG_CONF)])
        for f in (tmp / "clients").glob("*.conf"):
            shutil.copy(str(f), f"/root/{f.name}")
        # 恢复 Web 配置与数据
        if (tmp / "web/.env").exists():
            shutil.copy(str(tmp / "web/.env"), str(ENV_FILE))
            run(["chmod","600",str(ENV_FILE)])
        if (tmp / "web/data").exists():
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            for f in (tmp / "web/data").glob("*"):
                if f.is_file(): shutil.copy(str(f), str(DATA_DIR / f.name))
        if (tmp / "web/scripts/wg-limiter.sh").exists():
            dest = Path("/opt/wireguard-web/scripts/wg-limiter.sh")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(str(tmp / "web/scripts/wg-limiter.sh"), str(dest))
            run(["chmod","+x",str(dest)])
        shutil.rmtree(tmp)
        run(["systemctl","start","wg-quick@wg0"])
        # 重载对端（不中断已建立的隧道）
        try:
            strip = subprocess.run(["wg-quick","strip","wg0"], capture_output=True, text=True)
            if strip.returncode == 0 and strip.stdout:
                subprocess.run(["wg","syncconf","wg0","/dev/stdin"], input=strip.stdout,
                               capture_output=True, text=True, timeout=15)
        except Exception: pass
        append_audit("恢复备份", name, request.remote_addr or "")
        return jsonify({"success":True,"message":"恢复完成"})
    except Exception as e:
        return jsonify({"error":f"恢复失败: {e}"}), 500

@app.route("/api/change-password", methods=["POST"])
def api_change_password():
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    old = (request.get_json(silent=True) or {}).get("old_password", "")
    new = (request.get_json(silent=True) or {}).get("new_password", "")
    if len(new) < 6: return jsonify({"error":"密码至少6个字符"}), 400
    e = load_env()
    if not check_password_hash(e.get("PASSWORD_HASH",""), old): return jsonify({"error":"原密码错误"}), 403
    e["PASSWORD_HASH"] = generate_password_hash(new)
    ENV_FILE.write_text("\n".join(f"{k}={v}" for k,v in e.items()) + "\n")
    ENV_FILE.chmod(0o600)
    return jsonify({"success":True,"message":"密码已修改"})

@app.route("/metrics")
def metrics():
    mtoken = (load_env().get("METRICS_TOKEN") or "").strip()
    if not mtoken:
        return Response("# metrics disabled: METRICS_TOKEN not configured\n",
                        mimetype="text/plain", status=503)
    tok = bearer_token()
    if not tok or not secrets.compare_digest(tok, mtoken):
        return Response("# unauthorized\n", mimetype="text/plain", status=401)
    raw = get_wg_status()
    conf_peers = parse_conf_peers()
    if raw:
        port, st, rt, peers = parse_wg_status(raw, conf_peers, load_status())
        running = run(["systemctl","is-active","wg-quick@wg0"])[0] == "active"
        data = {"running": running, "client_count": len(peers), "peers": peers,
                "sent_total": st, "received_total": rt}
    else:
        data = {"running":False,"client_count":0,"peers":[],"sent_total":0,"received_total":0}
    lines = ["# HELP wireguard_up WireGuard service status", "# TYPE wireguard_up gauge",
             f"wireguard_up {1 if data.get('running') else 0}",
             "# HELP wireguard_peers_total Total number of peers", "# TYPE wireguard_peers_total gauge",
             f"wireguard_peers_total {data.get('client_count', 0)}",
             "# HELP wireguard_sent_bytes_total Total bytes sent", "# TYPE wireguard_sent_bytes_total counter",
             f"wireguard_sent_bytes_total {data.get('sent_total', 0)}",
             "# HELP wireguard_received_bytes_total Total bytes received", "# TYPE wireguard_received_bytes_total counter",
             f"wireguard_received_bytes_total {data.get('received_total', 0)}"]
    for p in data.get("peers", []):
        safe = re.sub(r'[^a-zA-Z0-9_]', '_', p.get("name","unknown"))
        lines.append(f'wireguard_peer_online{{name="{safe}"}} {1 if p.get("online") else 0}')
        lines.append(f'wireguard_peer_used_bytes{{name="{safe}"}} {p.get("used",0)}')
    return Response("\n".join(lines)+"\n", mimetype="text/plain")

# ================= API v1（APK / 自动化） =================

def _peer_views():
    raw = get_wg_status()
    conf_peers = parse_conf_peers()
    port, st, rt, peers = parse_wg_status(raw, conf_peers, load_status())
    return port, st, rt, peers

def _conf_path(name):
    for p in [f"/root/{name}.conf", f"/home/{name}.conf"]:
        if Path(p).exists(): return p
    return None

def _sub_url(name, conf_peers):
    tok = next((c["token"] for c in conf_peers if c["name"] == name and c["token"]), "")
    if not tok: return ""
    return f"http://{public_ip()}:{WEB_PORT}/sub/{tok}"

@app.route("/api/v1/health")
def v1_health():
    return jsonify({
        "status": "ok", "api_version": API_VERSION,
        "wg_running": run(["systemctl","is-active","wg-quick@wg0"])[0] == "active",
        "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    })

@app.route("/api/v1/login", methods=["POST"])
def v1_login():
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    ip = client_ip()
    key = rate_key(username)
    ok, wait = check_rate_limit(key)
    if not ok:
        return api_error(f"登录失败次数过多，请 {wait} 秒后再试", 429)
    e = load_env()
    admin_token = (e.get("ADMIN_TOKEN") or "").strip()
    if not admin_token:
        return api_error("服务端未配置 ADMIN_TOKEN，请运行 wgd admin-token reset", 500)
    if username == e.get("USERNAME") and check_password_hash(e.get("PASSWORD_HASH",""), password):
        login_attempts.pop(key, None)
        append_audit("API 登录成功", username, ip)
        return jsonify({"access_token": admin_token, "token_type": "Bearer",
                        "expires_in": 0, "role": "admin", "username": username})
    login_attempts.setdefault(key, {"count": 0, "first": datetime.now()})
    login_attempts[key]["count"] += 1
    append_audit("API 登录失败", f"用户: {username}", ip)
    return api_error("用户名或密码错误", 401)

@app.route("/api/v1/logout", methods=["POST"])
def v1_logout():
    role, name, _ = resolve_identity()
    if role is None:
        return api_error("未认证", 401)
    append_audit("API 登出", name or "", request.remote_addr or "")
    return jsonify({"success": True, "message": "已登出（服务端令牌为永久令牌，如泄露请用 wgd admin-token reset 重置）"})

@app.route("/api/v1/me")
def v1_me():
    role, name, _ = resolve_identity()
    if role is None:
        return api_error("未认证", 401)
    return jsonify({"role": role, "name": name, "api_version": API_VERSION})

# ---------- 客户端自助（只读） ----------
@app.route("/api/v1/self")
@require_self_or_admin
def v1_self(name):
    if not name:
        return api_error("未指定客户端（管理员请加 ?name=）", 400)
    _, _, _, peers = _peer_views()
    me = next((p for p in peers if p["name"] == name), None)
    if not me:
        return api_error("客户端不存在", 404)
    conf_peers = parse_conf_peers()
    cp = next((c for c in conf_peers if c["name"] == name), {})
    out = dict(me)
    out["remark"] = cp.get("remark", "")
    out["expire"] = cp.get("expire", "")
    out["cycle"] = cp.get("cycle", "30d")
    out["dns"] = cp.get("dns", "")
    out["sub_url"] = _sub_url(name, conf_peers)
    out["has_identity"] = bool(identity_id())
    return jsonify(out)

@app.route("/api/v1/self/config")
@require_self_or_admin
def v1_self_config(name):
    if not name: return api_error("未指定客户端", 400)
    p = _conf_path(name)
    if not p: return api_error("配置文件不存在", 404)
    return jsonify({"name": name, "content": Path(p).read_text()})

@app.route("/api/v1/self/config/download")
@require_self_or_admin
def v1_self_config_dl(name):
    if not name: return api_error("未指定客户端", 400)
    p = _conf_path(name)
    if not p: return api_error("配置文件不存在", 404)
    return send_file(p, as_attachment=True, download_name=f"{name}.conf")

@app.route("/api/v1/self/qrcode")
@require_self_or_admin
def v1_self_qr(name):
    if not name: return api_error("未指定客户端", 400)
    p = _conf_path(name)
    if not p: return api_error("配置文件不存在", 404)
    return _qr_response(p)

@app.route("/api/v1/self/traffic")
@require_self_or_admin
def v1_self_traffic(name):
    if not name: return api_error("未指定客户端", 400)
    f = DATA_DIR / f"traffic_{name}.json"
    if f.exists():
        try: return jsonify(json.loads(f.read_text()))
        except Exception: pass
    return jsonify([])

# ---------- 管理员：客户端管理 ----------
@app.route("/api/v1/clients")
@require_admin
def v1_clients():
    _, _, _, peers = _peer_views()
    conf_peers = parse_conf_peers()
    cmap = {c["name"]: c for c in conf_peers}
    for p in peers:
        cp = cmap.get(p["name"], {})
        p["remark"] = cp.get("remark", "")
        p["dns"] = cp.get("dns", "")
        p["rate_down"] = cp.get("rate_down", 0)
        p["rate_up"] = cp.get("rate_up", 0)
        p["over_quota_rate"] = cp.get("over_quota_rate", 0)
        p["throttled"] = cp.get("throttled", False)
    return jsonify({"count": len(peers), "clients": peers})

@app.route("/api/v1/clients", methods=["POST"])
@require_admin
def v1_add_client():
    name = (request.get_json(silent=True) or {}).get("name", "").strip()
    if not name: return api_error("名称不能为空", 400)
    if not re.match(r'^[a-zA-Z0-9_-]+$', name): return api_error("名称仅允许字母、数字、下划线和短横线", 400)
    if len(name) > 15: return api_error("名称最长15个字符", 400)
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return api_error("未找到 wg.sh", 500)
    out, err, code = run(["bash", s, "--addclient", name])
    if code != 0: return api_error(err or out, 500)
    qos_apply()
    append_audit("API 添加客户端", name, request.remote_addr or "")
    return jsonify({"success": True, "name": name})

@app.route("/api/v1/clients/<name>")
@require_admin
def v1_client_detail(name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return api_error("名称无效", 400)
    _, _, _, peers = _peer_views()
    me = next((p for p in peers if p["name"] == name), None)
    if not me: return api_error("客户端不存在", 404)
    conf_peers = parse_conf_peers()
    cp = next((c for c in conf_peers if c["name"] == name), {})
    myself = dict(me)
    myself["remark"] = cp.get("remark", "")
    myself["dns"] = cp.get("dns", "")
    myself["sub_url"] = _sub_url(name, conf_peers)
    myself["exists_conf"] = bool(_conf_path(name))
    myself["identity_count"] = len(load_identities().get(cp.get("token", ""), {}))
    return jsonify(myself)

@app.route("/api/v1/clients/<name>", methods=["DELETE"])
@require_admin
def v1_delete_client(name):
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return api_error("未找到 wg.sh", 500)
    out, err, code = run(["bash", s, "--removeclient", name, "-y"])
    if code != 0: return api_error(err or out, 500)
    qos_apply()
    append_audit("API 删除客户端", name, request.remote_addr or "")
    return jsonify({"success": True})

@app.route("/api/v1/clients/<name>/enable", methods=["POST"])
@require_admin
def v1_enable(name):
    out, err, code = run(["wgd","enable",name])
    if code != 0: return api_error(err or out, 500)
    append_audit("API 启用客户端", name, request.remote_addr or "")
    return jsonify({"success": True})

@app.route("/api/v1/clients/<name>/disable", methods=["POST"])
@require_admin
def v1_disable(name):
    out, err, code = run(["wgd","disable",name])
    if code != 0: return api_error(err or out, 500)
    append_audit("API 禁用客户端", name, request.remote_addr or "")
    return jsonify({"success": True})

@app.route("/api/v1/clients/<name>/reset", methods=["POST"])
@require_admin
def v1_reset(name):
    out, err, code = run(["wgd","reset",name])
    if code != 0: return api_error(err or out, 500)
    append_audit("API 重置流量", name, request.remote_addr or "")
    return jsonify({"success": True})

@app.route("/api/v1/clients/<name>/remark", methods=["POST"])
@require_admin
def v1_remark(name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return api_error("名称无效", 400)
    remark = (request.get_json(silent=True) or {}).get("remark", "") or ""
    remark = remark.replace("\n", " ").replace("\r", " ")[:40]
    if not WG_CONF.exists(): return api_error("配置不存在", 500)
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(name) + r"$", content, re.M):
        return api_error("客户端不存在", 404)
    lines = content.split("\n"); out = []; cur = None; replaced = False
    for ln in lines:
        m = re.match(r"^# BEGIN_PEER (.+)", ln)
        if m: cur = m.group(1)
        if cur == name and ln.startswith("# REMARK="):
            out.append(f"# REMARK={remark}"); replaced = True; continue
        out.append(ln)
        if ln.strip() == f"# BEGIN_PEER {name}" and not replaced:
            out.append(f"# REMARK={remark}"); replaced = True
    WG_CONF.write_text("\n".join(out))
    run(["chmod", "600", str(WG_CONF)])
    append_audit("API 修改备注", f"{name} → {remark}", request.remote_addr or "")
    return jsonify({"success": True})

@app.route("/api/v1/clients/<name>/settings", methods=["POST"])
@require_admin
def v1_settings(name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return api_error("名称无效", 400)
    if not WG_CONF.exists(): return api_error("配置不存在", 500)
    data = request.get_json(silent=True) or {}
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(name) + r"$", content, re.M):
        return api_error("客户端不存在", 404)
    lines = content.split("\n"); out = []; cur = None
    for ln in lines:
        m = re.match(r"^# BEGIN_PEER (.+)", ln)
        if m: cur = m.group(1)
        if cur == name:
            if "limit" in data and ln.startswith("# TRAFFIC_LIMIT="):
                try: ln = f"# TRAFFIC_LIMIT={int(data['limit'])}"
                except Exception: pass
            if "expire" in data and ln.startswith("# EXPIRE="):
                ln = f"# EXPIRE={data['expire']}"
            if "cycle" in data and ln.startswith("# RESET_CYCLE="):
                c = data["cycle"] if data["cycle"] in ("natural","30d","none") else "30d"
                ln = f"# RESET_CYCLE={c}"
        out.append(ln)
    if "dns" in data:
        out = apply_peer_dns(out, name, data["dns"])
    WG_CONF.write_text("\n".join(out))
    run(["chmod","600",str(WG_CONF)])
    append_audit("API 修改设置", name, request.remote_addr or "")
    return jsonify({"success": True, "message": "设置已更新"})

@app.route("/api/v1/clients/<name>/rename", methods=["POST"])
@require_admin
def v1_rename(name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return api_error("名称无效", 400)
    new = ((request.get_json(silent=True) or {}).get("new_name") or "").strip()
    if not re.match(r'^[a-zA-Z0-9_-]+$', new or ""): return api_error("新名称仅允许字母、数字、下划线和短横线", 400)
    if len(new) > 15: return api_error("名称最长15个字符", 400)
    ok, msg = rename_peer(name, new)
    if not ok: return api_error(msg, 400)
    append_audit("API 重命名客户端", f"{name} → {new}", request.remote_addr or "")
    return jsonify({"success": True, "old_name": name, "new_name": new})

@app.route("/api/v1/clients/batch-settings", methods=["POST"])
@require_admin
def v1_batch_settings():
    data = request.get_json(silent=True) or {}
    names = data.get("names", [])
    if not names: return api_error("名称列表为空", 400)
    if not WG_CONF.exists(): return api_error("配置不存在", 500)
    fields = {k: data[k] for k in ("limit", "expire", "cycle") if k in data}
    if not fields: return api_error("未提供任何要修改的字段", 400)
    changed = 0; errors = []
    for nm in names:
        if not re.match(r'^[a-zA-Z0-9_-]+$', str(nm) or ""): errors.append(f"{nm}: 名称无效"); continue
        content = WG_CONF.read_text()
        if not re.search(r"^# BEGIN_PEER " + re.escape(nm) + r"$", content, re.M):
            errors.append(f"{nm}: 不存在"); continue
        lines = content.split("\n"); out = []; cur = None
        for ln in lines:
            m = re.match(r"^# BEGIN_PEER (.+)", ln)
            if m: cur = m.group(1)
            if cur == nm:
                if "limit" in fields and ln.startswith("# TRAFFIC_LIMIT="):
                    try: ln = f"# TRAFFIC_LIMIT={int(fields['limit'])}"
                    except Exception: pass
                if "expire" in fields and ln.startswith("# EXPIRE="):
                    ln = f"# EXPIRE={fields['expire']}"
                if "cycle" in fields and ln.startswith("# RESET_CYCLE="):
                    c = fields["cycle"] if fields["cycle"] in ("natural","30d","none") else "30d"
                    ln = f"# RESET_CYCLE={c}"
            out.append(ln)
        WG_CONF.write_text("\n".join(out)); changed += 1
    run(["chmod","600",str(WG_CONF)])
    append_audit("API 批量修改设置", f"成功 {changed} 个", request.remote_addr or "")
    return jsonify({"success": True, "changed": changed, "errors": errors})

@app.route("/api/v1/qos", methods=["GET","POST"])
@require_admin
def v1_qos():
    if request.method == "GET":
        return jsonify(load_qos())
    data = request.get_json(silent=True) or {}
    q = load_qos()
    if "algo" in data:
        if data["algo"] not in ("htb", "tbf"): return api_error("algo 仅支持 htb 或 tbf", 400)
        q["algo"] = data["algo"]
    for k in ("total_down", "total_up"):
        if k in data:
            try: q[k] = max(0, int(round(float(data[k]) * 1048576)))   # 入参 MB/s → 字节/秒
            except Exception: return api_error(f"{k} 无效", 400)
    if "enabled" in data: q["enabled"] = bool(data["enabled"])
    if q["algo"] == "tbf" and (q["total_down"] > 0 or q["total_up"] > 0):
        pass  # TBF 模式忽略总带宽，下发脚本会跳过
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    QOS_FILE.write_text(json.dumps(q))
    qos_apply()
    append_audit("API 设置全局限速", f"algo={q['algo']} down={q['total_down']} up={q['total_up']}", request.remote_addr or "")
    return jsonify({"success": True, **q})

@app.route("/api/v1/clients/<name>/qos", methods=["GET","POST"])
@require_admin
def v1_client_qos(name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return api_error("名称无效", 400)
    cp = next((c for c in parse_conf_peers() if c["name"] == name), None)
    if not cp: return api_error("客户端不存在", 404)
    if request.method == "GET":
        return jsonify({"name": name, "rate_down": cp.get("rate_down",0), "rate_up": cp.get("rate_up",0),
                        "over_quota_rate": cp.get("over_quota_rate",0), "throttled": cp.get("throttled",False)})
    data = request.get_json(silent=True) or {}
    rates = {}
    for k in ("rate_down", "rate_up", "over_quota_rate"):
        if k in data:
            try: rates[k] = max(0, int(round(float(data[k]) * 1048576)))   # 入参 MB/s → 字节/秒
            except Exception: return api_error(f"{k} 无效", 400)
    if not rates: return api_error("未提供任何限速字段", 400)
    ok, msg = set_peer_rates(name, rates)
    if not ok: return api_error(msg, 404)
    append_audit("API 设置客户端限速", f"{name}: {rates}", request.remote_addr or "")
    cp2 = next((c for c in parse_conf_peers() if c["name"] == name), {})
    return jsonify({"success": True, "name": name, "rate_down": cp2.get("rate_down",0),
                    "rate_up": cp2.get("rate_up",0), "over_quota_rate": cp2.get("over_quota_rate",0)})

@app.route("/api/clients/<name>/qos", methods=["GET","POST"])
def api_client_qos_legacy(name):
    """兼容旧版网页/缓存脚本：Cookie 会话，语义与 v1 一致（入参 MB/s）"""
    if not is_authenticated(): return jsonify({"error":"未认证"}), 401
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return jsonify({"error":"名称无效"}), 400
    cp = next((c for c in parse_conf_peers() if c["name"] == name), None)
    if not cp: return jsonify({"error":"客户端不存在"}), 404
    if request.method == "GET":
        return jsonify({"name": name, "rate_down": cp.get("rate_down",0), "rate_up": cp.get("rate_up",0),
                        "over_quota_rate": cp.get("over_quota_rate",0), "throttled": cp.get("throttled",False)})
    data = request.get_json(silent=True) or {}
    rates = {}
    for k in ("rate_down", "rate_up", "over_quota_rate"):
        if k in data:
            try: rates[k] = max(0, int(round(float(data[k]) * 1048576)))
            except Exception: return jsonify({"error":f"{k} 无效"}), 400
    if not rates: return jsonify({"error":"未提供任何限速字段"}), 400
    ok, msg = set_peer_rates(name, rates)
    if not ok: return jsonify({"error": msg}), 404
    append_audit("设置客户端限速", f"{name}: {rates}", request.remote_addr or "")
    cp2 = next((c for c in parse_conf_peers() if c["name"] == name), {})
    return jsonify({"success": True, "name": name, "rate_down": cp2.get("rate_down",0),
                    "rate_up": cp2.get("rate_up",0), "over_quota_rate": cp2.get("over_quota_rate",0)})

@app.route("/api/v1/clients/<name>/config")
@require_admin
def v1_config(name):
    p = _conf_path(name)
    if not p: return api_error("配置文件不存在", 404)
    return jsonify({"name": name, "content": Path(p).read_text()})

@app.route("/api/v1/clients/<name>/config/download")
@require_admin
def v1_config_dl(name):
    p = _conf_path(name)
    if not p: return api_error("配置文件不存在", 404)
    return send_file(p, as_attachment=True, download_name=f"{name}.conf")

def _qr_response(conf_path):
    try:
        import qrcode
        img = qrcode.make(Path(conf_path).read_text()); buf = io.BytesIO()
        img.save(buf, format="PNG"); buf.seek(0)
        return send_file(buf, mimetype="image/png")
    except ImportError:
        import tempfile
        fd, tmp = tempfile.mkstemp(suffix=".png"); os.close(fd)
        try:
            out, err, code = run(["qrencode","-t","PNG","-o",tmp,"-r",conf_path])
            if code != 0 or not Path(tmp).exists(): return api_error("QR码生成失败", 500)
            return send_file(io.BytesIO(Path(tmp).read_bytes()), mimetype="image/png")
        finally:
            try: os.unlink(tmp)
            except Exception: pass

@app.route("/api/v1/clients/<name>/qrcode")
@require_admin
def v1_qr(name):
    p = _conf_path(name)
    if not p: return api_error("配置文件不存在", 404)
    return _qr_response(p)

@app.route("/api/v1/clients/<name>/token", methods=["POST"])
@require_admin
def v1_token(name):
    if not re.match(r'^[a-zA-Z0-9_-]+$', name or ""): return api_error("名称无效", 400)
    if not WG_CONF.exists(): return api_error("配置不存在", 500)
    content = WG_CONF.read_text()
    if not re.search(r"^# BEGIN_PEER " + re.escape(name) + r"$", content, re.M):
        return api_error("客户端不存在", 404)
    m = re.search(r"^# BEGIN_PEER " + re.escape(name) + r"\n(?:(?!# END_PEER).*\n)*?# TOKEN=([a-f0-9]{32})", content, re.M)
    if m:
        token = m.group(1)
    else:
        token = secrets.token_hex(16)
        content = re.sub(r"(?m)(^# BEGIN_PEER " + re.escape(name) + r"$)",
                         r"\1\n# TOKEN=" + token, content, count=1)
        WG_CONF.write_text(content)
        run(["chmod","600",str(WG_CONF)])
    return jsonify({"name": name, "token": token, "url": f"http://{public_ip()}:{WEB_PORT}/sub/{token}"})

@app.route("/api/v1/clients/batch-add", methods=["POST"])
@require_admin
def v1_batch_add():
    names = (request.get_json(silent=True) or {}).get("names", [])
    if not names: return api_error("名称列表为空", 400)
    if len(names) > 50: return api_error("单次最多 50 个", 400)
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return api_error("未找到 wg.sh", 500)
    added, errors = [], []
    for raw in names:
        nm = re.sub(r'[^a-zA-Z0-9_-]', '_', str(raw).strip())[:15]
        if not nm: continue
        out, err, code = run(["bash", s, "--addclient", nm])
        if code == 0: added.append(nm)
        else: errors.append(f"{nm}: {err or out}")
    append_audit("API 批量添加", f"成功 {len(added)} 个", request.remote_addr or "")
    return jsonify({"success": True, "added": added, "errors": errors})

@app.route("/api/v1/clients/batch-delete", methods=["POST"])
@require_admin
def v1_batch_delete():
    names = (request.get_json(silent=True) or {}).get("names", [])
    if not names: return api_error("名称列表为空", 400)
    s = "/etc/wireguard/wg.sh"
    if not Path(s).exists(): s = "/root/wg.sh"
    if not Path(s).exists(): return api_error("未找到 wg.sh", 500)
    errors = []
    for name in names:
        out, err, code = run(["bash", s, "--removeclient", name, "-y"])
        if code != 0: errors.append(f"{name}: {err or out}")
    qos_apply()
    return jsonify({"success": True, "deleted": len(names)-len(errors), "errors": errors})

@app.route("/api/v1/clients/batch-export", methods=["POST"])
@require_admin
def v1_batch_export():
    names = (request.get_json(silent=True) or {}).get("names", [])
    if not names: return api_error("名称列表为空", 400)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        for name in names:
            p = _conf_path(name)
            if p: zf.write(p, f"{name}.conf")
    buf.seek(0)
    return send_file(buf, mimetype="application/zip", as_attachment=True, download_name="wireguard-clients.zip")

# ---------- 管理员：身份 ID（反 token 泄露） ----------
@app.route("/api/v1/clients/<name>/identities")
@require_admin
def v1_identities(name):
    cp = next((c for c in parse_conf_peers() if c["name"] == name), None)
    if not cp: return api_error("客户端不存在", 404)
    rec = load_identities().get(cp.get("token", ""), {})
    items = [{"identity_id": k, **v} for k, v in rec.items()]
    items.sort(key=lambda x: x.get("last_seen", ""), reverse=True)
    return jsonify({"name": name, "count": len(items), "identities": items,
                    "leak_suspected": len(items) > 1})

@app.route("/api/v1/clients/<name>/identities/<iid>", methods=["DELETE"])
@require_admin
def v1_revoke_identity(name, iid):
    cp = next((c for c in parse_conf_peers() if c["name"] == name), None)
    if not cp: return api_error("客户端不存在", 404)
    d = load_identities(); tok = cp.get("token", "")
    if tok in d and iid in d[tok]:
        d[tok].pop(iid, None)
        save_identities(d)
        append_audit("吊销身份 ID", f"{name}: {iid}", request.remote_addr or "")
        return jsonify({"success": True})
    return api_error("身份 ID 不存在", 404)

# ---------- 管理员：服务器 ----------
@app.route("/api/v1/server")
@require_admin
def v1_server():
    raw = get_wg_status()
    conf_peers = parse_conf_peers()
    port, st, rt, peers = parse_wg_status(raw, conf_peers, load_status())
    active = run(["systemctl","is-active","wg-quick@wg0"])[0]
    sl = load_server_limit()
    r = sys_resources()
    online = sum(1 for p in peers if p["online"])
    return jsonify({
        "running": active == "active", "port": port, "public_ip": public_ip(),
        "client_count": len(peers), "online_count": online,
        "sent_total": st, "received_total": rt,
        "sent_total_fmt": fmt_bytes(st), "received_total_fmt": fmt_bytes(rt),
        "server_limit": sl["limit"], "server_used": sl["used"],
        "server_limit_fmt": fmt_bytes(sl["limit"]) if sl["limit"] > 0 else "无限制",
        "server_used_fmt": fmt_bytes(sl["used"]),
        "server_percent": round(sl["used"] / sl["limit"] * 100, 1) if sl["limit"] > 0 else 0,
        "server_blocked": sl["blocked"], "server_period": sl["period"],
        "resources": {
            "cpu": r["cpu"], "mem_pct": r["mem_pct"],
            "mem_used_fmt": fmt_bytes(r["mem_used"]), "mem_total_fmt": fmt_bytes(r["mem_total"]),
            "disk_pct": r["disk_pct"],
            "disk_used_fmt": fmt_bytes(r["disk_used"]), "disk_total_fmt": fmt_bytes(r["disk_total"]),
            "load": r["load"], "uptime": r["uptime"], "cpu_count": r["cpu_count"]
        }
    })

@app.route("/api/v1/server-limit", methods=["GET","POST"])
@require_admin
def v1_server_limit():
    if request.method == "GET":
        return jsonify(load_server_limit())
    data = request.get_json(silent=True) or {}
    sl = load_server_limit()
    sl["period"] = datetime.now().strftime("%Y-%m")
    if "limit" in data:
        try: sl["limit"] = max(0, int(data["limit"]))
        except Exception: return api_error("limit 无效", 400)
        sl["blocked"] = sl["used"] >= sl["limit"] if sl["limit"] > 0 else False
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    SERVER_LIMIT_FILE.write_text(json.dumps(sl))
    append_audit("API 设置服务器限额", str(sl["limit"]), request.remote_addr or "")
    return jsonify({"success": True, **sl})

@app.route("/api/v1/resources")
@require_admin
def v1_resources():
    r = sys_resources()
    r["mem_used_fmt"] = fmt_bytes(r["mem_used"]); r["mem_total_fmt"] = fmt_bytes(r["mem_total"])
    r["disk_used_fmt"] = fmt_bytes(r["disk_used"]); r["disk_total_fmt"] = fmt_bytes(r["disk_total"])
    return jsonify(r)

@app.route("/api/v1/audit")
@require_admin
def v1_audit():
    limit = request.args.get("limit", "100")
    if not re.match(r'^\d+$', limit): limit = "100"
    return jsonify(read_audit(int(limit)))

@app.route("/api/v1/backup", methods=["POST"])
@require_admin
def v1_backup():
    backup_name = f"wg-backup-{datetime.now().strftime('%Y%m%d-%H%M%S')}.tar.gz"
    backup_path = f"/root/{backup_name}"
    try:
        _do_backup_archive(backup_path)
        append_audit("API 创建备份", backup_name, request.remote_addr or "")
        return jsonify({"success": True, "name": backup_name, "path": backup_path})
    except Exception as e:
        return api_error(f"备份失败: {e}", 500)

@app.route("/api/v1/backup/list")
@require_admin
def v1_backup_list():
    backups = []
    for f in sorted(glob.glob("/root/wg-backup-*.tar.gz"), reverse=True):
        p = Path(f)
        backups.append({"name": p.name, "size": p.stat().st_size,
                        "mtime": datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")})
    return jsonify(backups)

@app.route("/api/v1/restore", methods=["POST"])
@require_admin
def v1_restore():
    name = (request.get_json(silent=True) or {}).get("name", "")
    if not re.match(r'^wg-backup-[\d-]+\.tar\.gz$', name or ""):
        return api_error("文件名无效", 400)
    path = f"/root/{name}"
    if not Path(path).exists(): return api_error("备份文件不存在", 404)
    try:
        import shutil
        tmp = Path("/tmp/wg-restore")
        if tmp.exists(): shutil.rmtree(tmp)
        tmp.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, "r:gz") as tar:
            _safe_extract(tar, tmp)
        run(["systemctl","stop","wg-quick@wg0"])
        if (tmp / "wireguard/wg0.conf").exists():
            for f in (tmp / "wireguard").glob("wg*.conf"):
                shutil.copy(str(f), f"/etc/wireguard/{f.name}")
            run(["chmod","600",str(WG_CONF)])
        for f in (tmp / "clients").glob("*.conf"):
            shutil.copy(str(f), f"/root/{f.name}")
        if (tmp / "web/.env").exists():
            shutil.copy(str(tmp / "web/.env"), str(ENV_FILE)); run(["chmod","600",str(ENV_FILE)])
        if (tmp / "web/data").exists():
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            for f in (tmp / "web/data").glob("*"):
                if f.is_file(): shutil.copy(str(f), str(DATA_DIR / f.name))
        shutil.rmtree(tmp)
        run(["systemctl","start","wg-quick@wg0"])
        try:
            strip = subprocess.run(["wg-quick","strip","wg0"], capture_output=True, text=True)
            if strip.returncode == 0 and strip.stdout:
                subprocess.run(["wg","syncconf","wg0","/dev/stdin"], input=strip.stdout,
                               capture_output=True, text=True, timeout=15)
        except Exception: pass
        append_audit("API 恢复备份", name, request.remote_addr or "")
        return jsonify({"success": True, "message": "恢复完成"})
    except Exception as e:
        return api_error(f"恢复失败: {e}", 500)

if __name__ == "__main__":
    host, port = "0.0.0.0", 5666
    import sys
    if "--host" in sys.argv: host = sys.argv[sys.argv.index("--host")+1]
    if "--port" in sys.argv: port = int(sys.argv[sys.argv.index("--port")+1])
    app.run(host=host, port=port, debug=False)
EMBEDPYEOF
  cat > "$WEB_DIR/templates/login.html" << 'EMBEDLOGINEOF'
<!DOCTYPE html>
<html lang="zh-CN" class="h-full">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WireGuard VPN 管理</title>
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://unpkg.com/lucide@latest/dist/umd/lucide.css" rel="stylesheet">
<script src="https://unpkg.com/lucide@latest"></script>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<style>
* { font-family: 'Inter', system-ui, -apple-system, sans-serif; }
body { background: linear-gradient(135deg, #0f172a 0%, #1e293b 50%, #0f172a 100%); }
.login-card { backdrop-filter: blur(20px); background: rgba(30, 41, 59, 0.7); border: 1px solid rgba(148, 163, 184, 0.1); }
.input-field { background: rgba(15, 23, 42, 0.6); border: 1px solid rgba(148, 163, 184, 0.2); }
.input-field:focus { border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15); }
</style>
</head>
<body class="h-full flex items-center justify-center p-4">
<div class="w-full max-w-sm">
  <div class="login-card rounded-2xl p-8 shadow-2xl">
    <div class="flex flex-col items-center mb-8">
      <div class="w-14 h-14 rounded-2xl bg-blue-500/10 flex items-center justify-center mb-4">
        <i data-lucide="shield" class="w-7 h-7 text-blue-400"></i>
      </div>
      <h1 class="text-xl font-semibold text-white">WireGuard VPN</h1>
      <p class="text-sm text-slate-400 mt-1">管理面板</p>
    </div>
    <form method="POST" action="/login" class="space-y-4">
      <div>
        <label class="block text-sm font-medium text-slate-300 mb-1.5">用户名</label>
        <div class="relative">
          <i data-lucide="user" class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-slate-500"></i>
          <input type="text" name="username" required autocomplete="username"
                 class="input-field w-full pl-10 pr-4 py-2.5 rounded-xl text-white text-sm
                        placeholder-slate-500 focus:outline-none transition-all duration-200"
                 placeholder="请输入用户名">
        </div>
      </div>
      <div>
        <label class="block text-sm font-medium text-slate-300 mb-1.5">密码</label>
        <div class="relative">
          <i data-lucide="lock" class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-slate-500"></i>
          <input type="password" name="password" required autocomplete="current-password"
                 class="input-field w-full pl-10 pr-4 py-2.5 rounded-xl text-white text-sm
                        placeholder-slate-500 focus:outline-none transition-all duration-200"
                 placeholder="请输入密码">
        </div>
      </div>
      {% if error %}
      <div class="flex items-center gap-2 text-red-400 text-sm bg-red-500/10 rounded-xl px-4 py-2.5">
        <i data-lucide="alert-circle" class="w-4 h-4 flex-shrink-0"></i>
        <span>{{ error }}</span>
      </div>
      {% endif %}
      <button type="submit"
              class="w-full py-2.5 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium
                     transition-all duration-200 active:scale-[0.98] focus:outline-none focus:ring-2
                     focus:ring-blue-500 focus:ring-offset-2 focus:ring-offset-slate-800">
        登 录
      </button>
    </form>
  </div>
  <p class="text-center text-xs text-slate-600 mt-6">WireGuard VPN 管理面板 v1.0</p>
</div>
<script>lucide.createIcons();</script>
</body>
</html>
EMBEDLOGINEOF
  cat > "$WEB_DIR/templates/dashboard.html" << 'EMBEDDASHEOF'
<!DOCTYPE html>
<html lang="zh-CN" class="h-full">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>WireGuard 管理面板</title>
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://unpkg.com/lucide@latest/dist/umd/lucide.css" rel="stylesheet">
<script src="https://unpkg.com/lucide@latest"></script>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
* { font-family: 'Inter', system-ui, -apple-system, sans-serif; }
body { background: #0f172a; }
.stat-card { background: rgba(30, 41, 59, 0.6); border: 1px solid rgba(148, 163, 184, 0.08); backdrop-filter: blur(12px); }
.stat-card:hover { border-color: rgba(148, 163, 184, 0.2); }
.modal-overlay { background: rgba(0,0,0,0.6); backdrop-filter: blur(4px); }
#topology { width: 100%; height: 100%; display: block; }
input, button, select { outline: none; }
::-webkit-scrollbar { width: 5px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: rgba(148,163,184,0.15); border-radius: 3px; }
.toast { animation: slideUp 0.3s ease-out; }
@keyframes slideUp { from { opacity: 0; transform: translateY(20px); } to { opacity: 1; transform: translateY(0); } }
@keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
.modal-content { animation: fadeIn 0.2s ease-out; }
.skel { background: linear-gradient(90deg, rgba(148,163,184,0.06) 25%, rgba(148,163,184,0.15) 50%, rgba(148,163,184,0.06) 75%); background-size: 200% 100%; animation: shimmer 1.5s infinite; border-radius: 6px; }
@keyframes shimmer { 0% { background-position: 200% 0; } 100% { background-position: -200% 0; } }
#topologyTooltip { position: absolute; display: none; background: rgba(15,23,42,0.92); border: 1px solid rgba(148,163,184,0.15); padding: 8px 12px; border-radius: 10px; font-size: 12px; color: #e2e8f0; pointer-events: none; white-space: nowrap; z-index: 10; backdrop-filter: blur(8px); }
#topologyTooltip b { color: #f1f5f9; }
#topologyWrap { position: relative; }
.log-line-error { color: #f87171; }
.log-line-warn { color: #fbbf24; }
.log-line-info { color: #94a3b8; }
@media (max-width: 639px) {
  .client-row { display: flex; flex-direction: column; padding: 12px; gap: 6px; border-bottom: 1px solid rgba(148,163,184,0.06); }
  .client-row:last-child { border-bottom: none; }
}
</style>
</head>
<body class="min-h-screen text-slate-200">
<div id="app" class="flex flex-col min-h-screen">
  <nav class="sticky top-0 z-30 bg-slate-900/80 backdrop-blur-xl border-b border-slate-800/50">
    <div class="max-w-7xl mx-auto px-4 sm:px-6 h-14 flex items-center justify-between">
      <div class="flex items-center gap-2.5">
        <div class="w-8 h-8 rounded-lg bg-blue-500/15 flex items-center justify-center"><i data-lucide="shield" class="w-4.5 h-4.5 text-blue-400" style="width:18px;height:18px"></i></div>
        <span class="text-sm font-semibold text-white hidden sm:inline">WireGuard</span>
        <span class="text-xs text-slate-500 hidden sm:inline">管理面板</span>
      </div>
      <div class="flex items-center gap-3">
        <span class="text-xs text-slate-400" id="navUser">{{ username }}</span>
        <button onclick="openSettingsModal()" class="text-xs text-slate-500 hover:text-slate-300 transition-colors" title="设置"><i data-lucide="settings" class="w-3.5 h-3.5"></i></button>
        <a href="/logout" class="text-xs text-slate-500 hover:text-slate-300 transition-colors flex items-center gap-1.5"><i data-lucide="log-out" class="w-3.5 h-3.5"></i><span class="hidden sm:inline">退出</span></a>
      </div>
    </div>
  </nav>
  <main class="flex-1 max-w-7xl mx-auto w-full px-4 sm:px-6 py-4 sm:py-6 space-y-4 sm:space-y-6">
    <!-- Status Cards -->
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
      <div class="stat-card rounded-xl sm:rounded-2xl p-4 sm:p-5">
        <div class="flex items-center gap-3"><div id="statusDot" class="w-2.5 h-2.5 rounded-full bg-slate-600"></div><span class="text-xs text-slate-500 font-medium">运行状态</span></div>
        <p id="statusText" class="text-lg sm:text-2xl font-bold text-white mt-2">检测中...</p>
      </div>
      <div class="stat-card rounded-xl sm:rounded-2xl p-4 sm:p-5">
        <div class="flex items-center gap-2"><i data-lucide="radio" class="w-4 h-4 text-slate-500"></i><span class="text-xs text-slate-500 font-medium">监听端口</span></div>
        <p id="portText" class="text-lg sm:text-2xl font-bold text-white mt-2">-</p>
      </div>
      <div class="stat-card rounded-xl sm:rounded-2xl p-4 sm:p-5">
        <div class="flex items-center gap-2"><i data-lucide="smartphone" class="w-4 h-4 text-slate-500"></i><span class="text-xs text-slate-500 font-medium">客户端</span></div>
        <p id="clientCountText" class="text-lg sm:text-2xl font-bold text-white mt-2">-</p>
      </div>
      <div class="stat-card rounded-xl sm:rounded-2xl p-4 sm:p-5">
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-2"><i data-lucide="arrow-up-down" class="w-4 h-4 text-slate-500"></i><span class="text-xs text-slate-500 font-medium">总流量</span></div>
          <button onclick="openServerLimitModal()" class="text-slate-500 hover:text-amber-400 transition-colors" title="设置服务器总流量上限"><i data-lucide="sliders-horizontal" class="w-3.5 h-3.5"></i></button>
        </div>
        <p id="trafficText" class="text-base sm:text-xl font-bold text-white mt-1 leading-tight">-</p>
        <p id="serverLimitText" class="text-[11px] mt-1">-</p>
      </div>
    </div>
    <!-- Traffic Chart -->
    <div class="stat-card rounded-xl sm:rounded-2xl p-4 sm:p-5">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2"><i data-lucide="trending-up" class="w-4 h-4 text-slate-500"></i><span class="text-xs text-slate-500 font-medium">流量趋势（最近24小时）</span></div>
        <div class="flex items-center gap-3 text-xs"><span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-emerald-400"></span><span class="text-slate-500">发送</span></span><span class="flex items-center gap-1"><span class="w-2 h-2 rounded-full bg-blue-400"></span><span class="text-slate-500">接收</span></span></div>
      </div>
      <div style="position:relative;height:130px">
        <canvas id="trafficChart"></canvas>
      </div>
    </div>
    <!-- Server Resources -->
    <div class="stat-card rounded-xl sm:rounded-2xl p-4 sm:p-5">
      <div class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2"><i data-lucide="activity" class="w-4 h-4 text-slate-500"></i><span class="text-xs text-slate-500 font-medium">服务器资源</span></div>
        <span id="uptimeText" class="text-xs text-slate-500">-</span>
      </div>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div>
          <div class="flex items-center justify-between text-xs mb-1"><span class="text-slate-400">CPU</span><span id="cpuText" class="text-slate-300">-</span></div>
          <div class="h-1.5 rounded-full bg-slate-700/60 overflow-hidden"><div id="cpuBar" class="h-full bg-blue-500" style="width:0%"></div></div>
          <p id="loadText" class="text-[10px] text-slate-600 mt-1">-</p>
        </div>
        <div>
          <div class="flex items-center justify-between text-xs mb-1"><span class="text-slate-400">内存</span><span id="memText" class="text-slate-300">-</span></div>
          <div class="h-1.5 rounded-full bg-slate-700/60 overflow-hidden"><div id="memBar" class="h-full bg-emerald-500" style="width:0%"></div></div>
        </div>
        <div>
          <div class="flex items-center justify-between text-xs mb-1"><span class="text-slate-400">磁盘</span><span id="diskText" class="text-slate-300">-</span></div>
          <div class="h-1.5 rounded-full bg-slate-700/60 overflow-hidden"><div id="diskBar" class="h-full bg-amber-500" style="width:0%"></div></div>
        </div>
      </div>
    </div>
    <!-- Topology + Clients -->
    <div class="grid grid-cols-1 xl:grid-cols-5 gap-4 sm:gap-6">
      <div id="topologyWrap" class="xl:col-span-2 stat-card rounded-xl sm:rounded-2xl overflow-hidden" style="min-height:300px;height:40vh;max-height:500px">
        <div id="topology" class="w-full h-full"></div><div id="topologyTooltip"></div>
      </div>
      <div class="xl:col-span-3 stat-card rounded-xl sm:rounded-2xl p-4 sm:p-5 flex flex-col" style="min-height:300px;max-height:500px">
        <div class="flex items-center justify-between mb-2 flex-shrink-0">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold text-white flex items-center gap-2"><i data-lucide="users" class="w-4 h-4 text-slate-500"></i>客户端</h2>
            <span id="batchBadge" class="hidden text-xs bg-blue-600/30 text-blue-400 px-2 py-0.5 rounded-full"></span>
          </div>
          <div class="flex items-center gap-1">
            <button id="batchDeleteBtn" onclick="batchDelete()" class="hidden text-xs px-2 py-1 rounded-lg bg-red-600/20 text-red-400 hover:bg-red-600/30">删除选中</button>
            <button id="batchSettingsBtn" onclick="openBatchSettingsModal()" class="hidden text-xs px-2 py-1 rounded-lg bg-amber-600/20 text-amber-400 hover:bg-amber-600/30">批量设置</button>
            <button id="batchExportBtn" onclick="batchExport()" class="hidden text-xs px-2 py-1 rounded-lg bg-green-600/20 text-green-400 hover:bg-green-600/30">导出选中</button>
            <button onclick="openBatchAddModal()" class="text-xs px-2 py-1.5 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300" title="批量添加"><i data-lucide="list-plus" class="w-3.5 h-3.5"></i></button>
            <button onclick="exportAll()" class="text-xs px-2 py-1.5 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300" title="导出全部配置"><i data-lucide="folder-down" class="w-3.5 h-3.5"></i></button>
            <button onclick="openAuditModal()" class="text-xs px-2 py-1.5 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300" title="登录审计"><i data-lucide="scroll-text" class="w-3.5 h-3.5"></i></button>
            <button onclick="openAddModal()" class="text-xs px-3 py-1.5 rounded-lg bg-blue-600/20 text-blue-400 hover:bg-blue-600/30 transition-colors">+ 添加</button>
          </div>
        </div>
        <div class="relative mb-2 flex-shrink-0 flex gap-1.5">
          <div class="relative flex-1 min-w-0">
            <i data-lucide="search" class="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-slate-500"></i>
            <input id="clientSearch" type="text" placeholder="搜索名称/备注/IP..." oninput="doFilter(this.value)" class="w-full pl-9 pr-3 py-2 rounded-lg bg-slate-800/60 border border-slate-700/30 text-white text-xs placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/20 transition-all">
          </div>
          <select id="clientSort" onchange="onSortChange()" class="px-2 py-2 rounded-lg bg-slate-800/60 border border-slate-700/30 text-white text-xs focus:border-blue-500/50">
            <option value="name">名称</option>
            <option value="used">用量</option>
            <option value="percent">占比</option>
            <option value="expire">到期</option>
            <option value="status">状态</option>
          </select>
          <button id="sortDirBtn" onclick="toggleSortDir()" class="px-2 py-2 rounded-lg bg-slate-800/60 border border-slate-700/30 text-slate-400 hover:text-white" title="切换排序方向"><i data-lucide="arrow-up" class="w-3.5 h-3.5"></i></button>
        </div>
        <div class="flex items-center gap-1.5 mb-2 flex-shrink-0" id="filterBar">
          <button data-filter="all" onclick="setFilter('all')" class="filter-btn text-[11px] px-2 py-1 rounded-lg bg-blue-600/30 text-blue-400">全部</button>
          <button data-filter="online" onclick="setFilter('online')" class="filter-btn text-[11px] px-2 py-1 rounded-lg bg-slate-700/40 text-slate-400 hover:text-white">在线</button>
          <button data-filter="offline" onclick="setFilter('offline')" class="filter-btn text-[11px] px-2 py-1 rounded-lg bg-slate-700/40 text-slate-400 hover:text-white">离线</button>
          <button data-filter="disabled" onclick="setFilter('disabled')" class="filter-btn text-[11px] px-2 py-1 rounded-lg bg-slate-700/40 text-slate-400 hover:text-white">禁用</button>
          <button data-filter="overdue" onclick="setFilter('overdue')" class="filter-btn text-[11px] px-2 py-1 rounded-lg bg-slate-700/40 text-slate-400 hover:text-white">超限/到期</button>
          <button data-filter="expiring" onclick="setFilter('expiring')" class="filter-btn text-[11px] px-2 py-1 rounded-lg bg-slate-700/40 text-slate-400 hover:text-white">即将到期</button>
        </div>
        <div class="hidden md:flex items-center gap-2 px-1 py-1.5 text-xs text-slate-600 font-medium flex-shrink-0">
          <span class="w-5 flex-shrink-0"><input type="checkbox" id="selectAll" onchange="toggleSelectAll()" class="accent-blue-500"></span>
          <span class="flex-1 min-w-0">名称 / 流量进度</span><span class="w-24 hidden lg:block">IP</span>
          <span class="w-14 text-center flex-shrink-0">状态</span>
          <span class="w-20 text-right hidden xl:block flex-shrink-0">发送</span>
          <span class="w-20 text-right hidden xl:block flex-shrink-0">接收</span>
          <span class="w-24 flex-shrink-0"></span>
        </div>
        <div class="flex-1 overflow-y-auto -mx-4 sm:-mx-5 px-4 sm:px-5"><div id="clientList" class="space-y-0.5"></div></div>
      </div>
    </div>
    <!-- Actions -->
    <div class="flex flex-wrap gap-3 justify-center sm:justify-start">
      <button onclick="openAddModal()" class="bg-blue-600 hover:bg-blue-500 text-white text-xs sm:text-sm px-4 sm:px-5 py-2.5 rounded-xl font-medium transition-all active:scale-95 flex items-center gap-2"><i data-lucide="plus" class="w-4 h-4"></i>添加客户端</button>
      <button onclick="confirmRestart()" class="bg-slate-700/50 hover:bg-slate-700 text-white text-xs sm:text-sm px-4 sm:px-5 py-2.5 rounded-xl font-medium transition-all active:scale-95 flex items-center gap-2"><i data-lucide="rotate-cw" class="w-4 h-4"></i>重启 WG</button>
      <button onclick="openLogModal()" class="bg-slate-700/50 hover:bg-slate-700 text-white text-xs sm:text-sm px-4 sm:px-5 py-2.5 rounded-xl font-medium transition-all active:scale-95 flex items-center gap-2"><i data-lucide="file-text" class="w-4 h-4"></i>日志</button>
      <button onclick="openBackupModal()" class="bg-slate-700/50 hover:bg-slate-700 text-white text-xs sm:text-sm px-4 sm:px-5 py-2.5 rounded-xl font-medium transition-all active:scale-95 flex items-center gap-2"><i data-lucide="archive" class="w-4 h-4"></i>备份</button>
      <button onclick="confirmUninstall()" class="bg-red-600/20 hover:bg-red-600/30 text-red-400 text-xs sm:text-sm px-4 sm:px-5 py-2.5 rounded-xl font-medium transition-all active:scale-95 flex items-center gap-2"><i data-lucide="trash-2" class="w-4 h-4"></i>卸载</button>
    </div>
  </main>
</div>

<!-- Add Modal --><div id="addModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeAddModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-sm border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-5"><h3 class="text-sm font-semibold text-white"><i data-lucide="user-plus" class="w-4 h-4 text-blue-400 inline"></i>添加客户端</h3><button onclick="closeAddModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<input id="newClientName" type="text" placeholder="客户端名称" maxlength="15" class="w-full px-4 py-2.5 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30 transition-all">
<p id="addError" class="text-red-400 text-xs mt-2 hidden"></p>
<div class="flex gap-3 mt-5"><button onclick="closeAddModal()" class="flex-1 py-2 rounded-xl bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm">取消</button><button onclick="addClient()" class="flex-1 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium">添加</button></div></div></div>
<!-- QR Modal --><div id="qrModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeQRModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-xs border border-slate-700/50 shadow-2xl text-center" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-4"><h3 class="text-sm font-semibold text-white"><i data-lucide="qr-code" class="w-4 h-4 text-blue-400 inline"></i><span id="qrTitle">QR 码</span></h3><button onclick="closeQRModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<img id="qrImage" class="mx-auto rounded-xl bg-white p-2 w-48 h-48 sm:w-56 sm:h-56" alt="QR">
<div class="flex gap-2 mt-3 justify-center"><a id="qrDownloadBtn" href="#" download="qrcode.png" class="text-xs px-3 py-1.5 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300 transition-colors"><i data-lucide="download" class="w-3 h-3 inline"></i> 保存 PNG</a></div>
<p class="text-xs text-slate-500 mt-2">手机客户端扫码导入配置</p></div></div>
<!-- Config Preview Modal --><div id="configModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeConfigModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-lg border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()" style="max-height:80vh">
<div class="flex items-center justify-between mb-4"><h3 class="text-sm font-semibold text-white"><i data-lucide="file-text" class="w-4 h-4 text-blue-400 inline"></i><span id="configTitle">配置预览</span></h3><button onclick="closeConfigModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<pre id="configContent" class="bg-slate-900 rounded-xl p-4 text-xs text-slate-300 overflow-auto" style="max-height:50vh;font-family:monospace"></pre>
<div class="flex gap-2 mt-3"><button onclick="downloadConfig(currentConfigName)" class="flex-1 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm"><i data-lucide="download" class="w-3.5 h-3.5 inline"></i> 下载 .conf</button></div></div></div>
<!-- Log Modal --><div id="logModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeLogModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-2xl border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()" style="max-height:80vh">
<div class="flex items-center justify-between mb-4">
<h3 class="text-sm font-semibold text-white"><i data-lucide="file-text" class="w-4 h-4 text-blue-400 inline"></i> WG 日志</h3>
<div class="flex items-center gap-2">
<label class="flex items-center gap-1.5 text-xs text-slate-500 cursor-pointer"><input type="checkbox" id="logAutoRefresh" checked onchange="toggleLogRefresh()" class="accent-blue-500"> 自动刷新</label>
<button onclick="refreshLogs()" class="text-xs px-2 py-1 rounded-lg bg-slate-700/50 hover:bg-slate-700 text-slate-300"><i data-lucide="refresh-cw" class="w-3 h-3 inline"></i></button>
<button onclick="closeLogModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div></div>
<div id="logContent" class="bg-slate-900 rounded-xl p-4 text-xs text-slate-400 overflow-auto" style="max-height:55vh;font-family:monospace;white-space:pre-wrap"></div></div></div>
<!-- Backup Modal --><div id="backupModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeBackupModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-md border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-4"><h3 class="text-sm font-semibold text-white"><i data-lucide="archive" class="w-4 h-4 text-blue-400 inline"></i> 备份管理</h3><button onclick="closeBackupModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<button onclick="createBackup()" class="w-full mb-3 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm"><i data-lucide="package-plus" class="w-3.5 h-3.5 inline"></i> 创建备份</button>
<div id="backupList" class="space-y-1 max-h-60 overflow-y-auto"><div class="text-center text-xs text-slate-600 py-4">暂无备份</div></div></div></div>
<!-- Settings Modal --><div id="settingsModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeSettingsModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-sm border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-5"><h3 class="text-sm font-semibold text-white"><i data-lucide="settings" class="w-4 h-4 text-blue-400 inline"></i> 设置</h3><button onclick="closeSettingsModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<h4 class="text-xs font-medium text-slate-400 mb-2">修改密码</h4>
<input id="oldPassword" type="password" placeholder="原密码" class="w-full mb-2 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<input id="newPassword" type="password" placeholder="新密码（至少6位）" class="w-full mb-2 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<p id="pwdError" class="text-red-400 text-xs mb-2 hidden"></p>
<button onclick="changePassword()" class="w-full py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium">修改密码</button>
<h4 class="text-xs font-medium text-slate-400 mb-2 mt-4">全局限速（QoS）</h4>
<label class="block text-xs text-slate-400 mb-1">算法</label>
<select id="qosAlgo" class="w-full mb-2 px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm"><option value="htb">HTB（支持总带宽）</option><option value="tbf">TBF（仅单客户端）</option></select>
<label class="block text-xs text-slate-400 mb-1">总带宽下行 / 上行（MB/s，0 不限）</label>
<div class="flex gap-2 mb-2">
<input id="qosTotalDown" type="number" step="0.1" min="0" placeholder="总下行" class="flex-1 min-w-0 px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50">
<input id="qosTotalUp" type="number" step="0.1" min="0" placeholder="总上行" class="flex-1 min-w-0 px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50">
</div>
<button onclick="saveQos()" class="w-full py-2 rounded-xl bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium">保存全局限速</button></div></div>
<!-- Edit Client Modal --><div id="editModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeEditModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-sm border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-5"><h3 id="editTitle" class="text-sm font-semibold text-white"><i data-lucide="sliders-horizontal" class="w-4 h-4 text-amber-400 inline"></i> 限制设置</h3><button onclick="closeEditModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<input type="hidden" id="editClientName">
<label class="block text-xs text-slate-400 mb-1">流量上限（留空为无限制）</label>
<div class="flex gap-2 mb-3">
<input id="editLimit" type="number" step="0.01" min="0" placeholder="例如 500" class="flex-1 min-w-0 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<select id="editLimitUnit" class="w-20 px-2 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<option value="1">KB</option><option value="2">MB</option><option value="3" selected>GB</option><option value="4">TB</option>
</select>
</div>
<label class="block text-xs text-slate-400 mb-1">到期时间 (YYYY-MM-DD，留空为永久)</label>
<input id="editExpire" type="text" placeholder="例如 2026-12-31" class="w-full mb-3 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<label class="block text-xs text-slate-400 mb-1">流量重置周期</label>
<select id="editCycle" class="w-full mb-2 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
  <option value="natural">自然月（每月1日重置）</option>
  <option value="30d">30天周期</option>
  <option value="none">不自动重置</option>
</select>
<label class="block text-xs text-slate-400 mb-1 mt-1">客户端 DNS（留空使用全局默认）</label>
<input id="editDns" type="text" placeholder="例如 1.1.1.1" class="w-full mb-2 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<label class="block text-xs text-slate-400 mb-1 mt-1">下行限速 / 上行限速（MB/s，留空或 0 不限）</label>
<div class="flex gap-2 mb-3">
<input id="editRateDown" type="number" step="0.1" min="0" placeholder="下行" class="flex-1 min-w-0 px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50">
<input id="editRateUp" type="number" step="0.1" min="0" placeholder="上行" class="flex-1 min-w-0 px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50">
</div>
<label class="block text-xs text-slate-400 mb-1">超月流量配额时降速到（MB/s，0=封禁）</label>
<input id="editOverQuota" type="number" step="0.1" min="0" placeholder="留空=保持封禁" class="w-full mb-2 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<p id="editError" class="text-red-400 text-xs mb-2 hidden"></p>
<div class="flex gap-3 mt-3"><button onclick="closeEditModal()" class="flex-1 py-2 rounded-xl bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm">取消</button><button onclick="saveEditClient()" class="flex-1 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium">保存</button></div></div></div>
<!-- Client Chart Modal --><div id="clientChartModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeClientChartModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-2xl border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-4"><h3 id="clientChartTitle" class="text-sm font-semibold text-white"><i data-lucide="trending-up" class="w-4 h-4 text-blue-400 inline"></i> 流量</h3><button onclick="closeClientChartModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<div style="position:relative;height:220px"><canvas id="clientChart"></canvas></div></div></div>
<!-- Subscription Modal --><div id="subModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeSubModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-md border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-4"><h3 id="subTitle" class="text-sm font-semibold text-white"><i data-lucide="link" class="w-4 h-4 text-purple-400 inline"></i> 订阅链接</h3><button onclick="closeSubModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<p class="text-xs text-slate-500 mb-2">凭此链接可直接下载配置文件，无需登录。请妥善保管。</p>
<div class="flex gap-2"><input id="subUrl" type="text" readonly class="flex-1 px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-xs font-mono"><button onclick="copySubUrl()" class="px-3 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-xs"><i data-lucide="copy" class="w-3.5 h-3.5 inline"></i></button></div></div></div>
<!-- Server Limit Modal --><div id="serverLimitModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeServerLimitModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-sm border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-5"><h3 class="text-sm font-semibold text-white"><i data-lucide="server" class="w-4 h-4 text-amber-400 inline"></i> 服务器总流量上限</h3><button onclick="closeServerLimitModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<p id="serverLimitInfo" class="text-xs text-slate-500 mb-3">-</p>
<label class="block text-xs text-slate-400 mb-1">总流量上限（留空为无限制）</label>
<div class="flex gap-2 mb-2">
<input id="serverLimitInput" type="number" step="0.01" min="0" placeholder="例如 1000" class="flex-1 min-w-0 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<select id="serverLimitUnit" class="w-20 px-2 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm focus:border-blue-500/50 focus:ring-1 focus:ring-blue-500/30">
<option value="1">KB</option><option value="2">MB</option><option value="3" selected>GB</option><option value="4">TB</option>
</select>
</div>
<p class="text-[11px] text-slate-600 mb-3">超限后将自动禁用所有客户端，下个计费周期自动恢复。</p>
<div class="flex gap-3"><button onclick="closeServerLimitModal()" class="flex-1 py-2 rounded-xl bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm">取消</button><button onclick="saveServerLimit()" class="flex-1 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium">保存</button></div></div></div>
<!-- Client Detail Modal --><div id="detailModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeDetailModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-md border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()" style="max-height:85vh">
<div class="flex items-center justify-between mb-4"><h3 id="detailTitle" class="text-sm font-semibold text-white"><i data-lucide="info" class="w-4 h-4 text-blue-400 inline"></i> 连接信息</h3><button onclick="closeDetailModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<div id="detailContent" class="text-xs space-y-1.5 overflow-auto" style="max-height:60vh"></div>
<div class="flex gap-2 mt-4">
  <button onclick="showQR(currentDetailName)" class="flex-1 py-2 rounded-xl bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-xs"><i data-lucide="qr-code" class="w-3 h-3 inline"></i> QR</button>
  <button onclick="downloadConfig(currentDetailName)" class="flex-1 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-xs"><i data-lucide="download" class="w-3 h-3 inline"></i> 下载</button>
</div>
<div class="mt-3">
  <label class="block text-xs text-slate-400 mb-1">备注（最多40字）</label>
  <div class="flex gap-2"><input id="detailRemark" type="text" maxlength="40" placeholder="例如：张三-手机" class="flex-1 min-w-0 px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-xs placeholder-slate-500 focus:border-blue-500/50"><button onclick="saveRemark()" class="px-3 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-xs">保存</button></div>
</div></div></div>
<!-- Batch Add Modal --><div id="batchAddModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeBatchAddModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-sm border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-4"><h3 class="text-sm font-semibold text-white"><i data-lucide="list-plus" class="w-4 h-4 text-blue-400 inline"></i> 批量添加客户端</h3><button onclick="closeBatchAddModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<p class="text-xs text-slate-500 mb-2">每行一个名称（最多 50 个），仅支持字母/数字/下划线/短横线</p>
<textarea id="batchAddNames" rows="6" placeholder="client1&#10;client2&#10;phone-zhang" class="w-full px-3 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-xs placeholder-slate-500 focus:border-blue-500/50 font-mono"></textarea>
<p id="batchAddError" class="text-red-400 text-xs mt-2 hidden"></p>
<div id="batchAddResult" class="text-xs text-slate-400 mt-2 hidden"></div>
<div class="flex gap-3 mt-4"><button onclick="closeBatchAddModal()" class="flex-1 py-2 rounded-xl bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm">关闭</button><button onclick="submitBatchAdd()" class="flex-1 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium">添加</button></div></div></div>
<!-- Batch Settings Modal --><div id="batchSettingsModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeBatchSettingsModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-sm border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center justify-between mb-4"><h3 class="text-sm font-semibold text-white"><i data-lucide="sliders-horizontal" class="w-4 h-4 text-amber-400 inline"></i>批量设置 <span id="batchSettingsCount" class="text-slate-500 font-normal"></span></h3><button onclick="closeBatchSettingsModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<p class="text-xs text-slate-500 mb-3">留空的字段不会修改。</p>
<label class="block text-xs text-slate-400 mb-1">流量上限</label>
<div class="flex gap-2 mb-3">
<input id="bsLimit" type="number" step="0.01" min="0" placeholder="留空不修改" class="flex-1 min-w-0 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50">
<select id="bsLimitUnit" class="w-20 px-2 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm"><option value="1">KB</option><option value="2">MB</option><option value="3" selected>GB</option><option value="4">TB</option></select>
</div>
<label class="block text-xs text-slate-400 mb-1">到期时间 (YYYY-MM-DD)</label>
<input id="bsExpire" type="text" placeholder="留空不修改；输入 clear 清除" class="w-full mb-3 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-blue-500/50">
<label class="block text-xs text-slate-400 mb-1">重置周期</label>
<select id="bsCycle" class="w-full mb-2 px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm"><option value="">不修改</option><option value="natural">自然月</option><option value="30d">30天周期</option><option value="none">不自动重置</option></select>
<p id="bsError" class="text-red-400 text-xs mb-2 hidden"></p>
<div class="flex gap-3 mt-3"><button onclick="closeBatchSettingsModal()" class="flex-1 py-2 rounded-xl bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm">取消</button><button onclick="submitBatchSettings()" class="flex-1 py-2 rounded-xl bg-amber-600 hover:bg-amber-500 text-white text-sm font-medium">应用</button></div></div></div>
<!-- Audit Modal --><div id="auditModal" class="fixed inset-0 z-40 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeAuditModal()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-2xl border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()" style="max-height:85vh">
<div class="flex items-center justify-between mb-4"><h3 class="text-sm font-semibold text-white"><i data-lucide="scroll-text" class="w-4 h-4 text-blue-400 inline"></i> 登录审计</h3><button onclick="closeAuditModal()" class="text-slate-500 hover:text-slate-300"><i data-lucide="x" class="w-4 h-4"></i></button></div>
<div id="auditContent" class="text-xs overflow-auto" style="max-height:60vh"></div></div></div>
<!-- Confirm Modal --><div id="confirmModal" class="fixed inset-0 z-50 modal-overlay hidden items-center justify-center p-4" onclick="if(event.target===this)closeConfirm()">
<div class="modal-content stat-card rounded-2xl p-6 w-full max-w-sm border border-slate-700/50 shadow-2xl" onclick="event.stopPropagation()">
<div class="flex items-center gap-3 mb-4"><div id="confirmIcon" class="w-10 h-10 rounded-xl bg-yellow-500/15 flex items-center justify-center"><i data-lucide="alert-triangle" class="w-5 h-5 text-yellow-400"></i></div><div><h3 id="confirmTitle" class="text-sm font-semibold text-white">确认操作</h3><p id="confirmDesc" class="text-xs text-slate-400 mt-0.5"></p></div></div>
<div id="confirmExtra" class="hidden mb-3"><input id="confirmInput" type="text" placeholder="请输入 YES 确认" class="w-full px-4 py-2 rounded-xl bg-slate-800/60 border border-slate-700/50 text-white text-sm placeholder-slate-500 focus:border-red-500/50 focus:ring-1 focus:ring-red-500/30"></div>
<div class="flex gap-3"><button onclick="closeConfirm()" class="flex-1 py-2 rounded-xl bg-slate-700/50 hover:bg-slate-700 text-slate-300 text-sm">取消</button><button id="confirmBtn" onclick="confirmAction()" class="flex-1 py-2 rounded-xl bg-red-600 hover:bg-red-500 text-white text-sm font-medium">确认</button></div></div></div>
<!-- Toast --><div id="toast" class="fixed bottom-6 left-1/2 -translate-x-1/2 z-50 hidden"><div class="toast px-5 py-3 rounded-xl text-sm font-medium shadow-2xl flex items-center gap-2.5" id="toastInner"></div></div>
<script src="/static/app.js?v=11"></script>
<script>lucide.createIcons();</script></body></html>
EMBEDDASHEOF
  cat > "$WEB_DIR/static/app.js" << 'EMBEDJSEOF'
// ============================================================
// WireGuard Web UI v3 — All features
// ============================================================
let scene, camera, renderer, controls, centerNode, glowRing, starField;
let clientNodes = [], connections = [], flowParticles = [];
let animTime = 0, isThreeReady = false;
let clients = [], statusData = {}, pollTimer = null, filterQuery = '';
let selectedClients = new Set(), logTimer = null, trafficChart = null, currentConfigName = '';
let clientChart = null, currentClientChartName = '';
let lastClientSignature = '', lastTopoUpdate = 0;
let currentDetailName = '';
let sortField = 'name', sortDir = 'asc', filterMode = 'all';
let resTimer = null;

document.addEventListener('DOMContentLoaded', function() {
  showSkeleton(); initThreeJS(); initTrafficChart(); fetchStatus(); fetchClients(); fetchResources();
  pollTimer = setInterval(function() { fetchStatus(); fetchClients(); }, 10000);
  resTimer = setInterval(fetchResources, 15000);
  lucide.createIcons();
});

function showToast(msg, type) {
  type = type || 'info';
  var inner = document.getElementById('toastInner'), toast = document.getElementById('toast');
  if (!inner || !toast) return;
  var colors = { info: 'bg-slate-700 text-white', success: 'bg-green-700 text-white', error: 'bg-red-700 text-white' };
  var icons = { info: 'info', success: 'check-circle', error: 'alert-circle' };
  inner.className = colors[type] || colors.info;
  inner.innerHTML = '<i data-lucide="' + (icons[type]||'info') + '" class="w-4 h-4 flex-shrink-0"></i><span>' + msg + '</span>';
  toast.classList.remove('hidden');
  setTimeout(function() { toast.classList.add('hidden'); }, 3500);
  try { lucide.createIcons(); } catch(e) {}
}

function api(url, method, body) {
  method = method || 'GET';
  var opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (body) opts.body = JSON.stringify(body);
  return fetch(url, opts).then(function(r) {
    if (r.status === 401) { window.location.href = '/logout'; return Promise.reject(new Error('未认证')); }
    return r.text().then(function(txt) {
      var d;
      try { d = JSON.parse(txt); } catch(e) { throw new Error('响应格式错误'); }
      if (!r.ok) throw new Error(d.error || '请求失败');
      return d;
    });
  });
}

function showSkeleton() {
  var el = document.getElementById('clientList');
  if (!el) return;
  var h = '';
  for (var i = 0; i < 4; i++) {
    h += '<div class="flex items-center gap-3 py-3 px-1">';
    h += '  <div class="skel w-5 h-4"></div><div class="flex-1"><div class="skel w-24 h-4 mb-1.5"></div><div class="skel w-32 h-3"></div></div><div class="skel w-16 h-4"></div></div>';
  }
  el.innerHTML = h;
}

function fetchStatus() {
  api('/api/status').then(function(d) {
    statusData = d;
    var dot = document.getElementById('statusDot'), st = document.getElementById('statusText');
    if (d.running) {
      if (dot) dot.className = 'w-2.5 h-2.5 rounded-full bg-green-500 shadow-lg shadow-green-500/30';
      if (st) { st.textContent = '运行中'; st.className = 'text-lg sm:text-2xl font-bold text-green-400 mt-2'; }
    } else {
      if (dot) dot.className = 'w-2.5 h-2.5 rounded-full bg-red-500';
      if (st) { st.textContent = '已停止'; st.className = 'text-lg sm:text-2xl font-bold text-red-400 mt-2'; }
    }
    if (document.getElementById('portText')) document.getElementById('portText').textContent = d.port || '-';
    if (document.getElementById('clientCountText')) document.getElementById('clientCountText').textContent = (d.client_count != null) ? d.client_count + ' / 253' : '-';
    var tt = document.getElementById('trafficText');
    if (tt && d.sent_total_fmt != null) tt.innerHTML = '<span class="text-emerald-400">\u2191 ' + d.sent_total_fmt + '</span> <span class="text-slate-500 mx-1">/</span> <span class="text-blue-400">\u2193 ' + d.received_total_fmt + '</span>';
    var sl = document.getElementById('serverLimitText');
    if (sl) {
      if (d.server_limit > 0) {
        sl.innerHTML = '<span class="' + (d.server_percent >= 90 ? 'text-red-400' : (d.server_percent >= 70 ? 'text-yellow-400' : 'text-slate-300')) + '">' +
          d.server_used_fmt + ' / ' + d.server_limit_fmt + '</span>' +
          (d.server_blocked ? ' <span class="text-red-500 font-semibold">已超限</span>' : '');
      } else {
        sl.innerHTML = '<span class="text-slate-500">已用 ' + (d.server_used_fmt || '0 B') + ' · 无限制</span>';
      }
    }
  }).catch(function(e) { showToast('获取状态失败', 'error'); });
}

function fetchClients() {
  api('/api/clients').then(function(data) {
    clients = data || [];
    doFilter(filterQuery);
    if (isThreeReady) maybeUpdateTopology();
  }).catch(function(e) { showToast('获取客户端列表失败', 'error'); });
}

function doFilter(q) {
  filterQuery = q || '';
  renderClientList(applyView(clients));
}

function setFilter(mode) {
  filterMode = mode || 'all';
  document.querySelectorAll('.filter-btn').forEach(function(b) {
    if (b.dataset.filter === filterMode) b.className = 'filter-btn text-[11px] px-2 py-1 rounded-lg bg-blue-600/30 text-blue-400';
    else b.className = 'filter-btn text-[11px] px-2 py-1 rounded-lg bg-slate-700/40 text-slate-400 hover:text-white';
  });
  renderClientList(applyView(clients));
}
function onSortChange() {
  var el = document.getElementById('clientSort');
  sortField = el ? el.value : 'name';
  renderClientList(applyView(clients));
}
function toggleSortDir() {
  sortDir = (sortDir === 'asc') ? 'desc' : 'asc';
  var btn = document.getElementById('sortDirBtn');
  if (btn) btn.innerHTML = '<i data-lucide="arrow-' + (sortDir === 'asc' ? 'up' : 'down') + '" class="w-3.5 h-3.5"></i>';
  try { lucide.createIcons(); } catch(e) {}
  renderClientList(applyView(clients));
}
/* 搜索 + 筛选 + 排序 */
function applyView(list) {
  var q = (filterQuery || '').toLowerCase();
  var out = (list || []).filter(function(c) {
    if (q) {
      var hay = ((c.name||'') + ' ' + (c.remark||'') + ' ' + (c.ip||'')).toLowerCase();
      if (hay.indexOf(q) === -1) return false;
    }
    switch (filterMode) {
      case 'online':   return c.online && !c.disabled;
      case 'offline':  return !c.online && !c.disabled;
      case 'disabled': return c.disabled;
      case 'overdue':
        var over = c.limit > 0 && c.used >= c.limit;
        var expired = c.expire && new Date(c.expire) < new Date();
        return over || expired;
      case 'expiring':
        return (c.days_left != null && c.days_left >= 0 && c.days_left <= 7) || (c.expire && new Date(c.expire) < new Date());
      default: return true;
    }
  });
  out.sort(function(a, b) {
    var r;
    switch (sortField) {
      case 'used':    r = (a.used||0) - (b.used||0); break;
      case 'percent': r = (a.percent||0) - (b.percent||0); break;
      case 'expire':  r = String(a.expire||'9999').localeCompare(String(b.expire||'9999')); break;
      case 'status':  r = (a.disabled?2:(a.online?0:1)) - (b.disabled?2:(b.online?0:1)); break;
      default:        r = (a.name||'').localeCompare(b.name||'');
    }
    return sortDir === 'asc' ? r : -r;
  });
  return out;
}

function renderClientList(data) {
  var el = document.getElementById('clientList');
  if (!el) return;
  if (!data || !data.length) { el.innerHTML = '<div class="text-center text-slate-600 text-xs py-8">' + (filterQuery ? '无匹配客户端' : '暂无客户端') + '</div>'; return; }
  var html = '';
  data.forEach(function(c, i) {
    var online = c.online, disabled = c.disabled;
    var dotColor = disabled ? 'bg-red-500' : (online ? 'bg-green-500' : 'bg-slate-600');
    var st = disabled ? '禁用' : (online ? '在线' : '离线');
    var stColor = disabled ? 'text-red-400' : (online ? 'text-green-400' : 'text-slate-500');
    var nameClass = disabled ? 'text-sm font-medium text-slate-500 line-through' : 'text-sm font-medium text-white';
    var hs = c.handshake || '从未', hsClass = 'text-slate-500';
    if (hs.includes('second')) hsClass = 'text-emerald-400';
    else if (hs.includes('minute')) hsClass = 'text-yellow-400';
    var ep = c.endpoint || '-';
    var checked = selectedClients.has(c.name) ? 'checked' : '';
    var bar = progressBarHtml(c);
    var expBadge = expiryBadgeHtml(c);
    // Desktop
    html += '<div class="hidden md:flex items-center gap-2 py-2.5 px-1 rounded-lg ' + (disabled ? 'opacity-60' : '') + '">';
    html += '  <span class="w-5 flex-shrink-0"><input type="checkbox" class="client-cb accent-blue-500" data-name="' + escAttr(c.name) + '" ' + checked + ' onchange="toggleSelect(\'' + escAttr(c.name) + '\')"></span>';
    html += '  <div class="flex-1 min-w-0"><p class="' + nameClass + ' truncate cursor-pointer hover:text-blue-400" onclick="showDetail(\'' + escAttr(c.name) + '\')" title="点击查看连接信息">' + esc(c.name) + (c.remark ? ' <span class="text-[10px] text-slate-500 font-normal">(' + esc(c.remark) + ')</span>' : '') + expBadge + '</p>' + bar + '</div>';
    html += '  <span class="text-xs text-slate-500 w-24 hidden lg:block truncate">' + (c.ip||'') + '</span>';
    html += '  <span class="flex items-center gap-1.5 w-14 flex-shrink-0"><span class="w-1.5 h-1.5 rounded-full ' + dotColor + '"></span><span class="text-xs ' + stColor + '">' + st + '</span></span>';
    html += '  <span class="text-xs text-right w-20 hidden xl:block text-slate-400 flex-shrink-0">' + (c.sent||'0 B') + '</span>';
    html += '  <span class="text-xs text-right w-20 hidden xl:block text-slate-400 flex-shrink-0">' + (c.received||'0 B') + '</span>';
    html += '  <div class="flex gap-0.5 flex-shrink-0">';
    if (disabled) html += '    <button onclick="toggleClient(\'' + escAttr(c.name) + '\',true)" class="p-1.5 rounded-lg hover:bg-slate-700/50 text-green-500 hover:text-green-400 transition-colors" title="启用"><i data-lucide="play" class="w-3.5 h-3.5"></i></button>';
    else html += '    <button onclick="toggleClient(\'' + escAttr(c.name) + '\',false)" class="p-1.5 rounded-lg hover:bg-slate-700/50 text-slate-500 hover:text-red-400 transition-colors" title="停用"><i data-lucide="pause" class="w-3.5 h-3.5"></i></button>';
    html += '    <button onclick="downloadConfig(\'' + escAttr(c.name) + '\')" class="p-1.5 rounded-lg hover:bg-slate-700/50 text-slate-500 hover:text-green-400 transition-colors" title="下载配置"><i data-lucide="download" class="w-3.5 h-3.5"></i></button>';
    html += '    <button onclick="showQR(\'' + escAttr(c.name) + '\')" class="p-1.5 rounded-lg hover:bg-slate-700/50 text-slate-500 hover:text-blue-400 transition-colors" title="QR 码"><i data-lucide="qr-code" class="w-3.5 h-3.5"></i></button>';
    html += '    <button onclick="openMoreMenu(\'' + escAttr(c.name) + '\', event)" class="p-1.5 rounded-lg hover:bg-slate-700/50 text-slate-500 hover:text-white transition-colors" title="更多"><i data-lucide="more-vertical" class="w-3.5 h-3.5"></i></button>';
    html += '  </div></div>';
    // Mobile
    html += '<div class="md:hidden" style="position:relative;padding:10px 4px;border-bottom:1px solid rgba(148,163,184,0.06);' + (disabled ? 'opacity:0.6' : '') + '">';
    html += '  <div class="flex items-center gap-2 pr-16"><input type="checkbox" class="client-cb accent-blue-500" data-name="' + escAttr(c.name) + '" ' + checked + ' onchange="toggleSelect(\'' + escAttr(c.name) + '\')" style="width:14px;height:14px">';
    html += '  <span class="text-sm ' + nameClass + ' cursor-pointer" onclick="showDetail(\'' + escAttr(c.name) + '\')">' + esc(c.name) + (c.remark ? ' <span class="text-[10px] text-slate-500">(' + esc(c.remark) + ')</span>' : '') + '</span><span class="w-1.5 h-1.5 rounded-full ' + dotColor + '"></span><span class="text-xs ' + stColor + '">' + st + '</span></div>';
    html += '  <div class="pl-5 mt-1">' + bar + '</div>';
    html += '  <div class="flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-slate-500 mt-1 pl-5">';
    if (c.ip) html += '<span>' + esc(c.ip) + '</span>';
    if (c.sent) html += '<span class="text-emerald-400">\u2191' + c.sent + '</span>';
    if (c.received) html += '<span class="text-blue-400">\u2193' + c.received + '</span>';
    if (ep != '-') html += '<span class="text-slate-600 truncate max-w-[70px]">' + esc(ep) + '</span>';
    html += '    <span class="' + hsClass + '">' + hs + '</span>';
    html += '  </div><div style="position:absolute;top:8px;right:4px;display:flex;gap:1px">';
    html += '    <button onclick="showQR(\'' + escAttr(c.name) + '\')" class="p-1 rounded-lg hover:bg-slate-700/50 text-slate-500 hover:text-blue-400"><i data-lucide="qr-code" class="w-3 h-3"></i></button>';
    html += '    <button onclick="openMoreMenu(\'' + escAttr(c.name) + '\', event)" class="p-1 rounded-lg hover:bg-slate-700/50 text-slate-500 hover:text-white"><i data-lucide="more-vertical" class="w-3 h-3"></i></button>';
    html += '  </div></div>';
  });
  el.innerHTML = html;
  updateBatchUI();
  try { lucide.createIcons(); } catch(e) {}
}

/* 到期倒计时徽章 */
function expiryBadgeHtml(c) {
  if (c.days_left == null) return '';
  var d = c.days_left, cls, txt;
  if (d < 0) { cls = 'text-red-400 bg-red-500/15'; txt = '已过期'; }
  else if (d === 0) { cls = 'text-red-400 bg-red-500/15'; txt = '今日到期'; }
  else if (d <= 7) { cls = 'text-yellow-400 bg-yellow-500/15'; txt = '剩余' + d + '天'; }
  else { return ''; }
  return ' <span class="text-[10px] px-1.5 py-0.5 rounded ' + cls + ' font-normal">' + txt + '</span>';
}

/* 流量进度条 HTML */
function progressBarHtml(c) {
  if (!c.limit || c.limit <= 0) {
    return '<div class="flex items-center gap-1 mt-0.5 min-w-0"><span class="text-[10px] text-slate-500 truncate">已用 ' + (c.used_fmt||'0 B') + ' · 无限制</span></div>';
  }
  var pct = c.percent || 0;
  var barColor = pct >= 90 ? 'bg-red-500' : (pct >= 70 ? 'bg-yellow-500' : 'bg-emerald-500');
  var txtColor = pct >= 90 ? 'text-red-400' : (pct >= 70 ? 'text-yellow-400' : 'text-slate-500');
  var w = Math.min(pct, 100);
  return '<div class="flex items-center gap-1.5 mt-1 min-w-0"><div class="h-1 rounded-full bg-slate-700/60 overflow-hidden flex-shrink-0" style="width:64px"><div class="h-full ' + barColor + '" style="width:' + w + '%"></div></div>' +
         '<span class="text-[10px] ' + txtColor + ' truncate">' + (c.used_fmt||'0 B') + ' / ' + (c.limit_fmt||'') + ' (' + pct + '%)</span></div>';
}

/* ⋯ 更多操作菜单（fixed 定位，避免被列表 overflow 裁剪） */
var moreMenuEl = null;
function closeMoreMenu() {
  if (moreMenuEl) { moreMenuEl.remove(); moreMenuEl = null; }
}
function openMoreMenu(name, ev) {
  ev.stopPropagation();
  closeMoreMenu();
  var c = clients.filter(function(x){return x.name===name;})[0] || {};
  var items = [];
  if (c.disabled) items.push(['启用', 'play', 'toggleClient(\'' + escAttr(name) + '\',true)']);
  else items.push(['停用', 'pause', 'toggleClient(\'' + escAttr(name) + '\',false)']);
  items.push(['查看详情', 'info', 'showDetail(\'' + escAttr(name) + '\')']);
  items.push(['编辑限制', 'sliders-horizontal', 'openEditModal(\'' + escAttr(name) + '\')']);
  items.push(['重命名', 'pencil', 'renameClient(\'' + escAttr(name) + '\')']);
  items.push(['订阅链接', 'link', 'showSub(\'' + escAttr(name) + '\')']);
  items.push(['下载配置', 'download', 'downloadConfig(\'' + escAttr(name) + '\')']);
  items.push(['查看配置', 'eye', 'showConfig(\'' + escAttr(name) + '\')']);
  items.push(['流量图表', 'trending-up', 'showClientChart(\'' + escAttr(name) + '\')']);
  items.push(['重置流量', 'rotate-ccw', 'resetClient(\'' + escAttr(name) + '\')']);
  items.push(['删除', 'trash-2', 'confirmDeleteClient(\'' + escAttr(name) + '\')', 'text-red-400']);

  var menu = document.createElement('div');
  menu.className = 'fixed z-50 bg-slate-800 border border-slate-700/60 rounded-xl shadow-2xl py-1 min-w-[140px]';
  var html = '';
  items.forEach(function(it) {
    html += '<button onclick="closeMoreMenu();' + it[2] + '" class="w-full flex items-center gap-2 px-3 py-1.5 text-xs hover:bg-slate-700/60 ' + (it[3] || 'text-slate-300') + '">' +
            '<i data-lucide="' + it[1] + '" class="w-3.5 h-3.5"></i><span>' + it[0] + '</span></button>';
  });
  menu.innerHTML = html;
  document.body.appendChild(menu);
  moreMenuEl = menu;
  try { lucide.createIcons(); } catch(e) {}

  // 定位：优先显示在按钮下方，空间不足则向上
  var rect = ev.currentTarget.getBoundingClientRect();
  var mw = menu.offsetWidth, mh = menu.offsetHeight;
  var left = Math.min(rect.right - mw, window.innerWidth - mw - 8);
  if (left < 8) left = 8;
  var top = rect.bottom + 4;
  if (top + mh > window.innerHeight - 8) top = Math.max(8, rect.top - mh - 4);
  menu.style.left = left + 'px';
  menu.style.top = top + 'px';
}
document.addEventListener('click', function(e) {
  if (moreMenuEl && !moreMenuEl.contains(e.target)) closeMoreMenu();
});
window.addEventListener('resize', closeMoreMenu);
window.addEventListener('scroll', closeMoreMenu, true);

function esc(s) { if (!s) return ''; var d = document.createElement('div'); d.appendChild(document.createTextNode(s)); return d.innerHTML; }
function escAttr(s) { return (s||'').replace(/'/g,"\\'"); }

/* ---- 流量单位换算 ---- */
var UNIT_FACTORS = { '1': 1024, '2': 1048576, '3': 1073741824, '4': 1099511627776 };
var UNIT_LABELS = { '1': 'KB', '2': 'MB', '3': 'GB', '4': 'TB' };

/* 字节 → 最合适的显示单位（用于回填表单） */
function bytesToUnit(bytes) {
  if (!bytes || bytes <= 0) return { val: '', unit: '3' };
  if (bytes >= 1099511627776) return { val: (bytes / 1099511627776).toFixed(2).replace(/\.?0+$/, ''), unit: '4' };
  if (bytes >= 1073741824)    return { val: (bytes / 1073741824).toFixed(2).replace(/\.?0+$/, ''),    unit: '3' };
  if (bytes >= 1048576)       return { val: (bytes / 1048576).toFixed(2).replace(/\.?0+$/, ''),       unit: '2' };
  if (bytes >= 1024)          return { val: (bytes / 1024).toFixed(2).replace(/\.?0+$/, ''),          unit: '1' };
  return { val: String(bytes), unit: '3' };
}

/* 数值 + 单位 → 字节 */
function unitToBytes(val, unit) {
  var f = UNIT_FACTORS[unit] || UNIT_FACTORS['3'];
  var n = parseFloat(val);
  if (isNaN(n) || n < 0) return NaN;
  return Math.round(n * f);
}

function toggleSelect(name) {
  if (selectedClients.has(name)) selectedClients.delete(name); else selectedClients.add(name);
  updateBatchUI();
}
function toggleSelectAll() {
  var all = document.getElementById('selectAll');
  var cbs = document.querySelectorAll('.client-cb');
  cbs.forEach(function(cb) {
    cb.checked = all.checked;
    if (all.checked) selectedClients.add(cb.dataset.name); else selectedClients.delete(cb.dataset.name);
  });
  updateBatchUI();
}
function updateBatchUI() {
  var n = selectedClients.size;
  document.getElementById('batchBadge').textContent = n + ' 选中';
  document.getElementById('batchBadge').classList.toggle('hidden', n === 0);
  document.getElementById('batchDeleteBtn').classList.toggle('hidden', n === 0);
  document.getElementById('batchExportBtn').classList.toggle('hidden', n === 0);
  var bs = document.getElementById('batchSettingsBtn');
  if (bs) bs.classList.toggle('hidden', n === 0);
}
function batchDelete() {
  var names = Array.from(selectedClients);
  showConfirm('批量删除', '确认删除 ' + names.length + ' 个客户端？', function() {
    api('/api/clients/batch-delete', 'POST', { names: names }).then(function(d) {
      showToast('已删除 ' + d.deleted + ' 个', 'success');
      selectedClients.clear(); fetchClients();
    }).catch(function(e) { showToast('批量删除失败: ' + e.message, 'error'); });
  }, 'danger');
}
function batchExport() {
  var names = Array.from(selectedClients);
  if (!names.length) return;
  fetch('/api/clients/batch-export', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ names: names })
  }).then(function(r) {
    if (r.status === 401) { window.location.href = '/logout'; return Promise.reject(new Error('未认证')); }
    if (!r.ok) return r.json().then(function(d){ throw new Error(d.error || '导出失败'); });
    return r.blob();
  }).then(function(blob) {
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url; a.download = 'wireguard-clients.zip'; a.click();
    setTimeout(function(){ URL.revokeObjectURL(url); }, 1000);
    showToast('已导出 ' + names.length + ' 个客户端', 'success');
  }).catch(function(e) { showToast('导出失败: ' + e.message, 'error'); });
}

function openAddModal() {
  var m = document.getElementById('addModal'); m.classList.remove('hidden'); m.classList.add('flex');
  document.getElementById('newClientName').value = ''; document.getElementById('addError').classList.add('hidden');
  setTimeout(function() { document.getElementById('newClientName').focus(); }, 100);
}
function closeAddModal() { var m = document.getElementById('addModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function addClient() {
  var name = document.getElementById('newClientName').value.trim();
  var err = document.getElementById('addError');
  if (!name) { err.textContent = '名称不能为空'; err.classList.remove('hidden'); return; }
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) { err.textContent = '仅允许字母、数字、下划线、短横线'; err.classList.remove('hidden'); return; }
  err.classList.add('hidden');
  api('/api/clients', 'POST', { name: name }).then(function() {
    closeAddModal(); showToast('客户端 ' + name + ' 已添加', 'success');
    fetchClients(); setTimeout(fetchStatus, 500);
  }).catch(function(e) { showToast('添加失败: ' + e.message, 'error'); });
}

function toggleClient(name, enable) {
  var action = enable ? 'enable' : 'disable';
  api('/api/clients/' + name + '/' + action, 'POST').then(function() {
    showToast(name + (enable ? ' 已启用' : ' 已禁用'), 'success');
    fetchClients();
  }).catch(function(e) { showToast('操作失败: ' + e.message, 'error'); });
}

function confirmDeleteClient(name) {
  showConfirm('删除客户端', '确认删除 "' + name + '" 吗？', function() {
    api('/api/clients/' + encodeURIComponent(name), 'DELETE').then(function() {
      showToast('已删除', 'success'); fetchClients(); setTimeout(fetchStatus, 500);
    }).catch(function(e) { showToast('删除失败: ' + e.message, 'error'); });
  }, 'danger');
}

function showQR(name) {
  document.getElementById('qrTitle').textContent = name + ' QR';
  document.getElementById('qrImage').src = '/api/clients/' + encodeURIComponent(name) + '/qrcode?' + Date.now();
  document.getElementById('qrDownloadBtn').href = '/api/clients/' + encodeURIComponent(name) + '/qrcode?' + Date.now();
  var m = document.getElementById('qrModal'); m.classList.remove('hidden'); m.classList.add('flex');
}
function closeQRModal() { var m = document.getElementById('qrModal'); m.classList.add('hidden'); m.classList.remove('flex'); }

function showConfig(name) {
  currentConfigName = name;
  document.getElementById('configTitle').textContent = name + ' 配置';
  document.getElementById('configContent').textContent = '加载中...';
  var m = document.getElementById('configModal'); m.classList.remove('hidden'); m.classList.add('flex');
  api('/api/clients/' + encodeURIComponent(name) + '/config/raw').then(function(d) {
    document.getElementById('configContent').textContent = d.content || '无内容';
  }).catch(function(e) {
    document.getElementById('configContent').textContent = '加载失败: ' + e.message;
  });
}
function closeConfigModal() { var m = document.getElementById('configModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function downloadConfig(name) { var a = document.createElement('a'); a.href = '/api/clients/' + encodeURIComponent(name) + '/config'; a.download = name + '.conf'; a.click(); }

// ---- 编辑客户端限制 ----
function openEditModal(name) {
  var c = clients.filter(function(x){return x.name===name;})[0];
  if (!c) return;
  document.getElementById('editTitle').textContent = name + ' 限制设置';
  document.getElementById('editClientName').value = name;
  var u = bytesToUnit(c.limit);
  document.getElementById('editLimit').value = u.val;
  document.getElementById('editLimitUnit').value = u.unit;
  document.getElementById('editExpire').value = c.expire || '';
  document.getElementById('editCycle').value = c.cycle || '30d';
  document.getElementById('editDns').value = c.dns || '';
  document.getElementById('editRateDown').value = c.rate_down ? (c.rate_down/1048576) : '';
  document.getElementById('editRateUp').value = c.rate_up ? (c.rate_up/1048576) : '';
  document.getElementById('editOverQuota').value = c.over_quota_rate ? (c.over_quota_rate/1048576) : '';
  document.getElementById('editError').classList.add('hidden');
  var m = document.getElementById('editModal'); m.classList.remove('hidden'); m.classList.add('flex');
}
function closeEditModal() { var m = document.getElementById('editModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function saveEditClient() {
  var name = document.getElementById('editClientName').value;
  var val = document.getElementById('editLimit').value.trim();
  var unit = document.getElementById('editLimitUnit').value;
  var expire = document.getElementById('editExpire').value.trim();
  var cycle = document.getElementById('editCycle').value;
  var dns = document.getElementById('editDns').value.trim();
  var err = document.getElementById('editError');
  var limit = 0;
  if (val !== '') {
    limit = unitToBytes(val, unit);
    if (isNaN(limit)) { err.textContent = '流量上限无效'; err.classList.remove('hidden'); return; }
  }
  if (expire && !/^\d{4}-\d{2}-\d{2}$/.test(expire)) { err.textContent = '到期时间格式应为 YYYY-MM-DD'; err.classList.remove('hidden'); return; }
  if (dns && !/^[0-9a-fA-F:., ]+$/.test(dns)) { err.textContent = 'DNS 格式无效'; err.classList.remove('hidden'); return; }
  err.classList.add('hidden');
  api('/api/clients/' + encodeURIComponent(name) + '/settings', 'POST',
      { limit: limit, expire: expire, cycle: cycle, dns: dns }).then(function() {
var rd = document.getElementById('editRateDown').value.trim();
    var ru = document.getElementById('editRateUp').value.trim();
    var oq = document.getElementById('editOverQuota').value.trim();
    return api('/api/v1/clients/' + encodeURIComponent(name) + '/qos', 'POST',
      { rate_down: rd === '' ? 0 : parseFloat(rd),
        rate_up: ru === '' ? 0 : parseFloat(ru),
        over_quota_rate: oq === '' ? 0 : parseFloat(oq) });
  }).then(function() {
    showToast(name + ' 设置已保存', 'success');
    closeEditModal(); fetchClients();
  }).catch(function(e) { showToast('保存失败: ' + e.message, 'error'); });
}

// ---- 全局限速 ----
function openQosInSettings() {
  api('/api/v1/qos').then(function(d) {
    var a = document.getElementById('qosAlgo'); if (a) a.value = d.algo || 'htb';
    var td = document.getElementById('qosTotalDown'); if (td) td.value = d.total_down ? (d.total_down/1048576) : '';
    var tu = document.getElementById('qosTotalUp'); if (tu) tu.value = d.total_up ? (d.total_up/1048576) : '';
  }).catch(function(){});
}
function saveQos() {
  var algo = document.getElementById('qosAlgo').value;
  var td = document.getElementById('qosTotalDown').value.trim();
  var tu = document.getElementById('qosTotalUp').value.trim();
  api('/api/v1/qos', 'POST', {
    algo: algo,
    total_down: td === '' ? 0 : parseFloat(td),
    total_up: tu === '' ? 0 : parseFloat(tu)
  }).then(function() { showToast('全局限速已保存', 'success'); })
    .catch(function(e) { showToast('保存失败: ' + e.message, 'error'); });
}

// ---- 重命名客户端 ----
function renameClient(name) {
  var nn = prompt('将 "' + name + '" 重命名为：', name);
  if (!nn || nn === name) return;
  nn = nn.trim();
  if (!/^[a-zA-Z0-9_-]+$/.test(nn) || nn.length > 15) { showToast('名称仅允许字母/数字/下划线/短横线，最长15位', 'error'); return; }
  api('/api/clients/' + encodeURIComponent(name) + '/rename', 'POST', { new_name: nn }).then(function() {
    showToast('已重命名为 ' + nn, 'success'); fetchClients();
  }).catch(function(e) { showToast('重命名失败: ' + e.message, 'error'); });
}

// ---- 批量设置 ----
function openBatchSettingsModal() {
  if (!selectedClients.size) { showToast('请先选择客户端', 'error'); return; }
  document.getElementById('bsLimit').value = '';
  document.getElementById('bsExpire').value = '';
  document.getElementById('bsCycle').value = '';
  document.getElementById('bsError').classList.add('hidden');
  document.getElementById('batchSettingsCount').textContent = '(' + selectedClients.size + ' 个)';
  var m = document.getElementById('batchSettingsModal'); m.classList.remove('hidden'); m.classList.add('flex');
}
function closeBatchSettingsModal() { var m = document.getElementById('batchSettingsModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function submitBatchSettings() {
  var names = Array.from(selectedClients);
  var val = document.getElementById('bsLimit').value.trim();
  var unit = document.getElementById('bsLimitUnit').value;
  var expire = document.getElementById('bsExpire').value.trim();
  var cycle = document.getElementById('bsCycle').value;
  var err = document.getElementById('bsError');
  var body = { names: names };
  if (val !== '') {
    var limit = unitToBytes(val, unit);
    if (isNaN(limit)) { err.textContent = '流量上限无效'; err.classList.remove('hidden'); return; }
    body.limit = limit;
  }
  if (expire !== '') {
    if (expire === 'clear') { body.expire = ''; }
    else if (!/^\d{4}-\d{2}-\d{2}$/.test(expire)) { err.textContent = '到期时间格式应为 YYYY-MM-DD 或 clear'; err.classList.remove('hidden'); return; }
    else body.expire = expire;
  }
  if (cycle !== '') body.cycle = cycle;
  if (body.limit === undefined && body.expire === undefined && body.cycle === undefined) {
    err.textContent = '请至少填写一个要修改的字段'; err.classList.remove('hidden'); return;
  }
  err.classList.add('hidden');
  api('/api/clients/batch-settings', 'POST', body).then(function(d) {
    showToast('已更新 ' + d.changed + ' 个客户端', 'success');
    closeBatchSettingsModal(); selectedClients.clear(); fetchClients();
  }).catch(function(e) { showToast('批量设置失败: ' + e.message, 'error'); });
}

// ---- 单客户端流量图表 ----
function showClientChart(name) {
  currentClientChartName = name;
  document.getElementById('clientChartTitle').textContent = name + ' 流量（24小时）';
  var m = document.getElementById('clientChartModal'); m.classList.remove('hidden'); m.classList.add('flex');
  var canvas = document.getElementById('clientChart');
  if (clientChart) { clientChart.destroy(); clientChart = null; }
  var ctx = canvas.getContext('2d');
  clientChart = new Chart(ctx, {
    type: 'line',
    data: { labels: [], datasets: [
      { label: '发送', data: [], borderColor: '#34d399', backgroundColor: 'rgba(52,211,153,0.1)', fill: true, tension: 0.3, pointRadius: 0, borderWidth: 2 },
      { label: '接收', data: [], borderColor: '#60a5fa', backgroundColor: 'rgba(96,165,250,0.1)', fill: true, tension: 0.3, pointRadius: 0, borderWidth: 2 }
    ]},
    options: {
      responsive: true, maintainAspectRatio: false, resizeDelay: 100,
      plugins: { legend: { display: true, labels: { color: '#94a3b8', font: { size: 10 }, boxWidth: 10 } },
                 tooltip: { callbacks: { label: function(c) { return c.dataset.label + ': ' + fmtBytes(c.parsed.y); } } } },
      scales: {
        x: { display: true, grid: { display: false }, ticks: { color: '#475569', font: { size: 9 }, maxRotation: 0, autoSkip: true, maxTicksLimit: 6 } },
        y: { beginAtZero: true, grid: { color: 'rgba(148,163,184,0.06)' }, ticks: { color: '#64748b', font: { size: 9 }, maxTicksLimit: 4, callback: function(v) { return fmtBytes(v); } } }
      },
      interaction: { mode: 'index', intersect: false }
    }
  });
  api('/api/clients/' + encodeURIComponent(name) + '/traffic').then(function(data) {
    if (!data || !data.length) { return; }
    clientChart.data.labels = data.map(function(d) { return d.hour || ''; });
    clientChart.data.datasets[0].data = data.map(function(d) { return d.sent || 0; });
    clientChart.data.datasets[1].data = data.map(function(d) { return d.received || 0; });
    clientChart.update('none');
  }).catch(function() {});
}
function closeClientChartModal() {
  var m = document.getElementById('clientChartModal'); m.classList.add('hidden'); m.classList.remove('flex');
  if (clientChart) { clientChart.destroy(); clientChart = null; }
}

// ---- 订阅链接 ----
function showSub(name) {
  document.getElementById('subTitle').textContent = name + ' 订阅链接';
  document.getElementById('subUrl').value = '生成中...';
  var m = document.getElementById('subModal'); m.classList.remove('hidden'); m.classList.add('flex');
  api('/api/clients/' + encodeURIComponent(name) + '/token', 'POST').then(function(d) {
    document.getElementById('subUrl').value = d.url || '';
  }).catch(function(e) {
    document.getElementById('subUrl').value = '生成失败: ' + e.message;
  });
}
function closeSubModal() { var m = document.getElementById('subModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function copySubUrl() {
  var el = document.getElementById('subUrl');
  el.select(); el.setSelectionRange(0, 99999);
  try { document.execCommand('copy'); showToast('已复制到剪贴板', 'success'); } catch(e) { showToast('复制失败，请手动复制', 'error'); }
}

// ---- 客户端连接详情 ----
function showDetail(name) {
  currentDetailName = name;
  document.getElementById('detailTitle').textContent = name + ' 连接信息';
  document.getElementById('detailContent').innerHTML = '<div class="text-slate-500 py-4 text-center">加载中...</div>';
  document.getElementById('detailRemark').value = '';
  var m = document.getElementById('detailModal'); m.classList.remove('hidden'); m.classList.add('flex');
  api('/api/clients/' + encodeURIComponent(name) + '/detail').then(function(d) {
    document.getElementById('detailRemark').value = d.remark || '';
    var rows = [
      ['状态', d.disabled ? '<span class="text-red-400">已禁用</span>' : (d.online ? '<span class="text-green-400">在线</span>' : '<span class="text-slate-400">离线</span>')],
      ['内部 IP', esc(d.ip || '-')],
      ['公钥', '<span class="font-mono text-[10px] break-all">' + esc(d.pubkey || '-') + '</span>'],
      ['客户端端点', esc(d.endpoint || '-')],
      ['最近握手', esc(d.handshake || '从未')],
      ['上行流量', esc(d.sent || '0 B')],
      ['下行流量', esc(d.received || '0 B')],
      ['周期用量', esc(d.used_fmt || '0 B') + ' / ' + esc(d.limit_fmt || '无限制') + (d.limit > 0 ? ' (' + d.percent + '%)' : '')],
      ['重置周期', ({natural:'自然月', '30d':'30天', none:'不重置'})[d.cycle] || d.cycle || '-'],
      ['周期起点', esc(d.cycle_start || '-')],
      ['到期时间', d.expire ? esc(d.expire) + (d.days_left != null ? (d.days_left < 0 ? ' <span class="text-red-400">（已过期）</span>' : ' <span class="text-slate-500">（剩余 ' + d.days_left + ' 天）</span>') : '') : '永久'],
      ['客户端 DNS', esc(d.dns || '（全局默认）')],
      ['下行限速', d.rate_down > 0 ? fmtRate(d.rate_down) : '不限'],
      ['上行限速', d.rate_up > 0 ? fmtRate(d.rate_up) : '不限'],
      ['超配额降速', d.over_quota_rate > 0 ? fmtRate(d.over_quota_rate) + (d.throttled ? ' <span class="text-yellow-400">（已降速）</span>' : '') : (d.throttled ? '<span class="text-yellow-400">已降速</span>' : '封禁')],
      ['服务器端口', String(d.server_port || '-')],
      ['服务器公网', esc(d.public_ip || '-')],
    ];
    if (d.sub_url) rows.push(['订阅链接', '<span class="font-mono text-[10px] break-all">' + esc(d.sub_url) + '</span>']);
    var h = '';
    rows.forEach(function(r) {
      h += '<div class="flex gap-3 py-1.5 border-b border-slate-800/40"><span class="w-20 flex-shrink-0 text-slate-500">' + r[0] + '</span><span class="flex-1 text-slate-300 break-all">' + r[1] + '</span></div>';
    });
    document.getElementById('detailContent').innerHTML = h;
  }).catch(function(e) {
    document.getElementById('detailContent').innerHTML = '<div class="text-red-400 py-4">加载失败: ' + esc(e.message) + '</div>';
  });
}
function closeDetailModal() { var m = document.getElementById('detailModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function saveRemark() {
  var remark = document.getElementById('detailRemark').value.trim();
  api('/api/clients/' + encodeURIComponent(currentDetailName) + '/remark', 'POST', { remark: remark }).then(function() {
    showToast('备注已保存', 'success');
    fetchClients();
  }).catch(function(e) { showToast('保存失败: ' + e.message, 'error'); });
}

// ---- 重置流量 ----
function resetClient(name) {
  showConfirm('重置流量', '确认将 "' + name + '" 的已用流量清零？', function() {
    api('/api/clients/' + encodeURIComponent(name) + '/reset', 'POST').then(function() {
      showToast(name + ' 流量已重置', 'success');
      fetchClients();
    }).catch(function(e) { showToast('重置失败: ' + e.message, 'error'); });
  }, 'warning');
}

// ---- 批量添加 ----
function openBatchAddModal() {
  document.getElementById('batchAddNames').value = '';
  document.getElementById('batchAddError').classList.add('hidden');
  document.getElementById('batchAddResult').classList.add('hidden');
  var m = document.getElementById('batchAddModal'); m.classList.remove('hidden'); m.classList.add('flex');
}
function closeBatchAddModal() { var m = document.getElementById('batchAddModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function submitBatchAdd() {
  var raw = document.getElementById('batchAddNames').value.split('\n').map(function(s){return s.trim();}).filter(Boolean);
  var err = document.getElementById('batchAddError');
  if (!raw.length) { err.textContent = '请输入至少一个名称'; err.classList.remove('hidden'); return; }
  if (raw.length > 50) { err.textContent = '单次最多 50 个'; err.classList.remove('hidden'); return; }
  err.classList.add('hidden');
  api('/api/clients/batch-add', 'POST', { names: raw }).then(function(d) {
    var res = document.getElementById('batchAddResult');
    res.classList.remove('hidden');
    res.innerHTML = '成功 ' + d.added.length + ' 个' + (d.added.length ? '：' + esc(d.added.join(', ')) : '') +
                    (d.errors.length ? '<br><span class="text-red-400">失败 ' + d.errors.length + ' 个</span>' : '');
    showToast('批量添加完成', 'success');
    fetchClients();
  }).catch(function(e) { err.textContent = '添加失败: ' + e.message; err.classList.remove('hidden'); });
}

// ---- 导出全部 ----
function exportAll() {
  showToast('正在打包...', 'info');
  fetch('/api/clients/export-all').then(function(r) {
    if (r.status === 401) { window.location.href = '/logout'; return Promise.reject(new Error('未认证')); }
    if (!r.ok) return r.json().then(function(d){ throw new Error(d.error || '导出失败'); });
    return r.blob();
  }).then(function(blob) {
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url; a.download = 'wireguard-all-' + new Date().toISOString().slice(0,10).replace(/-/g,'') + '.zip';
    a.click();
    setTimeout(function(){ URL.revokeObjectURL(url); }, 1000);
    showToast('已导出全部配置', 'success');
  }).catch(function(e) { showToast('导出失败: ' + e.message, 'error'); });
}

// ---- 登录审计 ----
function openAuditModal() {
  document.getElementById('auditContent').innerHTML = '<div class="text-slate-500 py-4 text-center">加载中...</div>';
  var m = document.getElementById('auditModal'); m.classList.remove('hidden'); m.classList.add('flex');
  api('/api/audit?limit=100').then(function(list) {
    if (!list || !list.length) { document.getElementById('auditContent').innerHTML = '<div class="text-center text-slate-600 py-4">暂无记录</div>'; return; }
    var h = '<table class="w-full text-left"><thead><tr class="text-slate-500"><th class="py-1.5 pr-2 font-medium">时间</th><th class="py-1.5 pr-2 font-medium">操作</th><th class="py-1.5 pr-2 font-medium">详情</th><th class="py-1.5 font-medium">来源 IP</th></tr></thead><tbody>';
    list.forEach(function(a) {
      var cls = a.action.indexOf('失败') >= 0 ? 'text-red-400' : (a.action.indexOf('成功') >= 0 ? 'text-emerald-400' : 'text-slate-300');
      h += '<tr class="border-t border-slate-800/40"><td class="py-1.5 pr-2 text-slate-500 whitespace-nowrap">' + esc(a.ts) + '</td>' +
           '<td class="py-1.5 pr-2 ' + cls + ' whitespace-nowrap">' + esc(a.action) + '</td>' +
           '<td class="py-1.5 pr-2 text-slate-400">' + esc(a.detail || '') + '</td>' +
           '<td class="py-1.5 text-slate-500 font-mono text-[10px]">' + esc(a.ip || '-') + '</td></tr>';
    });
    h += '</tbody></table>';
    document.getElementById('auditContent').innerHTML = h;
  }).catch(function(e) {
    document.getElementById('auditContent').innerHTML = '<div class="text-red-400 py-4">加载失败: ' + esc(e.message) + '</div>';
  });
}
function closeAuditModal() { var m = document.getElementById('auditModal'); m.classList.add('hidden'); m.classList.remove('flex'); }

// ---- 服务器资源 ----
function fetchResources() {
  api('/api/resources').then(function(d) {
    function set(id, pct) {
      var b = document.getElementById(id + 'Bar'); if (b) b.style.width = Math.min(pct, 100) + '%';
    }
    var ct = document.getElementById('cpuText');
    if (ct) ct.textContent = d.cpu + '%';
    set('cpu', d.cpu);
    var lt = document.getElementById('loadText');
    if (lt) lt.textContent = '负载 ' + (d.load||[0,0,0]).join(' / ');
    var mt = document.getElementById('memText');
    if (mt) mt.textContent = (d.mem_used_fmt||'') + ' / ' + (d.mem_total_fmt||'');
    set('mem', d.mem_pct);
    var dt = document.getElementById('diskText');
    if (dt) dt.textContent = (d.disk_used_fmt||'') + ' / ' + (d.disk_total_fmt||'');
    set('disk', d.disk_pct);
    var ut = document.getElementById('uptimeText');
    if (ut) ut.textContent = '运行 ' + fmtUptime(d.uptime);
  }).catch(function() {});
}
function fmtUptime(s) {
  s = parseInt(s || 0, 10);
  var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d > 0) return d + '天 ' + h + '小时';
  if (h > 0) return h + '小时 ' + m + '分';
  return m + '分钟';
}

// ---- 服务器总流量限制 ----
function openServerLimitModal() {
  api('/api/server-limit').then(function(d) {
    var u = bytesToUnit(d.limit);
    document.getElementById('serverLimitInput').value = u.val;
    document.getElementById('serverLimitUnit').value = u.unit;
    document.getElementById('serverLimitInfo').textContent =
      '已用 ' + fmtBytes(d.used || 0) + (d.blocked ? ' · 已超限禁用' : '');
  }).catch(function() {});
  var m = document.getElementById('serverLimitModal'); m.classList.remove('hidden'); m.classList.add('flex');
}
function closeServerLimitModal() { var m = document.getElementById('serverLimitModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function saveServerLimit() {
  var val = document.getElementById('serverLimitInput').value.trim();
  var unit = document.getElementById('serverLimitUnit').value;
  var limit = 0;
  if (val !== '') {
    limit = unitToBytes(val, unit);
    if (isNaN(limit)) { showToast('流量上限无效', 'error'); return; }
  }
  api('/api/server-limit', 'POST', { limit: limit }).then(function() {
    showToast('服务器总流量上限已保存', 'success');
    closeServerLimitModal(); fetchStatus();
  }).catch(function(e) { showToast('保存失败: ' + e.message, 'error'); });
}

function confirmRestart() {
  showConfirm('重启 WireGuard', '确认重启？客户端将短暂断开。', function() {
    api('/api/restart','POST').then(function() { showToast('已重启','success'); setTimeout(function() { fetchStatus(); fetchClients(); }, 2000); }).catch(function(e) { showToast('重启失败: ' + e.message,'error'); });
  }, 'warning');
}
function confirmUninstall() {
  showConfirm('卸载 WireGuard', '将删除所有配置和客户端！', function() {
    showConfirmExtra('确认卸载', '请输入 YES 确认', function() {
      if (document.getElementById('confirmInput').value !== 'YES') { showToast('请输入 YES','error'); return; }
      closeConfirm(); showToast('正在卸载...','info');
      api('/api/uninstall','POST',{confirm:'YES'}).then(function() { showToast('已卸载','success'); setTimeout(function() { window.location.href = '/logout'; }, 2000); }).catch(function(e) { showToast('卸载失败: ' + e.message,'error'); });
    });
  }, 'danger');
}

// ---- Logs ----
function openLogModal() {
  var m = document.getElementById('logModal'); m.classList.remove('hidden'); m.classList.add('flex');
  refreshLogs();
  if (document.getElementById('logAutoRefresh').checked) {
    logTimer = setInterval(refreshLogs, 5000);
  }
}
function closeLogModal() {
  var m = document.getElementById('logModal'); m.classList.add('hidden'); m.classList.remove('flex');
  if (logTimer) { clearInterval(logTimer); logTimer = null; }
}
function toggleLogRefresh() {
  if (logTimer) { clearInterval(logTimer); logTimer = null; }
  if (document.getElementById('logAutoRefresh').checked) { logTimer = setInterval(refreshLogs, 5000); }
}
function refreshLogs() {
  api('/api/logs?lines=100').then(function(d) {
    var el = document.getElementById('logContent');
    if (!el) return;
    if (!d.logs || !d.logs.length) { el.textContent = '暂无日志'; return; }
    el.innerHTML = d.logs.map(function(line) {
      var cls = 'log-line-info';
      if (line.toLowerCase().includes('error') || line.toLowerCase().includes('fail')) cls = 'log-line-error';
      else if (line.toLowerCase().includes('warn')) cls = 'log-line-warn';
      return '<div class="' + cls + '">' + esc(line) + '</div>';
    }).join('');
    el.scrollTop = el.scrollHeight;
  }).catch(function() {});
}

// ---- Backups ----
function openBackupModal() {
  var m = document.getElementById('backupModal'); m.classList.remove('hidden'); m.classList.add('flex');
  refreshBackupList();
}
function closeBackupModal() { var m = document.getElementById('backupModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function createBackup() {
  showToast('正在备份...', 'info');
  api('/api/backup', 'POST').then(function(d) {
    showToast('备份完成: ' + d.name, 'success');
    refreshBackupList();
  }).catch(function(e) { showToast('备份失败: ' + e.message, 'error'); });
}
function refreshBackupList() {
  api('/api/backup/list').then(function(backups) {
    var el = document.getElementById('backupList');
    if (!backups || !backups.length) { el.innerHTML = '<div class="text-center text-xs text-slate-600 py-4">暂无备份</div>'; return; }
    el.innerHTML = backups.map(function(b) {
      var size = b.size > 1048576 ? (b.size/1048576).toFixed(1)+'MB' : (b.size/1024).toFixed(1)+'KB';
      return '<div class="flex items-center justify-between py-1.5 px-2 rounded-lg hover:bg-slate-800/40">' +
        '<div><p class="text-xs text-white">' + esc(b.name) + '</p><p class="text-xs text-slate-500">' + size + ' / ' + esc(b.mtime) + '</p></div>' +
        '<button onclick="restoreBackup(\'' + escAttr(b.name) + '\')" class="text-xs px-2 py-1 rounded-lg bg-yellow-600/20 text-yellow-400 hover:bg-yellow-600/30">恢复</button></div>';
    }).join('');
    try { lucide.createIcons(); } catch(e) {}
  }).catch(function() {});
}
function restoreBackup(name) {
  showConfirm('恢复备份', '确认恢复 ' + name + '？当前配置将被覆盖。', function() {
    api('/api/restore', 'POST', { name: name }).then(function() {
      showToast('恢复完成', 'success');
      setTimeout(function() { fetchStatus(); fetchClients(); }, 2000);
    }).catch(function(e) { showToast('恢复失败: ' + e.message, 'error'); });
  }, 'danger');
}

// ---- Settings / Change Password ----
function openSettingsModal() {
  document.getElementById('oldPassword').value = '';
  document.getElementById('newPassword').value = '';
  document.getElementById('pwdError').classList.add('hidden');
  openQosInSettings();
  var m = document.getElementById('settingsModal'); m.classList.remove('hidden'); m.classList.add('flex');
}
function closeSettingsModal() { var m = document.getElementById('settingsModal'); m.classList.add('hidden'); m.classList.remove('flex'); }
function changePassword() {
  var old = document.getElementById('oldPassword').value;
  var pwd = document.getElementById('newPassword').value;
  var err = document.getElementById('pwdError');
  if (!old) { err.textContent = '请输入原密码'; err.classList.remove('hidden'); return; }
  if (pwd.length < 6) { err.textContent = '新密码至少6个字符'; err.classList.remove('hidden'); return; }
  err.classList.add('hidden');
  api('/api/change-password', 'POST', { old_password: old, new_password: pwd }).then(function() {
    showToast('密码已修改', 'success');
    closeSettingsModal();
  }).catch(function(e) { showToast('修改失败: ' + e.message, 'error'); });
}

// ---- Traffic Chart ----
function initTrafficChart() {
  var canvas = document.getElementById('trafficChart');
  if (!canvas || trafficChart) return;
  var ctx = canvas.getContext('2d');
  trafficChart = new Chart(ctx, {
    type: 'line',
    data: { labels: [], datasets: [
      { label: '发送', data: [], borderColor: '#34d399', backgroundColor: 'rgba(52,211,153,0.1)', fill: true, tension: 0.3, pointRadius: 0, borderWidth: 2 },
      { label: '接收', data: [], borderColor: '#60a5fa', backgroundColor: 'rgba(96,165,250,0.1)', fill: true, tension: 0.3, pointRadius: 0, borderWidth: 2 }
    ]},
    options: {
      responsive: true, maintainAspectRatio: false, resizeDelay: 100,
      plugins: { legend: { display: false }, tooltip: { callbacks: { label: function(c) { return c.dataset.label + ': ' + fmtBytes(c.parsed.y); } } } },
      scales: {
        x: { display: true, grid: { display: false }, ticks: { color: '#475569', font: { size: 9 }, maxRotation: 0, autoSkip: true, maxTicksLimit: 6 } },
        y: { beginAtZero: true, grid: { color: 'rgba(148,163,184,0.06)' }, ticks: { color: '#64748b', font: { size: 9 }, maxTicksLimit: 4, callback: function(v) { return fmtBytes(v); } } }
      },
      interaction: { mode: 'index', intersect: false }
    }
  });
  fetchTrafficHistory();
  setInterval(fetchTrafficHistory, 60000);
}
function fmtBytes(v) {
  if (v >= 1099511627776) return (v/1099511627776).toFixed(2) + 'TB';
  if (v >= 1073741824) return (v/1073741824).toFixed(2) + 'GB';
  if (v >= 1048576) return (v/1048576).toFixed(1) + 'MB';
  if (v >= 1024) return (v/1024).toFixed(0) + 'KB';
  return v + 'B';
}
function fmtRate(bps) {
  if (!bps) return '不限';
  return (bps/1048576).toFixed(bps % 1048576 === 0 ? 0 : 1) + ' MB/s';
}
function fetchTrafficHistory() {
  if (!trafficChart) return;
  api('/api/traffic/history').then(function(data) {
    if (!data || !data.length) {
      trafficChart.data.labels = [];
      trafficChart.data.datasets[0].data = [];
      trafficChart.data.datasets[1].data = [];
      trafficChart.update('none');
      return;
    }
    trafficChart.data.labels = data.map(function(d) { return d.hour || ''; });
    trafficChart.data.datasets[0].data = data.map(function(d) { return d.sent || 0; });
    trafficChart.data.datasets[1].data = data.map(function(d) { return d.received || 0; });
    trafficChart.update('none');
  }).catch(function() {});
}

// ---- Confirm Modal ----
var confirmCallback = null;
function showConfirm(title, desc, cb, type) {
  type = type || 'warning';
  document.getElementById('confirmTitle').textContent = title; document.getElementById('confirmDesc').textContent = desc;
  var icon = document.getElementById('confirmIcon');
  if (type === 'danger') { icon.innerHTML = '<i data-lucide="alert-triangle" class="w-5 h-5 text-red-400"></i>'; document.getElementById('confirmBtn').className = 'flex-1 py-2 rounded-xl bg-red-600 hover:bg-red-500 text-white text-sm font-medium'; }
  else { icon.innerHTML = '<i data-lucide="alert-triangle" class="w-5 h-5 text-yellow-400"></i>'; document.getElementById('confirmBtn').className = 'flex-1 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium'; }
  document.getElementById('confirmExtra').classList.add('hidden'); confirmCallback = cb;
  var m = document.getElementById('confirmModal'); m.classList.remove('hidden'); m.classList.add('flex');
  try { lucide.createIcons(); } catch(e) {}
}
function showConfirmExtra(title, desc, cb) {
  document.getElementById('confirmTitle').textContent = title; document.getElementById('confirmDesc').textContent = desc;
  document.getElementById('confirmIcon').innerHTML = '<i data-lucide="alert-triangle" class="w-5 h-5 text-red-400"></i>';
  document.getElementById('confirmBtn').className = 'flex-1 py-2 rounded-xl bg-red-600 hover:bg-red-500 text-white text-sm font-medium';
  document.getElementById('confirmExtra').classList.remove('hidden'); document.getElementById('confirmInput').value = '';
  confirmCallback = cb; var m = document.getElementById('confirmModal'); m.classList.remove('hidden'); m.classList.add('flex');
  setTimeout(function() { document.getElementById('confirmInput').focus(); }, 100);
  try { lucide.createIcons(); } catch(e) {}
}
function confirmAction() { if (confirmCallback) confirmCallback(); }
function closeConfirm() { document.getElementById('confirmModal').classList.add('hidden'); document.getElementById('confirmModal').classList.remove('flex'); confirmCallback = null; }

// ---- Three.js ----
function initThreeJS() {
  var container = document.getElementById('topology');
  if (!container) return;
  var w = container.clientWidth, h = container.clientHeight;
  if (w < 1 || h < 1) { w = 400; h = 300; }
  scene = new THREE.Scene(); scene.background = new THREE.Color(0x0f172a);
  camera = new THREE.PerspectiveCamera(45, w/h, 0.1, 1000);
  camera.position.set(8,5,12); camera.lookAt(0,0,0);
  renderer = new THREE.WebGLRenderer({ antialias:true, alpha:true });
  renderer.setSize(w,h); renderer.setPixelRatio(Math.min(window.devicePixelRatio,2));
  container.appendChild(renderer.domElement);
  controls = new THREE.OrbitControls(camera,renderer.domElement);
  controls.enableDamping=true; controls.dampingFactor=0.05;
  controls.autoRotate=true; controls.autoRotateSpeed=0.8;
  controls.minDistance=4; controls.maxDistance=30; controls.target.set(0,0,0);
  var starGeo = new THREE.BufferGeometry();
  var starPos = new Float32Array(3600);
  for (var i=0;i<3600;i++) starPos[i] = (Math.random()-0.5)*80;
  starGeo.setAttribute('position',new THREE.BufferAttribute(starPos,3));
  starField = new THREE.Points(starGeo,new THREE.PointsMaterial({color:0x94a3b8,size:0.08,transparent:true,opacity:0.6}));
  scene.add(starField);
  scene.add(new THREE.AmbientLight(0x334155,0.5));
  var dl=new THREE.DirectionalLight(0xffffff,0.8); dl.position.set(10,20,5); scene.add(dl);
  scene.add(new THREE.PointLight(0x3b82f6,0.5,20));
  centerNode=new THREE.Mesh(new THREE.SphereGeometry(0.8,32,32),new THREE.MeshPhongMaterial({color:0x3b82f6,emissive:0x1d4ed8,emissiveIntensity:0.4,shininess:80}));
  scene.add(centerNode);
  scene.add(new THREE.Mesh(new THREE.SphereGeometry(1.0,32,32),new THREE.MeshBasicMaterial({color:0x3b82f6,transparent:true,opacity:0.15})));
  glowRing=new THREE.Mesh(new THREE.TorusGeometry(1.3,0.03,16,64),new THREE.MeshBasicMaterial({color:0x60a5fa,transparent:true,opacity:0.4}));
  glowRing.rotation.x=Math.PI/3; scene.add(glowRing);
  var r2=new THREE.Mesh(new THREE.TorusGeometry(1.6,0.02,16,64),new THREE.MeshBasicMaterial({color:0x93c5fd,transparent:true,opacity:0.25}));
  r2.rotation.x=-Math.PI/4; r2.rotation.z=Math.PI/6; scene.add(r2);
  var raycaster=new THREE.Raycaster(), mouse=new THREE.Vector2(), tooltip=document.getElementById('topologyTooltip');
  renderer.domElement.addEventListener('mousemove',function(event){
    var rect=renderer.domElement.getBoundingClientRect();
    mouse.x=((event.clientX-rect.left)/rect.width)*2-1; mouse.y=-((event.clientY-rect.top)/rect.height)*2+1;
    raycaster.setFromCamera(mouse,camera);
    var hits=raycaster.intersectObjects(clientNodes);
    if(hits.length>0&&hits[0].object.userData.name){
      var u=hits[0].object.userData;
      tooltip.style.display='block'; tooltip.style.left=(event.clientX-rect.left+12)+'px'; tooltip.style.top=(event.clientY-rect.top-10)+'px';
      tooltip.innerHTML='<b>'+esc(u.name)+'</b><br>IP: '+(u.ip||'-')+'<br>\u2191 '+(u.sent||'0 B')+' \u2193 '+(u.received||'0 B');
    } else tooltip.style.display='none';
  });
  window.addEventListener('resize',onResize);
  isThreeReady=true;
  animate();
}
function onResize(){
  var c=document.getElementById('topology');if(!c||!renderer||!camera)return;
  var w=c.clientWidth,h=c.clientHeight;if(w<1||h<1)return;
  camera.aspect=w/h;camera.updateProjectionMatrix();renderer.setSize(w,h);
}
function animate(){
  requestAnimationFrame(animate); animTime+=0.01;
  if(glowRing){glowRing.rotation.y+=0.008;glowRing.rotation.x=Math.PI/3+Math.sin(animTime*0.5)*0.1;}
  if(centerNode)centerNode.scale.setScalar(1+Math.sin(animTime*2)*0.03);
  flowParticles.forEach(function(p){
    p.progress+=p.speed;if(p.progress>1)p.progress=0;
    if(p.lineGeom&&p.mesh){
      var pos=new THREE.Vector3(),arr=p.lineGeom.attributes.position.array;
      var idx=Math.floor(p.progress*((arr.length/3)-1)),frac=p.progress*((arr.length/3)-1)-idx;
      var i3=idx*3,i3n=Math.min((idx+1)*3,arr.length-3);
      pos.x=arr[i3]+(arr[i3n]-arr[i3])*frac;pos.y=arr[i3+1]+(arr[i3n+1]-arr[i3+1])*frac;pos.z=arr[i3+2]+(arr[i3n+2]-arr[i3+2])*frac;
      p.mesh.position.copy(pos);
    }
  });
  controls.update();renderer.render(scene,camera);
}
function getTrafficBytes(s){
  if(!s||s==='0 B')return 0;
  var parts=s.split(' '),v=parseFloat(parts[0]),u=(parts[1]||'').toLowerCase();
  if(u==='kib')return v*1024;if(u==='mib')return v*1048576;if(u==='gib')return v*1073741824;
  return v;
}
/* 释放场景中所有拓扑相关对象（含几何体/材质），避免显存泄漏 */
function clearTopology(){
  function disposeObj(o){
    scene.remove(o);
    if(o.geometry) o.geometry.dispose();
    if(o.material){
      if(Array.isArray(o.material)) o.material.forEach(function(m){m.dispose();});
      else o.material.dispose();
    }
  }
  clientNodes.forEach(disposeObj); clientNodes=[];
  connections.forEach(disposeObj); connections=[];
  flowParticles.forEach(function(p){ if(p.mesh) disposeObj(p.mesh); }); flowParticles=[];
}
/* 仅当数据变化或超时（30s）时才重建拓扑，减少无谓重建 */
function maybeUpdateTopology(){
  if(!isThreeReady) return;
  var sig=JSON.stringify(clients.map(function(c){return [c.name,c.online,c.disabled,c.sent,c.received];}));
  var now=Date.now();
  if(sig===lastClientSignature && now-lastTopoUpdate<30000) return;
  lastTopoUpdate=now;
  updateTopology();
}
function updateTopology(){
  if(!isThreeReady||!scene)return;
  clearTopology();
  if(!clients.length)return;
  var radius=4.5,count=clients.length;
  clients.forEach(function(c,i){
    var angle=(i/count)*Math.PI*2,x=Math.cos(angle)*radius,z=Math.sin(angle)*radius,y=(Math.random()-0.5)*1.5;
    var online=c.online,disabled=c.disabled,traffic=getTrafficBytes(c.sent)+getTrafficBytes(c.received);
    var ss=Math.min(1+Math.log2(1+traffic)*0.04,1.6),bs=0.35*ss;
    var col,emCol,emInt;
    if(disabled){col=0xdc2626;emCol=0x000000;emInt=0;}
    else if(online&&traffic>0){col=0x22c55e;emCol=0x16a34a;emInt=0.4;}
    else if(online){col=0x3b82f6;emCol=0x1d4ed8;emInt=0.2;}
    else{col=0x64748b;emCol=0x000000;emInt=0;}
    var mesh=new THREE.Mesh(new THREE.SphereGeometry(bs,20,20),new THREE.MeshPhongMaterial({color:col,emissive:emCol,emissiveIntensity:emInt,shininess:60}));
    mesh.position.set(x,y,z);mesh.userData={name:c.name,ip:c.ip,sent:c.sent,received:c.received,handshake:c.handshake,traffic:traffic};
    scene.add(mesh);clientNodes.push(mesh);
    if(online&&!disabled){
      var ring=new THREE.Mesh(new THREE.RingGeometry(bs*1.15,bs*1.35,24),new THREE.MeshBasicMaterial({color:traffic>0?0x22c55e:0x3b82f6,transparent:true,opacity:0.25,side:THREE.DoubleSide}));
      ring.position.set(x,y,z);ring.lookAt(camera.position);scene.add(ring);clientNodes.push(ring);
    }
    var pts=[];for(var j=0;j<=30;j++){var t=j/30;pts.push(new THREE.Vector3(x*t,y*t+Math.sin(t*Math.PI)*0.5,z*t));}
    var lg=new THREE.BufferGeometry().setFromPoints(pts);
    var lc=(online&&!disabled&&traffic>0)?0x3b82f6:(online&&!disabled?0x60a5fa:0x475569);
    var lo=(online&&!disabled&&traffic>0)?0.6:(online&&!disabled?0.35:0.15);
    var line=new THREE.Line(lg,new THREE.LineBasicMaterial({color:lc,transparent:true,opacity:lo}));
    scene.add(line);connections.push(line);   /* 已修复：保存引用以便清理 */
    if(online&&!disabled){
      var ps=0.04+Math.min(traffic/1048576,10)*0.005,pc=traffic>0?0x22c55e:0x60a5fa;
      var pt=new THREE.Mesh(new THREE.SphereGeometry(ps,6,6),new THREE.MeshBasicMaterial({color:pc}));
      scene.add(pt);
      flowParticles.push({mesh:pt,lineGeom:lg,progress:Math.random(),speed:0.005+(traffic/1048576)*0.002});
    }
  });
  lastClientSignature=JSON.stringify(clients.map(function(c){return [c.name,c.online,c.disabled,c.sent,c.received];}));
}
window.addEventListener('beforeunload',function(){if(pollTimer)clearInterval(pollTimer);});
EMBEDJSEOF
  echo "已部署 Web UI"

  # 安装 Python 依赖并探测解释器
  install_python_deps
  PYTHON_BIN=$(detect_python)
  if [ -z "$PYTHON_BIN" ]; then
    echo "错误：未找到具备 Flask/Werkzeug/qrcode 的 Python 解释器，Web UI 无法部署。" >&2
    echo "       请手动执行：apt install python3-flask python3-werkzeug python3-qrcode python3-pil" >&2
    deploy_web=0
    return 1
  fi
  echo "使用 Python 解释器：$PYTHON_BIN"

  if [ "$auto" != 0 ]; then
    web_username="admin_$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)"
    web_password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
  else
    echo; echo "请设置 Web 管理界面的登录凭据："
    read -rp "用户名（留空随机生成）：" web_username
    if [ -z "$web_username" ]; then
      web_username="admin_$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)"
      echo "生成用户名：$web_username"
    fi
    read -rsp "密码（留空随机生成）：" web_password; echo
    if [ -z "$web_password" ]; then
      web_password=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
      echo "生成密码：$web_password"
    fi
  fi

  PASSWORD_HASH=$("$PYTHON_BIN" - "$web_password" << 'PYEOF'
import sys
from werkzeug.security import generate_password_hash
print(generate_password_hash(sys.argv[1]))
PYEOF
)
  if [ -z "$PASSWORD_HASH" ] || [ ${#PASSWORD_HASH} -lt 20 ]; then
    echo "错误：密码哈希生成失败（werkzeug 不可用），中止 Web UI 部署。" >&2
    deploy_web=0
    return 1
  fi
  SECRET_KEY=$(head /dev/urandom | tr -dc 'A-F0-9' | head -c 64)
  ADMIN_TOKEN=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
  METRICS_TOKEN=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
  : "${web_port:=5666}"

  "$PYTHON_BIN" - "$ENV_FILE" "$web_username" "$PASSWORD_HASH" "$SECRET_KEY" "$ADMIN_TOKEN" "$METRICS_TOKEN" "$web_port" "$trust_proxy" << 'PYEOF'
import os, sys
env_file, username, pwhash, secret, admin_token, metrics_token, web_port, trust_proxy = sys.argv[1:9]
with open(env_file, 'w') as f:
    f.write(f'USERNAME={username}\n')
    f.write(f'PASSWORD_HASH={pwhash}\n')
    f.write(f'SECRET_KEY={secret}\n')
    f.write(f'ADMIN_TOKEN={admin_token}\n')
    f.write(f'METRICS_TOKEN={metrics_token}\n')
    f.write(f'WEB_PORT={web_port}\n')
    f.write(f'TRUST_PROXY={trust_proxy}\n')
os.chmod(env_file, 0o600)
PYEOF

  cat > /etc/systemd/system/wg-web.service << SERVICEEOF
[Unit]
Description=WireGuard Web UI
After=network.target wg-quick@wg0.service
Wants=wg-quick@wg0.service
[Service]
Type=simple
User=root
WorkingDirectory=/opt/wireguard-web
ExecStart=__PYBIN__ /opt/wireguard-web/app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
SERVICEEOF

  local listen_ip="127.0.0.1"
  if [ "$web_expose" = 1 ]; then listen_ip="0.0.0.0"; fi
  local web_service_port="${web_port:-5666}"
  sed -i "s|ExecStart=__PYBIN__ /opt/wireguard-web/app.py|ExecStart=$PYTHON_BIN /opt/wireguard-web/app.py --host $listen_ip --port $web_service_port|" /etc/systemd/system/wg-web.service

  if [ "$web_expose" = 1 ]; then
    if systemctl is-active --quiet firewalld.service 2>/dev/null; then
      firewall-cmd -q --permanent --add-port=${web_service_port}/tcp 2>/dev/null
      firewall-cmd -q --add-port=${web_service_port}/tcp 2>/dev/null
    elif hash iptables 2>/dev/null; then
      # 先删除同规则，避免重复安装时叠加
      while iptables -C INPUT -p tcp --dport ${web_service_port} -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport ${web_service_port} -j ACCEPT 2>/dev/null || break
      done
      iptables -I INPUT -p tcp --dport ${web_service_port} -j ACCEPT 2>/dev/null
    fi
  fi

  systemctl daemon-reload
  systemctl enable --now wg-web.service >/dev/null 2>&1 || true
  sleep 2
  if ! systemctl is-active --quiet wg-web 2>/dev/null; then
    echo "警告：Web UI 服务启动失败，最近日志："
    journalctl -u wg-web -n 15 --no-pager --output=cat 2>/dev/null || true
  fi
  rollback_files+=("/etc/systemd/system/wg-web.service")

  echo; echo "========== Web 管理界面 =========="
  echo "访问地址：http://${public_ip:-$ip}:${web_service_port}"
  echo "用户名：$web_username"
  echo "密码：$web_password"
  echo "------------------------------------"
  echo "API 管理员令牌（永久，请妥善保管）："
  echo "$ADMIN_TOKEN"
  echo "接口基址：http://${public_ip:-$ip}:${web_service_port}/api/v1"
  echo "===================================="
}

# ---------- 部署限速器 + 流量记录 ----------
deploy_limiter() {
  mkdir -p "$WEB_DIR/scripts"
  cat > "$WEB_DIR/scripts/wg-limiter.sh" << 'LIMEOF'
#!/bin/bash
# wg-limiter.sh — 每 1 分钟运行：在线判断(流量增量) + 流量限制 + 到期 + 周期重置 + 服务器总上限
WG_CONF="/etc/wireguard/wg0.conf"
DATA_DIR="/opt/wireguard-web/data"
BASE_FILE="$DATA_DIR/baseline.json"
TRAFFIC_BASE_FILE="$DATA_DIR/baseline_traffic.json"
STATUS_FILE="$DATA_DIR/status.json"
SERVER_FILE="$DATA_DIR/server_limit.json"
OFFLINE_THRESHOLD=51200   # 10 秒增量 < 50 KiB 视为离线

mkdir -p "$DATA_DIR"
[ ! -f "$WG_CONF" ] && exit 0

wg_raw=$(wg show wg0 dump 2>/dev/null | tail -n +2) || exit 0
today=$(date +%Y-%m-%d)
now=$(date +%s)
ym=$(date +%Y-%m)
hour=$(date +"%m-%d %H:00")

# 读取 peer 增量数据到临时文件
INC_FILE="$DATA_DIR/.limiter_inc"
: > "$INC_FILE"
while IFS=$'\t' read -r pubkey psk endpoint allowed handshake rx tx keepalive; do
  [ -z "$pubkey" ] && continue
  rx=${rx:-0}; tx=${tx:-0}
  name=$(awk -v pk="$pubkey" '
    /^# BEGIN_PEER / { n=$3 }
    /^PublicKey/ {
      k=$0; sub(/^[^=]*=[ \t]*/, "", k)
      if (k == pk) { print n; exit }
    }
  ' "$WG_CONF" 2>/dev/null)
  [ -z "$name" ] && continue
  echo "$pubkey	$name	$rx	$tx" >> "$INC_FILE"
done <<< "$wg_raw"

# Python：计算增量 → 更新 TRAFFIC_USED/status.json/traffic_<name>.json（仅统计在线）
python3 - "$INC_FILE" "$BASE_FILE" "$TRAFFIC_BASE_FILE" "$STATUS_FILE" "$WG_CONF" "$hour" "$DATA_DIR" "$OFFLINE_THRESHOLD" << 'PYEOF'
import json, sys, os, re

inc_file, base_file, tbase_file, status_file, conf_path, hour, data_dir, threshold = sys.argv[1:9]
threshold = int(threshold)

def load(p, default):
    if os.path.exists(p):
        try: return json.load(open(p))
        except Exception: return default
    return default

base = load(base_file, {})       # 用于 limiter（计入 TRAFFIC_USED）
tbase = load(tbase_file, {})     # 用于 traffic_<name>.json（独立基线）
status = load(status_file, {})

rows = []
if os.path.exists(inc_file):
    for line in open(inc_file):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 4:
            rows.append(parts)

new_base, new_tbase, new_status = {}, {}, {}
active_pubkeys = set()
inc_by_name = {}       # name -> 字节增量（计入配额，统计所有流量）
inc_tx_by_name = {}    # name -> 上行增量（图表）
inc_rx_by_name = {}    # name -> 下行增量（图表）

for pubkey, name, rx, tx in rows:
    rx, tx = int(rx), int(tx)
    active_pubkeys.add(pubkey)
    # limiter 基线
    prev = base.get(pubkey)
    if prev is None:
        d_limit = 0
    else:
        d_limit = max(0, rx - prev.get("rx", rx)) + max(0, tx - prev.get("tx", tx))
    new_base[pubkey] = {"rx": rx, "tx": tx}
    # 图表基线
    tprev = tbase.get(pubkey)
    if tprev is None:
        d_rx = d_tx = 0
    else:
        d_rx = max(0, rx - tprev.get("rx", rx))
        d_tx = max(0, tx - tprev.get("tx", tx))
    new_tbase[pubkey] = {"rx": rx, "tx": tx}

    # 在线状态：本轮增量达到阈值才算在线
    online = d_limit >= threshold
    new_status[name] = {"online": online, "delta": d_limit, "ts": int(__import__("time").time())}
    # 配额与图表：统计全部流量（不受在线阈值影响，避免漏计）
    inc_by_name[name] = inc_by_name.get(name, 0) + d_limit
    inc_tx_by_name[name] = inc_tx_by_name.get(name, 0) + d_tx
    inc_rx_by_name[name] = inc_rx_by_name.get(name, 0) + d_rx

json.dump(new_base, open(base_file, "w"))
json.dump(new_tbase, open(tbase_file, "w"))
json.dump(new_status, open(status_file, "w"))

# 更新 wg0.conf 中 TRAFFIC_USED
if inc_by_name and os.path.exists(conf_path):
    content = open(conf_path).read()
    lines = content.split("\n"); out = []; cur = None
    for ln in lines:
        m = re.match(r"^# BEGIN_PEER (.+)", ln)
        if m: cur = m.group(1)
        if cur and ln.startswith("# TRAFFIC_USED="):
            try: used = int(ln.split("=", 1)[1])
            except Exception: used = 0
            used += inc_by_name.get(cur, 0)
            ln = f"# TRAFFIC_USED={used}"
            cur = None
        out.append(ln)
    open(conf_path, "w").write("\n".join(out))

# 写每客户端小时流量 + 全局小时流量（同一轮内累加，避免漏计）
for name in set(list(inc_tx_by_name.keys()) + list(inc_rx_by_name.keys())):
    f = os.path.join(data_dir, f"traffic_{name}.json")
    data = load(f, [])
    sent = inc_tx_by_name.get(name, 0); received = inc_rx_by_name.get(name, 0)
    if data and data[-1].get("hour") == hour:
        data[-1]["sent"] = data[-1].get("sent", 0) + sent
        data[-1]["received"] = data[-1].get("received", 0) + received
    else:
        data.append({"hour": hour, "sent": sent, "received": received})
    json.dump(data[-168:], open(f, "w"))

# 全局小时流量
gf = os.path.join(data_dir, "traffic.json")
gdata = load(gf, [])
gsent = sum(inc_tx_by_name.values()); grecv = sum(inc_rx_by_name.values())
if gdata and gdata[-1].get("hour") == hour:
    gdata[-1]["sent"] = gdata[-1].get("sent", 0) + gsent
    gdata[-1]["received"] = gdata[-1].get("received", 0) + grecv
else:
    gdata.append({"hour": hour, "sent": gsent, "received": grecv})
json.dump(gdata[-168:], open(gf, "w"))
PYEOF
rm -f "$INC_FILE"

# ---------- 逐客户端：周期重置 / 流量限制 / 到期 ----------
peer_list=$(grep '^# BEGIN_PEER' "$WG_CONF" 2>/dev/null | cut -d' ' -f3)
QoS_CHANGED=0
for name in $peer_list; do
  [ -z "$name" ] && continue
  blk=$(sed -n "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/p" "$WG_CONF" 2>/dev/null)
  limit=$(echo "$blk" | grep "^# TRAFFIC_LIMIT=" | cut -d= -f2)
  expire=$(echo "$blk" | grep "^# EXPIRE=" | cut -d= -f2)
  cycle=$(echo "$blk" | grep "^# RESET_CYCLE=" | cut -d= -f2)
  cycle_start=$(echo "$blk" | grep "^# CYCLE_START=" | cut -d= -f2)
  used=$(echo "$blk" | grep "^# TRAFFIC_USED=" | cut -d= -f2)
  over_rate=$(echo "$blk" | grep "^# OVER_QUOTA_RATE=" | cut -d= -f2)
  disabled=$(echo "$blk" | grep "^# DISABLED" | head -1)
  throttled=$(echo "$blk" | grep "^# THROTTLED" | head -1)
  [ -z "$over_rate" ] && over_rate=0
  [ -z "$used" ] && used=0
  [ -z "$cycle" ] && cycle="30d"
  [ -z "$cycle_start" ] && cycle_start="$today"

  # 判断是否应重置
  do_reset=0
  case "$cycle" in
    none) do_reset=0 ;;
    natural)
      cur_month=$(date +%Y-%m)
      start_month=$(date -d "$cycle_start" +%Y-%m 2>/dev/null)
      [ "$cur_month" != "$start_month" ] && do_reset=1
      ;;
    *)
      cs=$(date -d "$cycle_start" +%s 2>/dev/null)
      ts=$(date -d "$today" +%s 2>/dev/null)
      [ -n "$cs" ] && [ -n "$ts" ] && [ $(( (ts - cs) / 86400 )) -ge 30 ] && do_reset=1
      ;;
  esac

  if [ "$do_reset" = 1 ]; then
    sed -i "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/s|^# TRAFFIC_USED=.*|# TRAFFIC_USED=0|" "$WG_CONF" 2>/dev/null
    sed -i "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/s|^# CYCLE_START=.*|# CYCLE_START=$today|" "$WG_CONF" 2>/dev/null
    if [ -n "$throttled" ]; then
      sed -i "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/s|^# THROTTLED||" "$WG_CONF" 2>/dev/null
      throttled=""
      QoS_CHANGED=1
      echo "[重置] $name 周期已重置，解除超配额限速" >&2
    fi
    if [ -n "$disabled" ]; then
      sed -i "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/s/^# DISABLED//" "$WG_CONF"
      wg addconf wg0 <(sed -n "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/p" "$WG_CONF" 2>/dev/null) 2>/dev/null
      echo "[重置] $name 周期已重置并重新启用" >&2
    fi
    used=0
  fi

  # 流量限制：设了 OVER_QUOTA_RATE 则降速，否则禁用
  if [ -n "$limit" ] && [ "$limit" -gt 0 ] && [ "$used" -ge "$limit" ] && [ -z "$disabled" ]; then
    if [ "${over_rate:-0}" -gt 0 ]; then
      if [ -z "$throttled" ]; then
        sed -i "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/s|^\[Peer\]|# THROTTLED\n[Peer]|" "$WG_CONF" 2>/dev/null
        QoS_CHANGED=1
        echo "[限速] $name 流量超限，已降速（不封禁）" >&2
      fi
    else
      pk=$(echo "$blk" | grep "^PublicKey" | head -1 | awk '{print $3}')
      [ -n "$pk" ] && wg set wg0 peer "$pk" remove 2>/dev/null
      sed -i "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/s|^\[Peer\]|# DISABLED\n[Peer]|" "$WG_CONF" 2>/dev/null
      echo "[限速] $name 流量超限，已禁用" >&2
    fi
  fi

  # 到期
  if [ -n "$expire" ] && [ -z "$disabled" ]; then
    es=$(date -d "$expire" +%s 2>/dev/null)
    ts=$(date +%s)
    if [ -n "$es" ] && [ "$ts" -ge "$es" ]; then
      pk=$(echo "$blk" | grep "^PublicKey" | head -1 | awk '{print $3}')
      [ -n "$pk" ] && wg set wg0 peer "$pk" remove 2>/dev/null
      sed -i "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/s|^\[Peer\]|# DISABLED\n[Peer]|" "$WG_CONF" 2>/dev/null
      echo "[到期] $name 已到期，已禁用" >&2
    fi
  fi
done

# ---------- 服务器总流量上限 ----------
python3 - "$SERVER_FILE" "$DATA_DIR" "$BASE_FILE" "$WG_CONF" "$ym" "$now" << 'PYEOF'
import json, sys, os

server_file, data_dir, base_file, conf_path, ym, now = sys.argv[1:7]
now = int(now)

def load(p, d):
    if os.path.exists(p):
        try: return json.load(open(p))
        except Exception: return d
    return d

srv = load(server_file, {"limit": 0, "used": 0, "period": ym, "blocked": False})
if srv.get("period") != ym:
    srv["period"] = ym; srv["used"] = 0; srv["blocked"] = False

# 从 limiter 已统计的每客户端增量累加服务器总量
# 增量文件已被删除，这里读取 status.json 的 delta 作近似（status 由本轮写入）
status = load(os.path.join(data_dir, "status.json"), {})
delta_sum = sum(v.get("delta", 0) for v in status.values())
srv["used"] = srv.get("used", 0) + delta_sum

# 超限：移除所有 peer（不改配置文件，便于恢复）
blocked = False
if srv.get("limit", 0) > 0 and srv["used"] >= srv["limit"]:
    blocked = True
srv["blocked"] = blocked
json.dump(srv, open(server_file, "w"))
PYEOF

# 若服务器超限则移除全部 peer；否则恢复未禁用的 peer
blocked=$(python3 -c "import json,os; p='$SERVER_FILE'; print(1 if os.path.exists(p) and json.load(open(p)).get('blocked') else 0)")
if [ "$blocked" = "1" ]; then
  wg show wg0 peers 2>/dev/null | while read pk; do
    [ -n "$pk" ] && wg set wg0 peer "$pk" remove 2>/dev/null
  done
else
  # 恢复所有未被禁用的客户端（跨月或取消上限后）
  peer_list=$(grep '^# BEGIN_PEER' "$WG_CONF" 2>/dev/null | cut -d' ' -f3)
  for name in $peer_list; do
    [ -z "$name" ] && continue
    if ! sed -n "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/p" "$WG_CONF" 2>/dev/null | grep -q "^# DISABLED"; then
      wg addconf wg0 <(sed -n "/^# BEGIN_PEER $name$/,/^# END_PEER $name$/p" "$WG_CONF" 2>/dev/null) 2>/dev/null
    fi
  done
fi

# 若限速状态有变化（超配额降速/解除），重新下发 tc 规则
if [ "${QoS_CHANGED:-0}" = "1" ] && [ -x /opt/wireguard-web/scripts/wg-qos.sh ]; then
  /opt/wireguard-web/scripts/wg-qos.sh apply >/dev/null 2>&1 || true
fi
LIMEOF
  chmod +x "$WEB_DIR/scripts/wg-limiter.sh"

  # 统一使用已探测的 Python 解释器（避免 systemd/宝塔多解释器不一致）
  if [ -n "$PYTHON_BIN" ] && [ "$PYTHON_BIN" != "python3" ]; then
    sed -i "s|python3 - |$PYTHON_BIN - |g" "$WEB_DIR/scripts/wg-limiter.sh"
  fi

  cat > /etc/systemd/system/wg-limiter.service << 'LSVC'
[Unit]
Description=WireGuard traffic limiter (10s)
[Service]
Type=oneshot
ExecStart=/opt/wireguard-web/scripts/wg-limiter.sh
User=root
LSVC

  cat > /etc/systemd/system/wg-limiter.timer << 'LTIMER'
[Unit]
Description=Run WireGuard limiter every 10 seconds
[Timer]
OnCalendar=*:*:0/10
AccuracySec=1s
Persistent=true
[Install]
WantedBy=timers.target
LTIMER

  # 旧的独立小时记录器已合并进 limiter（1 分钟），清理以免重复计数
  systemctl disable --now wg-traffic.timer 2>/dev/null
  systemctl disable --now wg-traffic.service 2>/dev/null
  rm -f /etc/systemd/system/wg-traffic.service /etc/systemd/system/wg-traffic.timer
  rm -f "$WEB_DIR/scripts/traffic-log.sh"
  rm -f "$DATA_DIR/baseline_traffic.json" 2>/dev/null

  systemctl daemon-reload
  systemctl enable --now wg-limiter.timer 2>/dev/null || true
  rollback_files+=("/etc/systemd/system/wg-limiter.service" "/etc/systemd/system/wg-limiter.timer")

  # ---------- QoS 限速（tc / HTB / TBF） ----------
  cat > "$WEB_DIR/scripts/wg-qos.sh" << 'QOSEOF'
#!/bin/bash
# wg-qos.sh — 依据 wg0.conf 的 # RATE_DOWN/# RATE_UP 与 data/qos.json 下发 tc 限速
# 用法：wg-qos.sh apply|clear
WG_IF="wg0"
IFB_IF="ifb0"
WG_CONF="/etc/wireguard/wg0.conf"
QOS_FILE="/opt/wireguard-web/data/qos.json"
# 存储口径：conf 与 qos.json 均为「字节/秒」，tc 需要「bit/s」→ ×8
FACTOR=8
HTB_ROOT="1:"; HTB_CLS="1:1"

log() { logger -t wg-qos "$1" 2>/dev/null || true; }

clear_all() {
  tc qdisc del dev "$WG_IF" root 2>/dev/null || true
  tc qdisc del dev "$WG_IF" ingress 2>/dev/null || true
  if ip link show "$IFB_IF" >/dev/null 2>&1; then
    tc qdisc del dev "$IFB_IF" root 2>/dev/null || true
    ip link set "$IFB_IF" down 2>/dev/null || true
    ip link delete "$IFB_IF" type ifb 2>/dev/null || true
  fi
}

# 读取客户端限速：输出 "IP DOWN_MBPS UP_MBPS"（仅 >0 的）
peer_rates() {
  python3 - "$WG_CONF" <<'PY'
import re,sys
try: c=open(sys.argv[1]).read()
except Exception: sys.exit(0)
cur=None; ip=""; down=0; up=0; thr=False; oq=0
def emit():
    if ip and (down>0 or up>0 or (thr and oq>0)):
        if thr and oq>0:
            print(f"{ip} {oq} {oq}")   # 超配额：上下行均降至 OVER_QUOTA_RATE
        else:
            print(f"{ip} {down} {up}")
for ln in c.split("\n"):
    m=re.match(r"^# BEGIN_PEER (.+)", ln)
    if m:
        if cur is not None: emit()
        cur=m.group(1); ip=""; down=0; up=0; thr=False; oq=0
        continue
    if cur is None: continue
    m=re.match(r"\s*AllowedIPs\s*=\s*([0-9.]+)/", ln)
    if m and not ip: ip=m.group(1)
    m=re.match(r"^# RATE_DOWN=(\d+)", ln)
    if m: down=int(m.group(1))
    m=re.match(r"^# RATE_UP=(\d+)", ln)
    if m: up=int(m.group(1))
    m=re.match(r"^# OVER_QUOTA_RATE=(\d+)", ln)
    if m: oq=int(m.group(1))
    if re.match(r"^# THROTTLED", ln): thr=True
    if re.match(r"^# END_PEER", ln):
        emit(); cur=None; ip=""; down=0; up=0; thr=False; oq=0
if cur is not None: emit()
PY
}

# 生成 HTB 单口配置：$1=设备 $2=方向(dst/src) $3=根速率(bit/s,0=不限) $4=客户端映射
build_htb() {
  local dev="$1" dir="$2" root_rate="$3" map="$4"
  local ceil_opt=""
  [ "$root_rate" -gt 0 ] && ceil_opt="ceil ${root_rate}bit"
  tc qdisc add dev "$dev" root handle 1: htb default 9999 2>/dev/null || {
    tc qdisc del dev "$dev" root 2>/dev/null; tc qdisc add dev "$dev" root handle 1: htb default 9999; }
  if [ "$root_rate" -gt 0 ]; then
    tc class add dev "$dev" parent 1: classid 1:1 htb rate ${root_rate}bit ceil ${root_rate}bit
  else
    tc class add dev "$dev" parent 1: classid 1:1 htb rate 100000mbit
  fi
  tc class add dev "$dev" parent 1:1 classid 1:9999 htb rate 1mbit ceil 100000mbit 2>/dev/null || true
  local n=0
  while read -r ip down up; do
    [ -z "$ip" ] && continue
    local rate=0
    [ "$dir" = "dst" ] && rate="$down" || rate="$up"
    [ "$rate" -le 0 ] && continue
    local bits=$(( rate * FACTOR ))
    local octet="${ip##*.}"
    local cid="1:${octet}"
    # 避免 classid 冲突（1:1 与 1:9999 保留）
    if [ "$octet" = "1" ] || [ "$octet" = "9999" ]; then cid="1:$((1000+octet))"; fi
    tc class add dev "$dev" parent 1:1 classid "$cid" htb rate ${bits}bit ceil ${bits}bit 2>/dev/null || \
      tc class change dev "$dev" parent 1:1 classid "$cid" htb rate ${bits}bit ceil ${bits}bit 2>/dev/null
    tc filter add dev "$dev" protocol ip parent 1: prio 1 u32 \
      match ip "$dir" "${ip}/32" flowid "$cid" 2>/dev/null || true
    n=$((n+1))
  done <<< "$map"
  log "$dev HTB: $n 个客户端限速 (dir=$dir root=${root_rate}bit)"
}

# 生成 TBF/police 单口配置：$1=设备 $2=方向 $3=客户端映射
build_tbf() {
  local dev="$1" dir="$2" map="$3"
  # TBF/police 模式：root 用 prio 承载 filter（tbf 根类不支持 police）
  tc qdisc add dev "$dev" root handle 1: prio 2>/dev/null || true
  local n=0
  while read -r ip down up; do
    [ -z "$ip" ] && continue
    local rate=0
    [ "$dir" = "dst" ] && rate="$down" || rate="$up"
    [ "$rate" -le 0 ] && continue
    local bits=$(( rate * FACTOR ))
    tc filter add dev "$dev" protocol ip parent 1: prio 1 u32 \
      match ip "$dir" "${ip}/32" police rate ${bits}bit burst 128k drop 2>/dev/null || true
    n=$((n+1))
  done <<< "$map"
  log "$dev TBF/police: $n 个客户端限速 (dir=$dir)"
}

apply_all() {
  local algo tdown tup
  algo=$(python3 -c "import json;print(json.load(open('$QOS_FILE')).get('algo','htb'))" 2>/dev/null || echo htb)
  tdown=$(python3 -c "import json;print(json.load(open('$QOS_FILE')).get('total_down',0))" 2>/dev/null || echo 0)
  tup=$(python3 -c "import json;print(json.load(open('$QOS_FILE')).get('total_up',0))" 2>/dev/null || echo 0)

  local map; map=$(peer_rates)

  if [ -z "$map" ] && [ "${tdown:-0}" -le 0 ] && [ "${tup:-0}" -le 0 ]; then
    clear_all
    log "未配置限速，已清空 tc 规则"
    return 0
  fi

  clear_all

  # 网卡线速（根类兜底）
  local ifc speed line
  ifc=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  line=$(cat /sys/class/net/${ifc}/speed 2>/dev/null || echo 1000)
  [ -z "$line" ] || [ "$line" -le 0 ] 2>/dev/null && line=1000
  local linebit=$(( line * 1000000 ))

  # ----- 下行：wg0 egress，按 dst -----
  if [ "$algo" = "tbf" ]; then
    build_tbf "$WG_IF" "dst" "$map"
  else
    local rd=$(( ${tdown:-0} * FACTOR )); [ "$rd" -le 0 ] && rd=0
    build_htb "$WG_IF" "dst" "$rd" "$map"
  fi

  # ----- 上行：先 ingress 重定向到 ifb0，再按 src -----
  local need_up=0
  while read -r ip down up; do [ -n "$ip" ] && [ "${up:-0}" -gt 0 ] && need_up=1; done <<< "$map"
  if [ "${tup:-0}" -gt 0 ]; then need_up=1; fi
  if [ "$need_up" = 1 ]; then
    modprobe ifb 2>/dev/null || true
    ip link show "$IFB_IF" >/dev/null 2>&1 || ip link add "$IFB_IF" type ifb
    ip link set "$IFB_IF" up
    tc qdisc add dev "$WG_IF" handle ffff: ingress 2>/dev/null || true
    tc filter add dev "$WG_IF" parent ffff: protocol ip u32 match u32 0 0 \
      action mirred egress redirect dev "$IFB_IF" 2>/dev/null || true
    if [ "$algo" = "tbf" ]; then
      build_tbf "$IFB_IF" "src" "$map"
    else
      local ru=$(( ${tup:-0} * FACTOR )); [ "$ru" -le 0 ] && ru=0
      build_htb "$IFB_IF" "src" "$ru" "$map"
    fi
  fi
  log "QoS 已应用（algo=$algo totaldown=${tdown} totalup=${tup}）"
}

case "${1:-apply}" in
  apply) apply_all ;;
  clear) clear_all; log "QoS 已清空" ;;
  *) echo "用法：$0 apply|clear"; exit 1 ;;
esac
QOSEOF
  chmod +x "$WEB_DIR/scripts/wg-qos.sh"

  cat > /etc/systemd/system/wg-qos.service << 'QSVC'
[Unit]
Description=WireGuard QoS (tc rate limit)
After=wg-quick@wg0.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/wireguard-web/scripts/wg-qos.sh apply
ExecStop=/opt/wireguard-web/scripts/wg-qos.sh clear
User=root
[Install]
WantedBy=multi-user.target
QSVC
  systemctl daemon-reload
  systemctl enable wg-qos.service >/dev/null 2>&1 || true
  systemctl start wg-qos.service >/dev/null 2>&1 || true
  rollback_files+=("/etc/systemd/system/wg-qos.service")

# ---------- wg-quick@wg0 熔断阈值（避免频繁重启触发 start-limit-hit） ----------
  # 该服务常被 Web/API/自愈重启，若按 systemd 默认（5次/10秒）极易触发 start-limit-hit
  # 而拒绝对外提供服务。此处彻底关闭启动频率限制（Interval=0），并挂 QoS 重启后重下发。
  mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
  cat > /etc/systemd/system/wg-quick@wg0.service.d/10-override.conf << 'WGDROP'
[Unit]
StartLimitIntervalSec=0
StartLimitBurst=0
[Service]
Restart=no
ExecStartPost=-/bin/bash -c 'sleep 1; [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply'
WGDROP
  systemctl daemon-reload
  rollback_files+=("/etc/systemd/system/wg-quick@wg0.service.d/10-override.conf")

  # 统一 Python 解释器
  if [ -n "$PYTHON_BIN" ] && [ "$PYTHON_BIN" != "python3" ]; then
    sed -i "s|python3 - |$PYTHON_BIN - |g" "$WEB_DIR/scripts/wg-qos.sh"
    sed -i "s|python3 -c |$PYTHON_BIN -c |g" "$WEB_DIR/scripts/wg-qos.sh"
  fi

  # ---------- 健康自愈：每分钟检查关键服务，异常自动重启 ----------
  cat > "$WEB_DIR/scripts/wg-health.sh" << 'HEALTHEOF'
#!/bin/bash
# wg-health.sh — 关键服务存活检查；异常自动重启并记录审计
# 关键改进：区分「停止/失败/启动频率超限」，用 start 而非 restart，
#           失败时先 reset-failed 解除熔断；对同一服务加冷却，避免自愈制造重启风暴。
DATA_DIR="/opt/wireguard-web/data"
STATE_FILE="$DATA_DIR/health_state.json"
COOLDOWN=120          # 同一服务两次自愈最小间隔（秒）
mkdir -p "$DATA_DIR"
audit() {
  echo "{\"ts\":\"$(date '+%Y-%m-%d %H:%M:%S')\",\"action\":\"自愈\",\"detail\":\"$1\",\"ip\":\"local\"}" >> "$DATA_DIR/audit.log"
  logger -t wg-health "$1" 2>/dev/null || true
}
# 冷却判断：返回 0=允许重启，1=冷却中
cooled() { # svc
  python3 - "$STATE_FILE" "$1" "$COOLDOWN" <<'PY'
import json,os,sys,time
f,svc,cd=sys.argv[1],sys.argv[2],int(sys.argv[3])
d={}
if os.path.exists(f):
    try: d=json.load(open(f))
    except Exception: d={}
last=float(d.get(svc,0))
sys.exit(1 if (time.time()-last)<cd else 0)
PY
}
mark() { # svc
  python3 - "$STATE_FILE" "$1" <<'PY'
import json,os,sys,time
f,svc=sys.argv[1],sys.argv[2]
d={}
if os.path.exists(f):
    try: d=json.load(open(f))
    except Exception: d={}
d[svc]=time.time()
try: json.dump(d,open(f,"w"))
except Exception: pass
PY
}
check_restart() { # name
  local svc="$1"
  systemctl is-active --quiet "$svc" && return 0
  # 启动频率超限（熔断）：先 reset-failed 解除，再 start
  if systemctl is-failed --quiet "$svc" || [ "$(systemctl show -p Result --value "$svc" 2>/dev/null)" = "start-limit-hit" ]; then
    if ! cooled "$svc"; then return 0; fi
    mark "$svc"
    audit "服务 $svc 处于失败/熔断状态，reset-failed 后尝试启动"
    systemctl reset-failed "$svc" 2>/dev/null || true
  else
    if ! cooled "$svc"; then return 0; fi
    mark "$svc"
    audit "服务 $svc 未运行，尝试启动"
  fi
  systemctl start "$svc" 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet "$svc"; then
    audit "$svc 已恢复"
  else
    audit "$svc 启动失败，请手动检查"
  fi
}
check_restart wg-quick@wg0
check_restart wg-web
if ! systemctl is-active --quiet wg-limiter.timer; then
  if cooled "wg-limiter.timer"; then
    mark "wg-limiter.timer"
    audit "限流定时器异常，尝试重启"
    systemctl reset-failed wg-limiter.timer 2>/dev/null || true
    systemctl start wg-limiter.timer 2>/dev/null || true
  fi
fi
# ---------- 重启风暴检测：5 分钟内 wg-quick 被反复拉起则告警（只记录，不干预，避免加重）----------
STORM_FILE="$DATA_DIR/storm_state.json"
python3 - "$STORM_FILE" <<'PY'
import json, os, subprocess, sys, time, datetime
f = sys.argv[1]
# 统计最近 5 分钟 systemd 日志中 wg-quick 的启动次数
try:
    out = subprocess.run(["journalctl", "-u", "wg-quick@wg0", "--since", "-5min", "--no-pager"],
                         capture_output=True, text=True, timeout=10).stdout
except Exception:
    out = ""
n = sum(1 for l in out.splitlines() if "Starting wg-quick@wg0" in l or "Starting WireGuard via wg-quick" in l)
now = time.time()
if os.path.exists(f):
    try: st = json.load(open(f))
    except Exception: st = {}
else:
    st = {}
if n >= 12 and now - float(st.get("last_alert", 0)) > 1800:
    st["last_alert"] = now
    st["count"] = n
    try:
        with open("/opt/wireguard-web/data/audit.log", "a") as a:
            ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            a.write(json.dumps({"ts": ts, "action": "重启风暴告警",
                                "detail": f"5 分钟内 wg-quick@wg0 被启动 {n} 次，疑似外部脚本/面板反复重启",
                                "ip": "local"}, ensure_ascii=False) + "\n")
    except Exception: pass
    subprocess.run(["logger", "-t", "wg-health", f"检测到重启风暴：5 分钟 {n} 次"], capture_output=True)
try: json.dump(st, open(f, "w"))
except Exception: pass
PY
# 审计日志裁剪（最多 500 行）
if [ -f "$DATA_DIR/audit.log" ]; then
  n=$(wc -l < "$DATA_DIR/audit.log" 2>/dev/null || echo 0)
  if [ "$n" -gt 500 ]; then tail -n 500 "$DATA_DIR/audit.log" > "$DATA_DIR/.audit.tmp" && mv "$DATA_DIR/.audit.tmp" "$DATA_DIR/audit.log"; fi
fi
HEALTHEOF
  chmod +x "$WEB_DIR/scripts/wg-health.sh"

  cat > /etc/systemd/system/wg-health.service << 'HSVC'
[Unit]
Description=WireGuard health check (self-heal)
[Service]
Type=oneshot
ExecStart=/opt/wireguard-web/scripts/wg-health.sh
User=root
HSVC

  cat > /etc/systemd/system/wg-health.timer << 'HTIMER'
[Unit]
Description=Run WireGuard health check every minute
[Timer]
OnCalendar=*:0/1
AccuracySec=5s
Persistent=true
[Install]
WantedBy=timers.target
HTIMER

  systemctl daemon-reload
  systemctl enable --now wg-health.timer 2>/dev/null || true
  rollback_files+=("/etc/systemd/system/wg-health.service" "/etc/systemd/system/wg-health.timer")
}

# ---------- 创建 wgd CLI ----------
create_wgd_cli() {
  cat > "$WGD_BIN" << 'WGDEOF'
#!/bin/bash
WG_CONF="/etc/wireguard/wg0.conf"
WG_SCRIPT=""
for p in /etc/wireguard/wg.sh /root/wg.sh; do
  [ -f "$p" ] && WG_SCRIPT="$p" && break
done

case "${1:-help}" in
  status)
    echo "=== WireGuard 状态 ==="
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then echo "状态：运行中"; else echo "状态：已停止"; fi
    if [ -f "$WG_CONF" ]; then
      echo "端口：$(grep '^ListenPort' "$WG_CONF" | cut -d' ' -f3)"
      echo "客户端数：$(grep -c '^# BEGIN_PEER' "$WG_CONF")"
    fi
    echo "---"
    wg show wg0 2>/dev/null || echo "WireGuard 未运行"
    ;;
  list)
    if [ -f "$WG_CONF" ]; then
      echo "=== 客户端列表 ==="
      grep '^# BEGIN_PEER' "$WG_CONF" | cut -d' ' -f3 | nl -s ') '
      echo "总计：$(grep -c '^# BEGIN_PEER' "$WG_CONF") 个客户端"
    else echo "WireGuard 未配置"; fi
    ;;
  add)
    [ -z "$2" ] && { echo "用法：wgd add <名称>"; exit 1; }
    [ -n "$WG_SCRIPT" ] && bash "$WG_SCRIPT" --addclient "$2" || echo "未找到 wg.sh"
    [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
    ;;
  remove)
    [ -z "$2" ] && { echo "用法：wgd remove <名称>"; exit 1; }
    [ -n "$WG_SCRIPT" ] && bash "$WG_SCRIPT" --removeclient "$2" -y || echo "未找到 wg.sh"
    [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
    ;;
  qr)
    [ -z "$2" ] && { echo "用法：wgd qr <名称>"; exit 1; }
    [ -n "$WG_SCRIPT" ] && bash "$WG_SCRIPT" --showclientqr "$2" || echo "未找到 wg.sh"
    ;;
  config)
    [ -z "$2" ] && { echo "用法：wgd config <名称>"; exit 1; }
    for d in /root /home; do
      if [ -f "$d/$2.conf" ]; then echo "配置路径：$d/$2.conf"; cat "$d/$2.conf"; exit 0; fi
    done
    echo "未找到 $2.conf 配置文件"
    ;;
  limit)
    [ -z "$2" ] && { echo "用法：wgd limit <名称> [1G|500M|0]"; exit 1; }
    if [ -z "$3" ]; then
      l=$(grep -A10 "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null | grep "^# TRAFFIC_LIMIT=" | cut -d= -f2)
      [ "$l" = "0" ] && echo "$2: 无限制" || echo "$2: 限制 $l bytes"
    else
      bytes=0
      case "$3" in
        *[Gg]) bytes=$((${3%[Gg]} * 1073741824)) ;;
        *[Mm]) bytes=$((${3%[Mm]} * 1048576)) ;;
        *[Kk]) bytes=$((${3%[Kk]} * 1024)) ;;
        *) bytes=$3 ;;
      esac
      sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# TRAFFIC_LIMIT=.*|# TRAFFIC_LIMIT=$bytes|" "$WG_CONF"
      echo "$2: 流量限制已设为 $3"
    fi
    ;;
  expire)
    [ -z "$2" ] && { echo "用法：wgd expire <名称> [2026-12-31|clear]"; exit 1; }
    if [ -z "$3" ]; then
      e=$(grep -A10 "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null | grep "^# EXPIRE=" | cut -d= -f2-)
      [ -z "$e" ] && echo "$2: 无到期时间" || echo "$2: 到期 $e"
    elif [ "$3" = "clear" ]; then
      sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# EXPIRE=.*|# EXPIRE=|" "$WG_CONF"
      echo "$2: 到期时间已清除"
    else
      sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# EXPIRE=.*|# EXPIRE=$3|" "$WG_CONF"
      echo "$2: 到期时间已设为 $3"
    fi
    ;;
  enable)
    [ -z "$2" ] && { echo "用法：wgd enable <名称>"; exit 1; }
    sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# DISABLED||" "$WG_CONF"
    wg addconf wg0 <(sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF") 2>/dev/null
    echo "$2: 已启用"
    ;;
  disable)
    [ -z "$2" ] && { echo "用法：wgd disable <名称>"; exit 1; }
    if ! grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then echo "$2: 客户端不存在"; exit 1; fi
    pubkey=$(grep -A10 "^# BEGIN_PEER $2$" "$WG_CONF" | grep "^PublicKey" | awk '{print $3}')
    [ -n "$pubkey" ] && wg set wg0 peer "$pubkey" remove 2>/dev/null
    # 先移除已有 DISABLED 标记，避免重复
    sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# DISABLED||" "$WG_CONF"
    sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^\[Peer\]|# DISABLED\n[Peer]|" "$WG_CONF"
    echo "$2: 已禁用"
    ;;
cycle)
    [ -z "$2" ] && { echo "用法：wgd cycle <名称> [natural|30d|none]"; exit 1; }
    if [ -z "$3" ]; then
      c=$(grep -A12 "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null | grep "^# RESET_CYCLE=" | cut -d= -f2)
      echo "$2: 重置周期 ${c:-30d}"
    else
      case "$3" in natural|30d|none) ;; *) echo "无效值，仅支持 natural|30d|none"; exit 1 ;; esac
      sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# RESET_CYCLE=.*|# RESET_CYCLE=$3|" "$WG_CONF"
      echo "$2: 重置周期已设为 $3"
    fi
    ;;
  reset)
    [ -z "$2" ] && { echo "用法：wgd reset <名称>"; exit 1; }
    if ! grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then echo "$2: 客户端不存在"; exit 1; fi
    TODAY=$(date +%Y-%m-%d)
    sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# TRAFFIC_USED=.*|# TRAFFIC_USED=0|" "$WG_CONF"
    sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# CYCLE_START=.*|# CYCLE_START=$TODAY|" "$WG_CONF"
    echo "$2: 流量已重置（周期起点 $TODAY）"
    ;;
  remark)
    [ -z "$2" ] && { echo "用法：wgd remark <名称> [备注]"; exit 1; }
    if ! grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then echo "$2: 客户端不存在"; exit 1; fi
    if [ -z "$3" ]; then
      r=$(grep -A12 "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null | grep "^# REMARK=" | cut -d= -f2-)
      echo "$2: 备注 ${r:-无}"
    else
      NEWR=$(printf '%s' "$3" | tr '\n' ' ' | cut -c1-40)
      if grep -q "^# REMARK=" <(sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF"); then
        sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# REMARK=.*|# REMARK=$NEWR|" "$WG_CONF"
      else
        sed -i "/^# BEGIN_PEER $2$/a # REMARK=$NEWR" "$WG_CONF"
      fi
      echo "$2: 备注已设为 $NEWR"
    fi
    ;;
  server-limit)
    SFILE="/opt/wireguard-web/data/server_limit.json"
    if [ -z "$2" ]; then
      [ -f "$SFILE" ] && python3 -c "import json;d=json.load(open('$SFILE'));print('限制: %s bytes  已用: %s bytes  周期: %s  状态: %s'%(d.get('limit',0),d.get('used',0),d.get('period',''),'超限' if d.get('blocked') else '正常'))" || echo "未设置"
    elif [ "$2" = "clear" ]; then
      python3 -c "
import json,os
f='$SFILE'
d={'limit':0,'used':0,'period':__import__('datetime').date.today().strftime('%Y-%m'),'blocked':False}
os.makedirs(os.path.dirname(f),exist_ok=True); json.dump(d,open(f,'w'))
print('服务器总流量上限已清除')"
    else
      python3 -c "
import json,os,re,sys
f='$SFILE'; v=re.sub(r'[^0-9]','', '$2')
b=int(v) if v else 0
d={'limit':b,'used':0,'period':__import__('datetime').date.today().strftime('%Y-%m'),'blocked':False}
os.makedirs(os.path.dirname(f),exist_ok=True); json.dump(d,open(f,'w'))
print(f'服务器总流量上限已设为 {b} bytes')"
    fi
    ;;
  sub)
    [ -z "$2" ] && { echo "用法：wgd sub <名称>"; exit 1; }
    tok=$(grep -A12 "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null | grep "^# TOKEN=" | cut -d= -f2 | head -1)
    if [ -z "$tok" ]; then
      tok=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
      if grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then
        sed -i "/^# BEGIN_PEER $2$/a # TOKEN=$tok" "$WG_CONF"
      else echo "$2: 客户端不存在"; exit 1; fi
    fi
    ip=$(grep '^# ENDPOINT' "$WG_CONF" | cut -d' ' -f3)
    WP=$(grep '^WEB_PORT=' /opt/wireguard-web/.env 2>/dev/null | cut -d= -f2); [ -z "$WP" ] && WP=5666
    echo "$2 的订阅链接：http://${ip}:${WP}/sub/$tok"
    ;;
  dns)
    [ -z "$2" ] && { echo "用法：wgd dns <名称> [DNS]"; exit 1; }
    if ! grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then echo "$2: 客户端不存在"; exit 1; fi
    if [ -z "$3" ]; then
      d=$(sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep "^# DNS=" | cut -d= -f2-)
      echo "$2: DNS ${d:-（使用全局默认）}"
    else
      NEWD=$(printf '%s' "$3" | tr -cd '0-9a-fA-F:., ')
      if sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep -q "^# DNS="; then
        sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# DNS=.*|# DNS=$NEWD|" "$WG_CONF"
      else
        sed -i "/^# BEGIN_PEER $2$/a # DNS=$NEWD" "$WG_CONF"
      fi
      echo "$2: DNS 已设为 $NEWD"
    fi
    ;;
  rename)
    [ -z "$2" ] || [ -z "$3" ] && { echo "用法：wgd rename <旧名称> <新名称>"; exit 1; }
    if ! grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then echo "$2: 客户端不存在"; exit 1; fi
    if grep -q "^# BEGIN_PEER $3$" "$WG_CONF" 2>/dev/null; then echo "$3: 新名称已存在"; exit 1; fi
    sed -i "s|^# BEGIN_PEER $2$|# BEGIN_PEER $3|; s|^# END_PEER $2$|# END_PEER $3|" "$WG_CONF"
    for d in /root /home; do
      [ -f "$d/$2.conf" ] && mv "$d/$2.conf" "$d/$3.conf"
    done
    [ -f "/opt/wireguard-web/data/traffic_$2.json" ] && mv "/opt/wireguard-web/data/traffic_$2.json" "/opt/wireguard-web/data/traffic_$3.json"
    echo "$2 已重命名为 $3"
    ;;
  limits)
    echo "=== 流量限制 ==="
    grep "^# BEGIN_PEER" "$WG_CONF" 2>/dev/null | cut -d' ' -f3 | while read n; do
      lim=$(grep -A10 "^# BEGIN_PEER $n$" "$WG_CONF" | grep "^# TRAFFIC_LIMIT=" | cut -d= -f2)
      used=$(grep -A10 "^# BEGIN_PEER $n$" "$WG_CONF" | grep "^# TRAFFIC_USED=" | cut -d= -f2)
      exp=$(grep -A10 "^# BEGIN_PEER $n$" "$WG_CONF" | grep "^# EXPIRE=" | cut -d= -f2-)
      dis=$(grep -A10 "^# BEGIN_PEER $n$" "$WG_CONF" | grep "^# DISABLED" | head -1)
      status="启用"
      [ -n "$dis" ] && status="禁用"
      [ -z "$used" ] && used=0
      echo "  $n: 已用=${used}B 限制=${lim:-0}B 到期=${exp:-无} [$status]"
    done
    ;;
  set-many)
    shift
    [ -z "$1" ] && { echo "用法：wgd set-many <名称1,名称2,...> [--limit 1G] [--expire 2026-12-31] [--cycle 30d]"; exit 1; }
    NAMES_CSV="$1"; shift
    L=""; E=""; CY=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --limit) L="$2"; shift 2 ;;
        --expire) E="$2"; shift 2 ;;
        --cycle) CY="$2"; shift 2 ;;
        *) echo "未知选项：$1"; exit 1 ;;
      esac
    done
    IFS=',' read -ra NAMES <<< "$NAMES_CSV"
    for n in "${NAMES[@]}"; do
      n=$(printf '%s' "$n" | tr -d ' ')
      [ -z "$n" ] && continue
      if ! grep -q "^# BEGIN_PEER $n$" "$WG_CONF" 2>/dev/null; then echo "  $n: 不存在，跳过"; continue; fi
      if [ -n "$L" ]; then
        bytes=0
        case "$L" in
          *[Gg]) bytes=$((${L%[Gg]} * 1073741824)) ;;
          *[Mm]) bytes=$((${L%[Mm]} * 1048576)) ;;
          *[Kk]) bytes=$((${L%[Kk]} * 1024)) ;;
          *) bytes=$L ;;
        esac
        sed -i "/^# BEGIN_PEER $n$/,/^# END_PEER $n$/s|^# TRAFFIC_LIMIT=.*|# TRAFFIC_LIMIT=$bytes|" "$WG_CONF"
      fi
      [ -n "$E" ] && sed -i "/^# BEGIN_PEER $n$/,/^# END_PEER $n$/s|^# EXPIRE=.*|# EXPIRE=$E|" "$WG_CONF"
      if [ -n "$CY" ]; then
        case "$CY" in natural|30d|none) sed -i "/^# BEGIN_PEER $n$/,/^# END_PEER $n$/s|^# RESET_CYCLE=.*|# RESET_CYCLE=$CY|" "$WG_CONF" ;; esac
      fi
      echo "  $n: 已更新"
    done
    ;;
  backup)
    [ -n "$WG_SCRIPT" ] && bash "$WG_SCRIPT" --do-backup "/root/wg-backup-$(date +%Y%m%d-%H%M%S).tar.gz" || echo "未找到 wg.sh"
    ;;
  backup-list)
    ls -lh /root/wg-backup-*.tar.gz 2>/dev/null || echo "无备份文件"
    ;;
  restore)
    [ -z "$2" ] && { echo "用法：wgd restore <备份文件>"; exit 1; }
    [ -n "$WG_SCRIPT" ] && bash "$WG_SCRIPT" --do-restore "$2" || echo "未找到 wg.sh"
    ;;
  restart) systemctl reset-failed wg-quick@wg0 2>/dev/null; systemctl restart wg-quick@wg0 && echo "WireGuard 已重启" || echo "重启失败" ;;
  start) systemctl reset-failed wg-quick@wg0 2>/dev/null; systemctl start wg-quick@wg0 && echo "WireGuard 已启动" || echo "启动失败" ;;
  stop) systemctl stop wg-quick@wg0 && echo "WireGuard 已停止" || echo "停止失败" ;;
  log) journalctl -fu wg-quick@wg0 -n 50 ;;
  web)
    case "$2" in
      restart) systemctl restart wg-web && echo "Web UI 已重启" ;;
      status)
        if systemctl is-active --quiet wg-web; then
          echo "Web UI：运行中"
          [ -f /opt/wireguard-web/.env ] && echo "用户名：$(grep USERNAME /opt/wireguard-web/.env | cut -d= -f2)"
          WP=$(grep '^WEB_PORT=' /opt/wireguard-web/.env 2>/dev/null | cut -d= -f2); [ -z "$WP" ] && WP=5666
          echo "端口：$WP"
          MT=$(grep '^METRICS_TOKEN=' /opt/wireguard-web/.env 2>/dev/null | cut -d= -f2)
          [ -n "$MT" ] && echo "Metrics 令牌：$MT"
        else echo "Web UI：已停止"; fi
        ;;
      *) echo "用法：wgd web [status|restart]" ;;
    esac
    ;;
  web-port)
    ENVF="/opt/wireguard-web/.env"
    [ -f "$ENVF" ] || { echo "未找到 $ENVF，请先安装 Web UI"; exit 1; }
    OLD=$(grep '^WEB_PORT=' "$ENVF" 2>/dev/null | cut -d= -f2); [ -z "$OLD" ] && OLD=5666
    if [ -z "$2" ]; then echo "当前 Web 端口：$OLD"; exit 0; fi
    NEW="$2"
    if ! [[ "$NEW" =~ ^[0-9]+$ && "$NEW" -ge 1 && "$NEW" -le 65535 ]]; then echo "端口无效（1-65535）"; exit 1; fi
    # 先放行新端口
    if hash iptables 2>/dev/null; then
      iptables -C INPUT -p tcp --dport "$NEW" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$NEW" -j ACCEPT
    fi
    sed -i "s|^WEB_PORT=.*|WEB_PORT=$NEW|" "$ENVF" 2>/dev/null || echo "WEB_PORT=$NEW" >> "$ENVF"
    sed -i "s|--port $OLD|--port $NEW|" /etc/systemd/system/wg-web.service
    systemctl daemon-reload; systemctl restart wg-web
    # 回收旧端口规则
    if hash iptables 2>/dev/null && [ "$OLD" != "$NEW" ]; then
      while iptables -C INPUT -p tcp --dport "$OLD" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$OLD" -j ACCEPT 2>/dev/null || break
      done
    fi
    echo "Web 端口已由 $OLD 改为 $NEW"
    ;;
  admin-token)
    ENVF="/opt/wireguard-web/.env"
    if [ "$2" = "reset" ]; then
      [ -f "$ENVF" ] || { echo "未找到 $ENVF，请先安装 Web UI"; exit 1; }
      NEWTOK=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 64)
      if grep -q '^ADMIN_TOKEN=' "$ENVF"; then
        sed -i "s|^ADMIN_TOKEN=.*|ADMIN_TOKEN=$NEWTOK|" "$ENVF"
      else
        echo "ADMIN_TOKEN=$NEWTOK" >> "$ENVF"
      fi
      chmod 600 "$ENVF"
      systemctl restart wg-web 2>/dev/null
      echo "管理员令牌已重置（旧令牌立即失效）："
      echo "  $NEWTOK"
      echo "Web UI 已重启以应用新令牌。"
    else
      [ -f "$ENVF" ] || { echo "未找到 $ENVF，请先安装 Web UI"; exit 1; }
      TOK=$(grep '^ADMIN_TOKEN=' "$ENVF" | cut -d= -f2)
      if [ -z "$TOK" ]; then
        echo "未配置管理员令牌，执行 'wgd admin-token reset' 生成。"
      else
        echo "管理员 API 令牌（永久有效）："
        echo "  $TOK"
        echo
        echo "用法示例："
echo "  curl -H \"Authorization: Bearer $TOK\" http://127.0.0.1:5666/api/v1/clients"
        echo
        echo "重置：wgd admin-token reset"
      fi
    fi
    ;;
  passwd)
    read -rp "新用户名（留空不修改）：" new_user
    read -rsp "新密码：" new_pass
    echo
    if [ -n "$new_pass" ]; then
      python3 - "$new_user" "$new_pass" << 'PYEOF'
import os, sys, re
new_user, new_pass = sys.argv[1], sys.argv[2]
env_file = '/opt/wireguard-web/.env'
if not os.path.exists(env_file):
    print("更新失败：.env 文件不存在"); sys.exit(1)
with open(env_file) as f:
    content = f.read()
if new_user:
    content = re.sub(r'^USERNAME=.*', f'USERNAME={new_user}', content, flags=re.M)
from werkzeug.security import generate_password_hash
content = re.sub(r'^PASSWORD_HASH=.*', f'PASSWORD_HASH={generate_password_hash(new_pass)}', content, flags=re.M)
with open(env_file, 'w') as f:
    f.write(content)
os.chmod(env_file, 0o600)
print("密码已更新")
PYEOF
      systemctl restart wg-web
    else echo "密码未修改"; fi
    ;;
  uninstall)
    [ -n "$WG_SCRIPT" ] && exec bash "$WG_SCRIPT" --uninstall "$([ "$2" = "-y" ] && echo "-y")" || echo "未找到 wg.sh"
    ;;
  qos)
    QF="/opt/wireguard-web/data/qos.json"
    qget() { python3 -c "import json;print(json.load(open('$QF')).get('$1',0))" 2>/dev/null || echo 0; }
    case "$2" in
      ""|show)
        echo "=== 全局限速 ==="
        [ -f "$QF" ] || echo "(未配置)"
        echo "算法：$(qget algo)"
        echo "总下行：$(qget total_down) MB/s"
        echo "总上行：$(qget total_up) MB/s"
        ;;
      algo)
        case "$3" in htb|tbf) ;; *) echo "用法：wgd qos algo htb|tbf"; exit 1 ;; esac
        python3 -c "import json,os;f='$QF';d=json.load(open(f)) if os.path.exists(f) else {};d['algo']='$3';os.makedirs(os.path.dirname(f),exist_ok=True);json.dump(d,open(f,'w'));print('算法已设为 $3')"
        [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
        ;;
      total-down)
        V="${3:-0}"; python3 -c "import json,os;f='$QF';d=json.load(open(f)) if os.path.exists(f) else {};d['total_down']=int(round(float('$V')*1048576));os.makedirs(os.path.dirname(f),exist_ok=True);json.dump(d,open(f,'w'));print('总下行已设为 $V MB/s')"
        [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
        ;;
      total-up)
        V="${3:-0}"; python3 -c "import json,os;f='$QF';d=json.load(open(f)) if os.path.exists(f) else {};d['total_up']=int(round(float('$V')*1048576));os.makedirs(os.path.dirname(f),exist_ok=True);json.dump(d,open(f,'w'));print('总上行已设为 $V MB/s')"
        [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
        ;;
      *) echo "用法：wgd qos [show|algo htb|tbf|total-down N|total-up N]"; exit 1 ;;
    esac
    ;;
  rate)
    [ -z "$2" ] && { echo "用法：wgd rate <名称> [下行MB/s] [上行MB/s] | wgd rate <名称> clear"; exit 1; }
    if ! grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then echo "$2: 客户端不存在"; exit 1; fi
    if [ "${3:-}" = "clear" ]; then
      if sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep -q '^# RATE_DOWN='; then
        sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# RATE_DOWN=.*|# RATE_DOWN=0|" "$WG_CONF"
      else sed -i "/^# BEGIN_PEER $2$/a # RATE_DOWN=0" "$WG_CONF"; fi
      if sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep -q '^# RATE_UP='; then
        sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# RATE_UP=.*|# RATE_UP=0|" "$WG_CONF"
      else sed -i "/^# BEGIN_PEER $2$/a # RATE_UP=0" "$WG_CONF"; fi
      [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
      echo "$2: 限速已清除"; exit 0
    fi
    D="${3:-}"; U="${4:-}"
    if [ -z "$D" ] && [ -z "$U" ]; then
      echo "$2: 下行=$(sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep '^# RATE_DOWN=' | cut -d= -f2) B/s  上行=$(sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep '^# RATE_UP=' | cut -d= -f2) B/s"
      exit 0
    fi
    DB=""; UB=""
    [ -n "$D" ] && DB=$(python3 -c "print(int(round(float('$D')*1048576)))")
    [ -n "$U" ] && UB=$(python3 -c "print(int(round(float('$U')*1048576)))")
    if [ -n "$DB" ]; then
      if sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep -q '^# RATE_DOWN='; then
        sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# RATE_DOWN=.*|# RATE_DOWN=$DB|" "$WG_CONF"
      else
        sed -i "/^# BEGIN_PEER $2$/a # RATE_DOWN=$DB" "$WG_CONF"
      fi
    fi
    if [ -n "$UB" ]; then
      if sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep -q '^# RATE_UP='; then
        sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# RATE_UP=.*|# RATE_UP=$UB|" "$WG_CONF"
      else
        sed -i "/^# BEGIN_PEER $2$/a # RATE_UP=$UB" "$WG_CONF"
      fi
    fi
    [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
    echo "$2: 下行=${D:-不变} 上行=${U:-不变} MB/s"
    ;;
  rate-overquota)
    [ -z "$2" ] && { echo "用法：wgd rate-overquota <名称> [MB/s]（0=改为封禁）"; exit 1; }
    if ! grep -q "^# BEGIN_PEER $2$" "$WG_CONF" 2>/dev/null; then echo "$2: 客户端不存在"; exit 1; fi
    V="${3:-}"
    if [ -z "$V" ]; then
      echo "$2: 超配额降速=$(sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep '^# OVER_QUOTA_RATE=' | cut -d= -f2) B/s"
      exit 0
    fi
    VB=$(python3 -c "print(int(round(float('$V')*1048576)))")
    if sed -n "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/p" "$WG_CONF" | grep -q '^# OVER_QUOTA_RATE='; then
      sed -i "/^# BEGIN_PEER $2$/,/^# END_PEER $2$/s|^# OVER_QUOTA_RATE=.*|# OVER_QUOTA_RATE=$VB|" "$WG_CONF"
    else
      sed -i "/^# BEGIN_PEER $2$/a # OVER_QUOTA_RATE=$VB" "$WG_CONF"
    fi
    [ -x /opt/wireguard-web/scripts/wg-qos.sh ] && /opt/wireguard-web/scripts/wg-qos.sh apply
    echo "$2: 超配额降速已设为 $V MB/s"
    ;;
  doctor)
    ok=0; bad=0
    chk() { if eval "$2" >/dev/null 2>&1; then echo "  [✓] $1"; ok=$((ok+1)); else echo "  [✗] $1 ${3:-}"; bad=$((bad+1)); fi; }
    echo "=== WireGuard 体检 ==="
    chk "root 权限" "[ \"\$(id -u)\" = 0 ]" "需 sudo"
    chk "内核模块 wireguard" "modprobe -nq wireguard"
    chk "wg 命令" "command -v wg"
    chk "配置文件存在" "[ -f \"$WG_CONF\" ]"
    chk "wg-quick@wg0 运行中" "systemctl is-active --quiet wg-quick@wg0" "可执行 wgd restart"
    sl_result=$(systemctl show -p Result --value wg-quick@wg0 2>/dev/null)
    if [ "$sl_result" = "start-limit-hit" ]; then
      echo "  [✗] wg-quick@wg0 启动频率超限（start-limit-hit），已尝试自动解除"
      systemctl reset-failed wg-quick@wg0 2>/dev/null || true
      systemctl start wg-quick@wg0 2>/dev/null || true
      bad=$((bad+1))
    fi
    if [ -f /opt/wireguard-web/.env ]; then
      chk "wg-web 运行中" "systemctl is-active --quiet wg-web" "可执行 wgd web restart"
      chk "wg-limiter.timer 运行中" "systemctl is-active --quiet wg-limiter.timer"
      chk "ADMIN_TOKEN 已配置" "grep -q '^ADMIN_TOKEN=' /opt/wireguard-web/.env"
      chk "METRICS_TOKEN 已配置" "grep -q '^METRICS_TOKEN=' /opt/wireguard-web/.env" "旧版 .env 可手动补充"
    else
      echo "  [i] 未部署 Web UI"
    fi
    chk "IP 转发已开启" "[ \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = 1 ]" "sysctl -w net.ipv4.ip_forward=1"
    chk "DNS 解析正常" "getent hosts mirrors.aliyun.com || getent hosts www.google.com" "检查 /etc/resolv.conf"
    lp=$(grep '^ListenPort' "$WG_CONF" 2>/dev/null | cut -d' ' -f3)
    echo "  [i] WireGuard 监听端口：${lp:-未知}"
    echo "  [i] 客户端数：$(grep -c '^# BEGIN_PEER' "$WG_CONF" 2>/dev/null || echo 0)"
    df -h / 2>/dev/null | awk 'NR==2{print "  [i] 磁盘：已用 "$5"（剩余 "$4"）"}'
    free -m 2>/dev/null | awk 'NR==2{print "  [i] 内存：已用 "$3"MB / "$2"MB"}'
    echo "  ------------------------------"
    echo "  通过 $ok 项，问题 $bad 项"
    ;;
  help|*)
    echo "WireGuard 管理工具 (wgd)"
    echo "用法：wgd <命令> [参数]"
    echo
    echo "命令："
    echo "  status              查看服务状态"
    echo "  list                列出所有客户端"
    echo "  add <名称>          添加客户端"
    echo "  remove <名称>       删除客户端"
    echo "  qr <名称>           显示客户端 QR 码"
    echo "  config <名称>       查看客户端配置"
    echo "  limit <名称> [限制]  查看/设置流量限制 (1G/500M/0)"
    echo "  expire <名称> [日期] 查看/设置到期时间"
    echo "  cycle <名称> [周期]  查看/设置重置周期 (natural|30d|none)"
    echo "  reset <名称>        重置客户端流量"
    echo "  remark <名称> [备注] 查看/设置客户端备注"
    echo "  enable <名称>       启用客户端"
    echo "  disable <名称>      禁用客户端"
    echo "  limits             查看所有限制"
    echo "  server-limit [值]  查看/设置服务器总流量上限 (clear 清除)"
    echo "  sub <名称>          显示客户端订阅链接"
    echo "  rename <旧> <新>    重命名客户端"
    echo "  dns <名称> [DNS]    查看/设置客户端独立 DNS"
    echo "  set-many <名称s> [--limit 1G] [--expire 日期] [--cycle 30d]  批量修改"
    echo "  rate <名称> [下行] [上行]  查看/设置客户端限速 (MB/s，clear 清除)"
    echo "  rate-overquota <名称> [值] 超月配额时降到该速度 (MB/s，0=封禁)"
    echo "  qos [show|algo htb|tbf|total-down N|total-up N]  全局限速"
    echo "  backup             创建备份"
    echo "  backup-list        列出备份"
    echo "  restore <文件>     恢复备份"
    echo "  restart            重启 WireGuard"
    echo "  start              启动 WireGuard"
    echo "  stop               停止 WireGuard"
    echo "  log                查看实时日志"
    echo "  web [status|restart]  Web UI 管理"
    echo "  web-port [端口]    查看/修改 Web UI 端口"
    echo "  admin-token [reset] 查看/重置 API 管理员令牌"
    echo "  doctor             一键体检（DNS/端口/服务/模块/磁盘）"
    echo "  passwd             修改 Web UI 密码"
    echo "  uninstall [-y]     卸载 WireGuard"
    ;;
esac
WGDEOF
  chmod +x "$WGD_BIN"
  # 统一 Python 解释器（将行首缩进的 python3 调用替换为绝对路径）
  if [ -n "$PYTHON_BIN" ] && [ "$PYTHON_BIN" != "python3" ]; then
    sed -i "s|python3 - |$PYTHON_BIN - |g" "$WGD_BIN"
  fi
  rollback_files+=("$WGD_BIN")
  echo "CLI 管理工具已安装：wgd"
}

# ---------- 安装依赖 ----------
install_wget() {
  if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
    if [ "$auto" = 0 ]; then
      echo "本安装脚本需要 wget 工具。"
      read -n1 -r -p "按任意键安装 wget 并继续..."
    fi
    export DEBIAN_FRONTEND=noninteractive
    (set -x; apt-get -yqq update || apt-get -yqq update; apt-get -yqq install wget >/dev/null) || exiterr2
  fi
}

install_iproute() {
  if ! hash ip 2>/dev/null; then
    if [ "$auto" = 0 ]; then
      echo "本安装脚本需要 iproute 工具。"
      read -n1 -r -p "按任意键安装 iproute 并继续..."
    fi
    if [ "$os" = "debian" ] || [ "$os" = "ubuntu" ]; then
      export DEBIAN_FRONTEND=noninteractive
      (set -x; apt-get -yqq update || apt-get -yqq update; apt-get -yqq install iproute2 >/dev/null) || exiterr2
    elif [ "$os" = "openSUSE" ]; then
      (set -x; zypper install iproute2 >/dev/null) || exiterr4
    else
      (set -x; yum -y -q install iproute >/dev/null) || exiterr3
    fi
  fi
}

check_firewall() {
  firewall=""
  if ! systemctl is-active --quiet firewalld.service 2>/dev/null && ! hash iptables 2>/dev/null; then
    if [[ "$os" == "centos" || "$os" == "fedora" || "$os" == "openSUSE" ]]; then
      firewall="firewalld"
    elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
      firewall="iptables"
    fi
    if [[ "$firewall" == "firewalld" ]]; then
      echo "注意：将同时安装 firewalld（用于管理路由表，WireGuard 必需）。"
    fi
  fi
}

install_pkgs() {
  # 安装前确保 DNS 可用（避免 apt 无法解析镜像）
  ensure_dns

  # 非交互并保留本地配置文件，避免 dpkg conffile 提示导致安装中断
  export DEBIAN_FRONTEND=noninteractive
  APT_OPTS="-yqq -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

  if [[ "$os" == "ubuntu" ]]; then
    (set -x; apt-get $APT_OPTS update || apt-get $APT_OPTS update; apt-get $APT_OPTS install wireguard qrencode $firewall >/dev/null) || \
      { apt_mirror_fallback && (set -x; apt-get $APT_OPTS install wireguard qrencode $firewall >/dev/null) && : || exiterr2; }
  elif [[ "$os" == "debian" ]]; then
    (set -x; apt-get $APT_OPTS update || apt-get $APT_OPTS update; apt-get $APT_OPTS install wireguard qrencode $firewall >/dev/null) || \
      { apt_mirror_fallback && (set -x; apt-get $APT_OPTS install wireguard qrencode $firewall >/dev/null) && : || exiterr2; }
  elif [[ "$os" == "centos" && "$os_version" -ge 9 ]]; then
    (set -x; yum -y -q install epel-release >/dev/null; yum -y -q install wireguard-tools qrencode $firewall >/dev/null 2>&1) || exiterr3
    mkdir -p /etc/wireguard/
  elif [[ "$os" == "centos" && "$os_version" -eq 8 ]]; then
    (set -x; yum -y -q install epel-release elrepo-release >/dev/null; yum -y -q --nobest install kmod-wireguard >/dev/null 2>&1; yum -y -q install wireguard-tools qrencode $firewall >/dev/null 2>&1) || exiterr3
    mkdir -p /etc/wireguard/
  elif [[ "$os" == "fedora" ]]; then
    (set -x; dnf install -y wireguard-tools qrencode $firewall >/dev/null) || exiterr "dnf install 命令执行失败。"
    mkdir -p /etc/wireguard/
  elif [[ "$os" == "openSUSE" ]]; then
    (set -x; zypper install -y wireguard-tools qrencode $firewall >/dev/null) || exiterr4
    mkdir -p /etc/wireguard/
  fi
  [ ! -d /etc/wireguard ] && mkdir -p /etc/wireguard
  if [[ "$firewall" == "firewalld" ]]; then
    (set -x; systemctl enable --now firewalld.service >/dev/null 2>&1)
  fi
}

create_server_config() {
  cat <<EOF >"$WG_CONF"
# 请勿修改以下注释行，用于 xa_wg 脚本识别配置
# ENDPOINT $([[ -n "$public_ip" ]] && echo "$public_ip" || echo "$ip")

[Interface]
Address = 10.7.0.1/24$([[ -n "$ip6" ]] && echo ", fddd:2c4:2c4:2c4::1/64")
PrivateKey = $(wg genkey)
ListenPort = $port

EOF
  chmod 600 "$WG_CONF"
  rollback_files+=("$WG_CONF")
}

create_firewall_rules() {
  if systemctl is-active --quiet firewalld.service 2>/dev/null; then
    firewall-cmd -q --add-port="$port"/udp
    firewall-cmd -q --zone=trusted --add-source=10.7.0.0/24
    firewall-cmd -q --permanent --add-port="$port"/udp
    firewall-cmd -q --permanent --zone=trusted --add-source=10.7.0.0/24
    firewall-cmd -q --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE
    firewall-cmd -q --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE
    if [[ -n "$ip6" ]]; then
      firewall-cmd -q --zone=trusted --add-source=fddd:2c4:2c4:2c4::/64
      firewall-cmd -q --permanent --zone=trusted --add-source=fddd:2c4:2c4:2c4::/64
      firewall-cmd -q --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j MASQUERADE
      firewall-cmd -q --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j MASQUERADE
    fi
  else
    iptables_path=$(command -v iptables)
    ip6tables_path=$(command -v ip6tables)
    if [[ $(systemd-detect-virt) == "openvz" ]] && readlink -f "$(command -v iptables)" | grep -q "nft" && hash iptables-legacy 2>/dev/null; then
      iptables_path=$(command -v iptables-legacy)
      ip6tables_path=$(command -v ip6tables-legacy)
    fi
    cat > /etc/systemd/system/wg-iptables.service <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$iptables_path -w 5 -t nat -A POSTROUTING -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE
ExecStart=$iptables_path -w 5 -I INPUT -p udp --dport $port -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -s 10.7.0.0/24 -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -w 5 -t nat -D POSTROUTING -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE
ExecStop=$iptables_path -w 5 -D INPUT -p udp --dport $port -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -s 10.7.0.0/24 -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
    if [[ -n "$ip6" ]]; then
      cat >> /etc/systemd/system/wg-iptables.service <<EOF
ExecStart=$ip6tables_path -w 5 -t nat -A POSTROUTING -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j MASQUERADE
ExecStart=$ip6tables_path -w 5 -I FORWARD -s fddd:2c4:2c4:2c4::/64 -j ACCEPT
ExecStart=$ip6tables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$ip6tables_path -w 5 -t nat -D POSTROUTING -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j MASQUERADE
ExecStop=$ip6tables_path -w 5 -D FORWARD -s fddd:2c4:2c4:2c4::/64 -j ACCEPT
ExecStop=$ip6tables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
    fi
    echo "RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >> /etc/systemd/system/wg-iptables.service
    (set -x; systemctl enable --now wg-iptables.service >/dev/null 2>&1)
    rollback_files+=("/etc/systemd/system/wg-iptables.service")
  fi
}

update_sysctl() {
  mkdir -p /etc/sysctl.d
  conf_fwd="/etc/sysctl.d/99-wireguard-forward.conf"
  conf_opt="/etc/sysctl.d/99-wireguard-optimize.conf"
  echo 'net.ipv4.ip_forward=1' >"$conf_fwd"
  if [[ -n "$ip6" ]]; then
    echo "net.ipv6.conf.all.forwarding=1" >>"$conf_fwd"
  fi
  rollback_files+=("$conf_fwd")
  base_url="https://github.com/hwdsl2/vpn-extras/releases/download/v1.0.0"
  conf_url="$base_url/sysctl-wg-$os"
  [ "$auto" != 0 ] && conf_url="${conf_url}-auto"
  wget -t 3 -T 30 -q -O "$conf_opt" "$conf_url" 2>/dev/null ||
    curl -m 30 -fsL "$conf_url" -o "$conf_opt" 2>/dev/null ||
    { /bin/rm -f "$conf_opt"; touch "$conf_opt"; }
  if modprobe -q tcp_bbr &&
    printf '%s\n%s' "4.20" "$(uname -r)" | sort -C -V &&
    [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    cat >>"$conf_opt" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  fi
  sysctl -e -q -p "$conf_fwd"
  sysctl -e -q -p "$conf_opt"
}

update_rclocal() {
  ipt_cmd="systemctl restart wg-iptables.service"
  if ! grep -qs "$ipt_cmd" /etc/rc.local 2>/dev/null; then
    if [ ! -f /etc/rc.local ]; then
      echo '#!/bin/sh' >/etc/rc.local
    else
      if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
        sed --follow-symlinks -i '/^exit 0/d' /etc/rc.local
      fi
    fi
    cat >>/etc/rc.local <<EOF

$ipt_cmd
EOF
    if [ "$os" = "ubuntu" ] || [ "$os" = "debian" ]; then
      echo "exit 0" >>/etc/rc.local
    fi
    chmod +x /etc/rc.local
  fi
}

# ---------- 客户端管理 ----------
get_export_dir() {
  export_to_home_dir=0
  export_dir=~/
  if [ -n "$SUDO_USER" ] && getent group "$SUDO_USER" >/dev/null 2>&1; then
    user_home_dir=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    if [ -d "$user_home_dir" ] && [ "$user_home_dir" != "/" ]; then
      export_dir="$user_home_dir/"
      export_to_home_dir=1
    fi
  fi
}

select_client_ip() {
  octet=2
  while grep AllowedIPs "$WG_CONF" | cut -d "." -f 4 | cut -d "/" -f 1 | grep -q "^$octet$"; do
    ((octet++))
  done
  if [[ "$octet" -eq 255 ]]; then
    exiterr "已配置 253 个客户端，WireGuard 内部子网地址已用尽！"
  fi
}

new_client() {
  select_client_ip
  specify_ip=n
  if [ "$1" = "add_client" ] && [ "$add_client" = 0 ]; then
    echo; read -rp "是否为新客户端手动指定内部 IP 地址？[y/N]：" specify_ip
    until [[ "$specify_ip" =~ ^[yYnN]*$ ]]; do
      echo "$specify_ip：选择无效。"; read -rp "是否为新客户端手动指定内部 IP 地址？[y/N]：" specify_ip
    done
    if [[ ! "$specify_ip" =~ ^[yY]$ ]]; then
      echo "将自动为客户端分配 IP 地址：10.7.0.$octet。"
    fi
  fi
  if [[ "$specify_ip" =~ ^[yY]$ ]]; then
    echo; read -rp "请输入新客户端的 IP 地址（例如 10.7.0.X）：" client_ip
    octet=$(printf '%s' "$client_ip" | cut -d "." -f 4)
    until [[ $client_ip =~ ^10\.7\.0\.([2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$ ]] &&
      ! grep AllowedIPs "$WG_CONF" | cut -d "." -f 4 | cut -d "/" -f 1 | grep -q "^$octet$"; do
      if [[ ! $client_ip =~ ^10\.7\.0\.([2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$ ]]; then
        echo "IP 地址无效。必须在 10.7.0.2-10.7.0.254 范围内。"
      else
        echo "该 IP 地址已被使用，请选择其他地址。"
      fi
      read -rp "请输入新客户端的 IP 地址（例如 10.7.0.X）：" client_ip
      octet=$(printf '%s' "$client_ip" | cut -d "." -f 4)
    done
  fi
  key=$(wg genkey)
  psk=$(wg genpsk)
  cat <<EOF >>"$WG_CONF"
# BEGIN_PEER $client
# TRAFFIC_LIMIT=0
# EXPIRE=
# CYCLE_START=$(date +%Y-%m-%d)
# TRAFFIC_USED=0
# RESET_CYCLE=30d
# REMARK=
# DNS=
# RATE_DOWN=0
# RATE_UP=0
# OVER_QUOTA_RATE=0
# TOKEN=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
[Peer]
PublicKey = $(wg pubkey <<<"$key")
PresharedKey = $psk
AllowedIPs = 10.7.0.$octet/32$(grep -q 'fddd:2c4:2c4:2c4::1' "$WG_CONF" && echo ", fddd:2c4:2c4:2c4::$octet/128")
# END_PEER $client
EOF
  get_export_dir
  cat <<EOF >"$export_dir$client".conf
[Interface]
Address = 10.7.0.$octet/24$(grep -q 'fddd:2c4:2c4:2c4::1' "$WG_CONF" && echo ", fddd:2c4:2c4:2c4::$octet/64")
DNS = $dns
PrivateKey = $key

[Peer]
PublicKey = $(grep PrivateKey "$WG_CONF" | cut -d " " -f 3 | wg pubkey)
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $(grep '^# ENDPOINT' "$WG_CONF" | cut -d " " -f 3):$(grep ListenPort "$WG_CONF" | cut -d " " -f 3)
PersistentKeepalive = 25
EOF
  if [ "$export_to_home_dir" = 1 ]; then
    chown "$SUDO_USER:$SUDO_USER" "$export_dir$client".conf
  fi
  chmod 600 "$export_dir$client".conf
}

show_client_qr_code() {
  if hash qrencode 2>/dev/null; then
    qrencode -t UTF8 <"$export_dir$client".conf
    echo "以上为客户端配置的 QR 码，手机客户端可扫码导入。"
  else
    echo "qrencode 未安装，无法显示 QR 码。"
  fi
}

start_wg_service() {
  (set -x; systemctl enable --now wg-quick@wg0.service >/dev/null 2>&1)
}

# ---------- 卸载 ----------
remove_firewall_rules() {
  port=$(grep '^ListenPort' "$WG_CONF" 2>/dev/null | cut -d " " -f 3)
  [ -z "$port" ] && port=53
  # Web 端口可能被自定义，从 .env 读取
  local wp=""
  [ -f "$ENV_FILE" ] && wp=$(grep '^WEB_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
  [ -z "$wp" ] && wp=5666
  if systemctl is-active --quiet firewalld.service 2>/dev/null; then
    firewall-cmd -q --remove-port="$port"/udp 2>/dev/null
    firewall-cmd -q --zone=trusted --remove-source=10.7.0.0/24 2>/dev/null
    firewall-cmd -q --permanent --remove-port="$port"/udp 2>/dev/null
    firewall-cmd -q --permanent --zone=trusted --remove-source=10.7.0.0/24 2>/dev/null
    firewall-cmd -q --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE 2>/dev/null
    firewall-cmd -q --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j MASQUERADE 2>/dev/null
    firewall-cmd -q --permanent --remove-port=${wp}/tcp 2>/dev/null
    firewall-cmd -q --remove-port=${wp}/tcp 2>/dev/null
  else
    systemctl disable --now wg-iptables.service 2>/dev/null
    rm -f /etc/systemd/system/wg-iptables.service
    # 清理 Web UI 端口放行规则（避免卸载后端口仍对公网开放）
    if hash iptables 2>/dev/null; then
      while iptables -C INPUT -p tcp --dport ${wp} -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport ${wp} -j ACCEPT 2>/dev/null || break
      done
    fi
  fi
}

remove_sysctl_rules() {
  rm -f /etc/sysctl.d/99-wireguard-forward.conf /etc/sysctl.d/99-wireguard-optimize.conf
  if [ ! -f /usr/sbin/openvpn ] && [ ! -f /usr/sbin/ipsec ] && [ ! -f /usr/local/sbin/ipsec ]; then
    echo 0 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
    echo 0 >/proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null
  fi
}

remove_rclocal_rules() {
  ipt_cmd="systemctl restart wg-iptables.service"
  if grep -qs "$ipt_cmd" /etc/rc.local 2>/dev/null; then
    sed --follow-symlinks -i "/^$ipt_cmd/d" /etc/rc.local 2>/dev/null
  fi
}

remove_web_ui() {
  systemctl disable --now wg-web.service 2>/dev/null
  systemctl disable --now wg-qos.service 2>/dev/null
  systemctl disable --now wg-limiter.timer 2>/dev/null
  systemctl disable --now wg-limiter.service 2>/dev/null
  systemctl disable --now wg-health.timer 2>/dev/null
  systemctl disable --now wg-health.service 2>/dev/null
  systemctl disable --now wg-traffic.timer 2>/dev/null
  systemctl disable --now wg-traffic.service 2>/dev/null
  rm -rf "$WEB_DIR"
  rm -f /etc/systemd/system/wg-web.service
  rm -f /etc/systemd/system/wg-qos.service
  rm -f /etc/systemd/system/wg-limiter.service
  rm -f /etc/systemd/system/wg-limiter.timer
  rm -f /etc/systemd/system/wg-health.service
  rm -f /etc/systemd/system/wg-health.timer
  rm -f /etc/systemd/system/wg-traffic.service
  rm -f /etc/systemd/system/wg-traffic.timer
  # 清理 wg-quick@wg0 熔断阈值 drop-in
  rm -f /etc/systemd/system/wg-quick@wg0.service.d/10-override.conf
  rmdir /etc/systemd/system/wg-quick@wg0.service.d 2>/dev/null
  systemctl reset-failed wg-quick@wg0 2>/dev/null
  # 清理 QoS（tc 规则 + ifb0）
  tc qdisc del dev wg0 root 2>/dev/null
  tc qdisc del dev wg0 ingress 2>/dev/null
  if ip link show ifb0 >/dev/null 2>&1; then
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link set ifb0 down 2>/dev/null
    ip link delete ifb0 type ifb 2>/dev/null
  fi
  systemctl daemon-reload 2>/dev/null
}

remove_client_confs() {
  for dir in /root /home/*; do
    if [ -d "$dir" ]; then
      find "$dir" -maxdepth 1 -name "*.conf" -type f 2>/dev/null | while read f; do
        if grep -q "^\[Interface\]" "$f" 2>/dev/null && grep -q "^\[Peer\]" "$f" 2>/dev/null; then
          rm -f "$f"
        fi
      done
    fi
  done
}

remove_pkgs() {
  if [[ "$os" == "ubuntu" ]] || [[ "$os" == "debian" ]]; then
    rm -rf /etc/wireguard/
    apt-get remove --purge -y wireguard wireguard-tools qrencode >/dev/null 2>&1
  elif [[ "$os" == "centos" && "$os_version" -ge 9 ]]; then
    yum -y -q remove wireguard-tools qrencode >/dev/null 2>&1
    rm -rf /etc/wireguard/
  elif [[ "$os" == "centos" && "$os_version" -eq 8 ]]; then
    yum -y -q remove kmod-wireguard wireguard-tools qrencode >/dev/null 2>&1
    rm -rf /etc/wireguard/
  elif [[ "$os" == "fedora" ]]; then
    dnf remove -y wireguard-tools qrencode >/dev/null 2>&1
    rm -rf /etc/wireguard/
  elif [[ "$os" == "openSUSE" ]]; then
    zypper remove -y wireguard-tools qrencode >/dev/null 2>&1
    rm -rf /etc/wireguard/
  fi
}

# ---------- 交互式菜单 ----------
select_menu_option() {
  echo; echo "WireGuard 已安装完成。"; echo
  echo "请选择操作："
  echo "   1) 添加新客户端"
  echo "   2) 列出所有已存在的客户端"
  echo "   3) 删除指定客户端"
  echo "   4) 显示指定客户端的 QR 码"
  echo "   5) 卸载 WireGuard"
  echo "   6) 退出"
  read -rp "选择操作 [1-6]：" option
  until [[ "$option" =~ ^[1-6]$ ]]; do
    echo "$option：选择无效。"; read -rp "选择操作 [1-6]：" option
  done
}

show_clients() {
  grep '^# BEGIN_PEER' "$WG_CONF" | cut -d ' ' -f 3 | nl -s ') '
}

check_clients() {
  num_of_clients=$(grep -c '^# BEGIN_PEER' "$WG_CONF")
  if [[ "$num_of_clients" = 0 ]]; then
    echo; echo "当前无已配置的客户端！"; exit 1
  fi
}

print_check_clients() { echo; echo "正在检查已存在的客户端..."; }
print_client_total() {
  if [ "$num_of_clients" = 1 ]; then printf '\n%s\n' "总计：1 个客户端"
  elif [ -n "$num_of_clients" ]; then printf '\n%s\n' "总计：$num_of_clients 个客户端"; fi
}

select_client_to() {
  echo; echo "请选择要$1的客户端："; show_clients
  read -rp "客户端编号：" client_num
  [ -z "$client_num" ] && { echo "已中止。"; exit 1; }
  until [[ "$client_num" =~ ^[0-9]+$ && "$client_num" -le "$num_of_clients" ]]; do
    echo "$client_num：选择无效。"; read -rp "客户端编号：" client_num
    [ -z "$client_num" ] && { echo "已中止。"; exit 1; }
  done
  client=$(grep '^# BEGIN_PEER' "$WG_CONF" | cut -d ' ' -f 3 | sed -n "$client_num"p)
}

confirm_remove_client() {
  if [ "$assume_yes" != 1 ]; then
    echo; read -rp "确认删除 $client 吗？[y/N]：" remove
    until [[ "$remove" =~ ^[yYnN]*$ ]]; do
      echo "$remove：选择无效。"; read -rp "确认删除 $client 吗？[y/N]：" remove
    done
  else remove=y; fi
}

remove_client_conf() {
  get_export_dir
  wg_file="$export_dir$client.conf"
  [ -f "$wg_file" ] && rm -f "$wg_file"
}

remove_client_wg() {
  wg set wg0 peer "$(sed -n "/^# BEGIN_PEER $client$/,\$p" "$WG_CONF" | grep -m 1 PublicKey | cut -d " " -f 3)" remove 2>/dev/null
  sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" "$WG_CONF"
  remove_client_conf
}

check_client_conf() {
  get_export_dir
  wg_file="$export_dir$client.conf"
  if [ ! -f "$wg_file" ]; then
    echo "错误：无法显示 QR 码，客户端配置文件 $wg_file 不存在。" >&2
    echo "       您可以重新运行此脚本并添加新客户端。" >&2; exit 1
  fi
}

confirm_remove_wg() {
  if [ "$assume_yes" != 1 ]; then
    echo; read -rp "确认卸载 WireGuard 吗？[y/N]：" remove
    until [[ "$remove" =~ ^[yYnN]*$ ]]; do
      echo "$remove：选择无效。"; read -rp "确认卸载 WireGuard 吗？[y/N]：" remove
    done
  else remove=y; fi
}

enter_client_name() {
  echo; echo "请为新客户端输入名称："
  read -rp "名称：" unsanitized_client
  [ -z "$unsanitized_client" ] && { echo "已中止。"; exit 1; }
  set_client_name
  while [[ -z "$client" ]] || grep -q "^# BEGIN_PEER $client$" "$WG_CONF"; do
    if [ -z "$client" ]; then echo "客户端名称无效。仅可使用单个单词，特殊字符仅支持 - 和 _。"
    else echo "$client：名称已存在，请重新输入。"; fi
    read -rp "名称：" unsanitized_client
    [ -z "$unsanitized_client" ] && { echo "已中止。"; exit 1; }
    set_client_name
  done
}

update_wg_conf() {
  wg addconf wg0 <(sed -n "/^# BEGIN_PEER $client/,/^# END_PEER $client/p" "$WG_CONF") 2>/dev/null
}

# ============================================================
# 主函数
# ============================================================
wgsetup() {
  check_root
  check_shell
  check_kernel
  check_os
  check_os_ver
  check_container

  WG_CONF="/etc/wireguard/wg0.conf"

  auto=0; assume_yes=0; add_client=0; list_clients=0
  remove_client=0; show_client_qr=0; remove_wg=0
  public_ip=""; server_addr=""; server_port=""; first_client_name=""
  unsanitized_client=""; client=""; dns=""; dns1=""; dns2=""
  ip=""; port=""; ip6=""; firewall=""; use_dns_name=0
  deploy_web=0; web_username=""; web_password=""; web_expose=0; web_disabled=0
  web_port=5666; trust_proxy=0
  rollback_files=()

  parse_args "$@"
  check_args

  if [ -e "$WG_CONF" ]; then
    if [ ! -f "$WGD_BIN" ]; then
      create_wgd_cli
    fi
    if [ "$0" != "/etc/wireguard/wg.sh" ]; then
      cp "$0" /etc/wireguard/wg.sh 2>/dev/null
      chmod +x /etc/wireguard/wg.sh
    fi
  fi

  if [ "$add_client" = 1 ]; then
    show_header
    if [ -z "$dns" ]; then
      auto_detect_dns
      [ -z "$dns" ] && dns="223.5.5.5"
    fi
    new_client add_client
    update_wg_conf
    echo; show_client_qr_code
    echo; echo "$client 添加成功。配置文件已保存至：$export_dir$client.conf"
    exit 0
  fi

  if [ "$list_clients" = 1 ]; then
    show_header; print_check_clients; check_clients
    echo; show_clients; print_client_total; exit 0
  fi

  if [ "$remove_client" = 1 ]; then
    show_header; confirm_remove_client
    if [[ "$remove" =~ ^[yY]$ ]]; then
      echo; echo "正在删除客户端 $client..."
      remove_client_wg
      echo; echo "$client 删除成功！"; exit 0
    else echo; echo "$client 删除操作已中止！"; exit 1; fi
  fi

  if [ "$show_client_qr" = 1 ]; then
    show_header; echo; get_export_dir; check_client_conf
    show_client_qr_code; echo; echo "'$client' 的配置文件路径：$wg_file"; exit 0
  fi

  if [ "$remove_wg" = 1 ]; then
    show_header; confirm_remove_wg
    if [[ "$remove" =~ ^[yY]$ ]]; then
      echo; echo "正在卸载 WireGuard，请稍候..."
      remove_web_ui
      remove_firewall_rules
      systemctl disable --now wg-quick@wg0.service 2>/dev/null
      remove_sysctl_rules
      remove_rclocal_rules
      remove_client_confs
      remove_pkgs
      rm -f "$WGD_BIN"
      restore_dns
      echo; echo "WireGuard 卸载成功！"; exit 0
    else echo; echo "WireGuard 卸载操作已中止！"; exit 1; fi
  fi

  if [[ ! -e "$WG_CONF" ]]; then
    trap rollback_cleanup ERR

    check_nftables
    install_wget
    install_iproute

    # 端口 53 若被 systemd-resolved 占用，先释放并确保 DNS 可用
    # （必须在 detect_ip / apt 之前，否则 DNS 失效会导致公网 IP 检测与安装失败）
    if [ -z "$server_port" ] || [ "$server_port" = "53" ]; then
      check_port_conflict 53
    fi
    ensure_dns

    if [ "$auto" = 0 ]; then
      show_header2
      echo "开始配置前，需要向您确认几个问题。"
      echo "若您接受默认选项，直接按回车键即可。"
    else
      show_header; echo; echo "正在使用自动选项配置 WireGuard。"
    fi

    if [ "$auto" = 0 ]; then
      enter_server_address
    else
      if [ -n "$server_addr" ]; then
        ip="$server_addr"
      else
        detect_ip
        check_nat_ip
      fi
    fi

    detect_ipv6
    select_port
    if [ "$port" = 53 ]; then
      check_port_conflict 53
    else
      check_port_conflict "$port"
    fi
    enter_first_client_name

    if [ -z "$dns" ]; then
      select_dns
    fi

    check_firewall

    if [ "$auto" = 0 ]; then
      echo; echo "WireGuard 安装配置已准备就绪。"
      printf "是否继续安装？[Y/n] "; read -r response
      case $response in [yY][eE][sS]|[yY]|'') : ;; *) echo "已中止。未修改任何系统配置。" >&2; exit 1 ;; esac
    fi

    echo; echo "正在安装 WireGuard，请稍候..."
    install_pkgs
    create_server_config
    update_sysctl
    create_firewall_rules
    update_rclocal

    new_client
    start_wg_service
    echo
    show_client_qr_code

    if [ "$web_disabled" = 1 ]; then
      deploy_web=0; web_expose=0
    elif [ "$auto" != 0 ]; then
      deploy_web=1
      web_expose=1
    else
      echo; echo "是否部署 Web 管理界面？（提供浏览器管理 + CLI 工具 wgd）"
      printf "是否部署？[Y/n] "; read -r deploy_response
      case $deploy_response in [yY][eE][sS]|[yY]|'') deploy_web=1 ;; *) deploy_web=0 ;; esac
      if [ "$deploy_web" = 1 ]; then
        echo "是否允许从外网访问 Web 管理界面？（默认仅本机访问）"
        printf "对外暴露？[y/N] "; read -r expose_response
        case $expose_response in [yY][eE][sS]|[yY]) web_expose=1 ;; *) web_expose=0 ;; esac
      fi
    fi

    if [ "$deploy_web" = 1 ]; then
      deploy_web_ui
      create_wgd_cli
      deploy_limiter
    fi

    if [ "$0" != "/etc/wireguard/wg.sh" ]; then
      cp "$0" /etc/wireguard/wg.sh 2>/dev/null
      chmod +x /etc/wireguard/wg.sh
      rollback_files+=("/etc/wireguard/wg.sh")
    fi

    trap - ERR
    echo
    if ! modprobe -nq wireguard 2>/dev/null; then
      echo "警告！安装已完成，但 WireGuard 内核模块未能加载。请重启系统以加载最新内核。"
    else
      echo "安装完成！"
    fi
    echo; echo "客户端配置文件已保存至：$export_dir$client.conf"
    echo "如需添加新客户端，重新运行此脚本即可。"

  else
    show_header
    select_menu_option
    case "$option" in
    1)
      enter_client_name
      select_dns
      new_client add_client
      update_wg_conf
      echo; show_client_qr_code
      echo; echo "$client 添加成功。配置文件已保存至：$export_dir$client.conf"; exit 0 ;;
    2)
      print_check_clients; check_clients; echo; show_clients; print_client_total; exit 0 ;;
    3)
      check_clients; select_client_to "删除"; confirm_remove_client
      if [[ "$remove" =~ ^[yY]$ ]]; then
        echo; echo "正在删除客户端 $client..."; remove_client_wg
        echo; echo "$client 删除成功！"; exit 0
      else echo; echo "$client 删除操作已中止！"; exit 1; fi ;;
    4)
      check_clients; select_client_to "显示 QR 码"; echo; get_export_dir; check_client_conf
      show_client_qr_code; echo; echo "'$client' 的配置文件路径：$wg_file"; exit 0 ;;
    5)
      confirm_remove_wg
      if [[ "$remove" =~ ^[yY]$ ]]; then
        echo; echo "正在卸载 WireGuard，请稍候..."
        remove_web_ui
        remove_firewall_rules
        systemctl disable --now wg-quick@wg0.service 2>/dev/null
        remove_sysctl_rules; remove_rclocal_rules
        remove_client_confs; remove_pkgs
        rm -f "$WGD_BIN"
        restore_dns
        echo; echo "WireGuard 卸载成功！"; exit 0
      else echo; echo "WireGuard 卸载操作已中止！"; exit 1; fi ;;
    6) exit 0 ;;
    esac
  fi
}

wgsetup "$@"
exit 0
