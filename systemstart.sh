#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# 日志 & 通用工具
# =========================
info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

[[ "${EUID:-0}" -eq 0 ]] || { err "请用 root 执行：sudo bash $0"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 临时文件统一清理（避免你在函数里反复 trap 覆盖）
TMP_FILES=()
cleanup() {
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "${f:-}" ]] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup EXIT

# =========================
# 可调开关（可用环境变量覆盖）
# =========================
: "${DISABLE_IPV6:=1}"            # 1=关闭IPv6
: "${DISABLE_PING:=1}"            # 1=不响应ping
: "${ENABLE_BBR:=1}"              # 1=尝试开启BBR（内核支持才启）
: "${ENABLE_TCP_FASTOPEN:=1}"     # 1=启用tcp_fastopen=3
: "${PANIC_ON_OOM:=1}"            # 1=OOM触发panic（配合kernel.panic会重启；有风险）
: "${APPLY_CORE_PATTERN:=0}"      # 1=写 kernel.core_pattern=core_%e（可能影响coredump策略）

# “2G”判断阈值（MB）
# 很多 2G VPS 的 MemTotal 可能只有 19xxMB，默认 1900 更贴近“标称2G”
: "${TWO_G_THRESHOLD_MB:=1900}"

# 文件路径
: "${SYSCTL_FILE:=/etc/sysctl.d/99-oneclick-init.conf}"
: "${SWAPFILE:=/swapfile}"
: "${BBR_MODULES_FILE:=/etc/modules-load.d/bbr.conf}"

# 可选：强制重建 swapfile（默认不动已存在 swap）
: "${FORCE_RECREATE_SWAPFILE:=0}"  # 1=如果当前启用的就是 /swapfile，则重建；其他swap不动

# =========================
# 基础信息/检测
# =========================
get_mem_mb() { awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo; }

sysctl_path() { echo "/proc/sys/${1//./\/}"; }
sysctl_exists() { [[ -e "$(sysctl_path "$1")" ]]; }

detect_virt_warn() {
  if have_cmd systemd-detect-virt; then
    local vt
    vt="$(systemd-detect-virt 2>/dev/null || echo "none")"
    if [[ "$vt" != "none" ]]; then
      warn "检测到虚拟化/容器环境：$vt。部分 sysctl / swap 可能被宿主机限制，出现 WARN 属正常现象。"
    fi
  fi
}

# =========================
# apt 安装
# =========================
ensure_pkg() {
  local pkgs=("$@")
  export DEBIAN_FRONTEND=noninteractive
  info "apt update..."
  apt-get update -yqq
  info "安装：${pkgs[*]}"
  apt-get install -yqq --no-install-recommends "${pkgs[@]}"
}

# =========================
# Swap 管理
# =========================
swap_is_active() {
  swapon --show --noheadings 2>/dev/null | grep -q .
}

swapfile_is_active() {
  swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -Fxq "$SWAPFILE"
}

remove_swapfile_fstab_entry() {
  # 清理旧条目，避免失败后残留坏状态
  sed -i "\|^[[:space:]]*${SWAPFILE}[[:space:]]|d" /etc/fstab 2>/dev/null || true
}

create_swap_if_needed() {
  if swap_is_active; then
    # 已有 swap：默认不折腾
    if [[ "$FORCE_RECREATE_SWAPFILE" == "1" ]] && swapfile_is_active; then
      warn "FORCE_RECREATE_SWAPFILE=1 且当前启用的是 ${SWAPFILE}，将尝试重建 swapfile。"
      swapoff "$SWAPFILE" 2>/dev/null || true
    else
      info "检测到系统已有 swap 正在使用，跳过创建。"
      swapon --show || true
      return 0
    fi
  fi

  local mem_mb swap_g
  mem_mb="$(get_mem_mb)"
  info "检测到内存：${mem_mb} MB"

  # 规则：<2G -> 2G；>=2G -> 1G
  if (( mem_mb < TWO_G_THRESHOLD_MB )); then
    swap_g=2
  else
    swap_g=1
  fi
  info "按规则：内存 < ${TWO_G_THRESHOLD_MB}MB -> 2G swap；否则 -> 1G swap。将创建：${swap_g}G"

  local need_mb=$((swap_g * 1024))
  local avail_mb
  avail_mb="$(df -Pm / | awk 'NR==2{print $4}')"

  if (( avail_mb < need_mb + 256 )); then
    warn "磁盘剩余空间不足（可用约 ${avail_mb}MB，需要至少约 $((need_mb+256))MB），跳过创建 swap。"
    return 1
  fi

  local fstype
  fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  info "根分区文件系统：${fstype:-unknown}"

  # 清理旧 swapfile 与 fstab 条目，避免坏状态
  remove_swapfile_fstab_entry
  rm -f "$SWAPFILE"

  # 生成 swapfile
  if [[ "$fstype" == "btrfs" ]]; then
    ensure_pkg btrfs-progs || true
    if have_cmd btrfs && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
      info "Btrfs：使用 btrfs filesystem mkswapfile 创建 swapfile"
      if ! btrfs filesystem mkswapfile --size "${swap_g}G" "$SWAPFILE"; then
        warn "Btrfs mkswapfile 失败，跳过 swap 创建。"
        rm -f "$SWAPFILE"
        return 1
      fi
    else
      warn "Btrfs：未找到可用 mkswapfile，尝试传统 dd（失败建议改用 swap 分区）。"
      touch "$SWAPFILE"
      have_cmd chattr && chattr +C "$SWAPFILE" 2>/dev/null || true
      have_cmd btrfs && btrfs property set "$SWAPFILE" compression none 2>/dev/null || true
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((swap_g*1024)) status=progress
    fi
  else
    if have_cmd fallocate && fallocate -l "${swap_g}G" "$SWAPFILE" 2>/dev/null; then
      :
    else
      warn "fallocate 不可用/失败，改用 dd 创建 swapfile"
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((swap_g*1024)) status=progress
    fi
  fi

  chmod 600 "$SWAPFILE"

  # mkswap / swapon 失败要清理，防止坏状态
  if ! mkswap "$SWAPFILE" >/dev/null 2>&1; then
    warn "mkswap 失败：$SWAPFILE（可能文件系统/属性不满足 swapfile 要求）"
    rm -f "$SWAPFILE"
    return 1
  fi

  if ! swapon "$SWAPFILE" 2>/dev/null; then
    warn "swapon 失败：$SWAPFILE（容器限制/btrfs/xfs reflink/洞文件等常见原因），已清理并跳过"
    rm -f "$SWAPFILE"
    return 1
  fi

  echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
  info "已写入 /etc/fstab：${SWAPFILE}"

  info "swap 已启用："
  swapon --show || true
  return 0
}

# =========================
# BBR 支持与开机加载
# =========================
bbr_supported() {
  have_cmd modprobe || return 1
  modprobe sch_fq 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || true
  local avail
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  echo "$avail" | grep -qw bbr
}

enable_bbr_modules_if_supported() {
  if [[ "$ENABLE_BBR" != "1" ]]; then
    warn "ENABLE_BBR=0：跳过 BBR（并清理旧 modules-load 文件）"
    rm -f "$BBR_MODULES_FILE" 2>/dev/null || true
    return 1
  fi

  if bbr_supported; then
    info "内核支持 BBR，写入开机加载模块：$BBR_MODULES_FILE"
    cat > "$BBR_MODULES_FILE" <<'EOF'
sch_fq
tcp_bbr
EOF
    return 0
  else
    warn "未检测到 BBR 支持，跳过写入 modules-load（并清理旧文件）。"
    rm -f "$BBR_MODULES_FILE" 2>/dev/null || true
    return 1
  fi
}

# =========================
# sysctl：只写入“设置成功”的项
# =========================
try_set_sysctl_and_persist() {
  local out="$1" key="$2" val="$3"

  if ! sysctl_exists "$key"; then
    # 不支持/不存在就跳过（容器环境很常见）
    warn "跳过（内核不支持/不存在）：$key"
    return 0
  fi

  if sysctl -w "${key}=${val}" >/dev/null 2>&1; then
    echo "${key} = ${val}" >> "$out"
    return 0
  else
    warn "设置失败（值不被接受/功能不支持）：${key} = ${val}"
    return 0
  fi
}

apply_advanced_tuning() {
  info "生成 sysctl：$SYSCTL_FILE（按内存自动分档）"

  local mem_mb profile buf_max backlog somaxconn min_free
  mem_mb="$(get_mem_mb)"

  # 分档策略：小(<2G) / 中(2-4G) / 大(>4G)
  if (( mem_mb < TWO_G_THRESHOLD_MB )); then
    profile="小内存 (<2G)"
    buf_max=$((4*1024*1024))     # 4MB
    backlog=4096
    somaxconn=4096
    min_free=32768               # 32MB
  elif (( mem_mb < 4096 )); then
    profile="中等 (2-4G)"
    buf_max=10147595             # ~9.7MB（参考你那套）
    backlog=8192
    somaxconn=8192
    min_free=65536               # 64MB
  else
    profile="大内存 (>4G)"
    buf_max=$((16*1024*1024))    # 16MB
    backlog=16384
    somaxconn=16384
    min_free=131072              # 128MB
  fi

  info "匹配档位：${profile}（mem=${mem_mb}MB, buf_max=${buf_max}, backlog=${backlog}, somaxconn=${somaxconn}, min_free=${min_free}）"

  local tmp
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  chmod 0644 "$tmp"

  {
    echo "# One-click init + tuning"
    echo "# Generated: $(date -u '+%F %T UTC')"
    echo "# Profile: ${profile}"
    echo "# TWO_G_THRESHOLD_MB=${TWO_G_THRESHOLD_MB}"
    echo "# DISABLE_IPV6=${DISABLE_IPV6} DISABLE_PING=${DISABLE_PING} ENABLE_BBR=${ENABLE_BBR} FASTOPEN=${ENABLE_TCP_FASTOPEN}"
    echo "# PANIC_ON_OOM=${PANIC_ON_OOM} APPLY_CORE_PATTERN=${APPLY_CORE_PATTERN}"
    echo
  } > "$tmp"

  # ----- kernel -----
  # pid_max：只在当前值 < 65535 时才设置，避免“降级”
  if sysctl_exists kernel.pid_max; then
    local cur_pid
    cur_pid="$(cat "$(sysctl_path kernel.pid_max)" 2>/dev/null || echo "")"
    if [[ "$cur_pid" =~ ^[0-9]+$ ]] && (( cur_pid < 65535 )); then
      try_set_sysctl_and_persist "$tmp" kernel.pid_max 65535
    else
      info "kernel.pid_max=${cur_pid:-unknown}（不低于 65535，不做降级）"
    fi
  fi

  try_set_sysctl_and_persist "$tmp" kernel.panic 1
  try_set_sysctl_and_persist "$tmp" kernel.sysrq 1
  try_set_sysctl_and_persist "$tmp" kernel.printk "3 4 1 3"
  try_set_sysctl_and_persist "$tmp" kernel.numa_balancing 0
  try_set_sysctl_and_persist "$tmp" kernel.sched_autogroup_enabled 0

  if [[ "$APPLY_CORE_PATTERN" == "1" ]]; then
    try_set_sysctl_and_persist "$tmp" kernel.core_pattern "core_%e"
  else
    info "跳过 kernel.core_pattern（如需启用：APPLY_CORE_PATTERN=1 bash init.sh）"
  fi

  # ----- vm -----
  # 有 swap 才写 swappiness（但如果系统已有 swap 分区也算 active）
  if swap_is_active; then
    try_set_sysctl_and_persist "$tmp" vm.swappiness 5
  fi
  try_set_sysctl_and_persist "$tmp" vm.dirty_ratio 5
  try_set_sysctl_and_persist "$tmp" vm.dirty_background_ratio 2
  try_set_sysctl_and_persist "$tmp" vm.overcommit_memory 1
  try_set_sysctl_and_persist "$tmp" vm.min_free_kbytes "${min_free}"

  if [[ "$PANIC_ON_OOM" == "1" ]]; then
    # 注意：可能导致 OOM 重启循环（看你业务是否接受）
    try_set_sysctl_and_persist "$tmp" vm.panic_on_oom 1
  else
    info "PANIC_ON_OOM=0：跳过 vm.panic_on_oom"
  fi

  # ----- IPv6 / Ping -----
  if [[ "$DISABLE_IPV6" == "1" ]]; then
    try_set_sysctl_and_persist "$tmp" net.ipv6.conf.all.disable_ipv6 1
    try_set_sysctl_and_persist "$tmp" net.ipv6.conf.default.disable_ipv6 1
    try_set_sysctl_and_persist "$tmp" net.ipv6.conf.lo.disable_ipv6 1
  fi

  if [[ "$DISABLE_PING" == "1" ]]; then
    try_set_sysctl_and_persist "$tmp" net.ipv4.icmp_echo_ignore_all 1
  fi
  try_set_sysctl_and_persist "$tmp" net.ipv4.icmp_echo_ignore_broadcasts 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.icmp_ignore_bogus_error_responses 1

  # ----- net.core -----
  if have_cmd modprobe; then modprobe sch_fq 2>/dev/null || true; fi
  try_set_sysctl_and_persist "$tmp" net.core.default_qdisc fq

  try_set_sysctl_and_persist "$tmp" net.core.netdev_max_backlog "${backlog}"
  try_set_sysctl_and_persist "$tmp" net.core.somaxconn "${somaxconn}"
  try_set_sysctl_and_persist "$tmp" net.core.rmem_max "${buf_max}"
  try_set_sysctl_and_persist "$tmp" net.core.wmem_max "${buf_max}"
  try_set_sysctl_and_persist "$tmp" net.core.rmem_default 262144
  try_set_sysctl_and_persist "$tmp" net.core.wmem_default 262144
  try_set_sysctl_and_persist "$tmp" net.core.optmem_max 262144

  # ----- TCP -----
  if [[ "$ENABLE_TCP_FASTOPEN" == "1" ]]; then
    try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_fastopen 3
  fi

  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_timestamps 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_tw_reuse 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_fin_timeout 10
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_slow_start_after_idle 0
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_max_tw_buckets 32768
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_sack 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_fack 1

  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_rmem "32768 262144 ${buf_max}"
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_wmem "32768 262144 ${buf_max}"
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_mtu_probing 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_notsent_lowat 524288
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_window_scaling 1

  # 你参考里 35 很容易坑，建议稳一点用 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_adv_win_scale 1

  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_moderate_rcvbuf 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_no_metrics_save 1

  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_max_syn_backlog "${backlog}"
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_max_orphans 32768
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_synack_retries 2
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_syn_retries 2
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_abort_on_overflow 0
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_stdurg 0

  # RFC1337 建议开启保护
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_rfc1337 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_syncookies 1

  try_set_sysctl_and_persist "$tmp" net.ipv4.ip_local_port_range "1024 65535"
  try_set_sysctl_and_persist "$tmp" net.ipv4.ip_no_pmtu_disc 0
  try_set_sysctl_and_persist "$tmp" net.ipv4.route.gc_timeout 100

  try_set_sysctl_and_persist "$tmp" net.ipv4.neigh.default.gc_stale_time 120
  try_set_sysctl_and_persist "$tmp" net.ipv4.neigh.default.gc_thresh3 4096
  try_set_sysctl_and_persist "$tmp" net.ipv4.neigh.default.gc_thresh2 2048
  try_set_sysctl_and_persist "$tmp" net.ipv4.neigh.default.gc_thresh1 512

  try_set_sysctl_and_persist "$tmp" net.ipv4.conf.all.rp_filter 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.conf.default.rp_filter 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.conf.all.arp_announce 2
  try_set_sysctl_and_persist "$tmp" net.ipv4.conf.default.arp_announce 2
  try_set_sysctl_and_persist "$tmp" net.ipv4.conf.all.arp_ignore 1
  try_set_sysctl_and_persist "$tmp" net.ipv4.conf.default.arp_ignore 1

  # ----- BBR（仅支持时）-----
  if [[ "$ENABLE_BBR" == "1" ]] && bbr_supported; then
    try_set_sysctl_and_persist "$tmp" net.ipv4.tcp_congestion_control bbr
  else
    warn "BBR 未启用（ENABLE_BBR=${ENABLE_BBR} 或内核不支持）"
  fi

  # 原子替换落盘
  install -m 0644 "$tmp" "$SYSCTL_FILE"
  info "已写入：$SYSCTL_FILE"

  # 关键：确保我们的文件最终生效（不要只 sysctl --system，可能被其它配置覆盖）
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
}

# =========================
# 状态输出
# =========================
status_check() {
  info "========== 核心状态检查 =========="
  info "Swap 状态："
  swapon --show || true
  info "IPv6 禁用(all): $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '未知')"
  info "禁 Ping: $(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo '未知')"
  info "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
  info "default_qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
  info "rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo '未知')"
  info "somaxconn: $(sysctl -n net.core.somaxconn 2>/dev/null || echo '未知')"
}

# =========================
# main
# =========================
main() {
  info "开始 Debian 一键初始化与深度调优..."

  detect_virt_warn

  # 依赖：procps(sysctl), kmod(modprobe), util-linux(swapon/mkswap) 这些在某些极简系统不一定齐
  ensure_pkg sudo curl ca-certificates procps kmod util-linux

  create_swap_if_needed || true
  enable_bbr_modules_if_supported || true
  apply_advanced_tuning

  status_check
  info "脚本执行完毕！"
}

main "$@"