#!/usr/bin/env bash
# 生产环境：后台启动或注册 systemd。二进制与源码不一致时先编译。
# 没有源码树时只使用现有二进制。启动后与当前终端分离。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# shellcheck source=start-lib.sh
. "$ROOT/start-lib.sh"
setup_build_path

umask 077

RUN_DIR="${DAVBOX_RUN_DIR:-$ROOT/.run/prod}"
PID_FILE="$RUN_DIR/davbox.pid"
LOG_FILE="$RUN_DIR/davbox.log"
CONF_FILE="$RUN_DIR/davbox.conf"
LOCK_FILE="$RUN_DIR/start.lock"
DEV_PID_FILE="$ROOT/.run/dev/davbox.pid"
DEV_CONF_FILE="$ROOT/.run/dev/start.conf"

FACTORY_ADDR="0.0.0.0:18900"
DEFAULT_ADDR="$FACTORY_ADDR"
DEFAULT_DATA="./data"
DEFAULT_AUTH="builtin"
DEFAULT_BIN="$ROOT/davbox"
LAST_LISTEN=""
SERVICE_NAME="${DAVBOX_SERVICE:-davbox}"

usage() {
  cat <<'EOF'
用法（生产环境）：
  ./start-prod.sh           后台启动已编译的 davbox
  ./start-prod.sh start     同上
  ./start-prod.sh stop      停止
  ./start-prod.sh restart   按已保存（或环境变量）配置重启
  ./start-prod.sh status    查看状态
  ./start-prod.sh log       打印最近日志
  ./start-prod.sh help      显示本说明

  ./start-prod.sh service install     注册 systemd 服务并开机自启
  ./start-prod.sh service uninstall   取消开机自启并移除单元
  ./start-prod.sh service status      查看 systemd 状态
  ./start-prod.sh service start|stop|restart
  ./start-prod.sh service enable|disable   只改开机自启，不立刻启停

有源码时会比对二进制与源码，不一致则先编译再启动或注册服务。没有源码时只使用现有二进制。
监听优先使用 0.0.0.0:18900。开发脚本或生产脚本拉起的实例会先停掉再接管该端口；其它进程占用时才改用相邻端口。临时换端口不会当成下次的默认地址。
已注册 systemd 后，start / stop / restart 走系统服务，不再用脚本托管进程。

可用环境变量（优先于上次保存的配置）：
  DAVBOX_BIN     二进制路径，默认 <脚本目录>/davbox
  DAVBOX_ADDR    监听地址，默认 0.0.0.0:18900
  DAVBOX_DATA    数据目录，默认 ./data
  AUTH_MODE      builtin 或 sso，默认 builtin
  DAVBOX_RUN_DIR 运行时目录（pid / 日志 / 配置），默认 <脚本目录>/.run/prod
  DAVBOX_SERVICE systemd 单元名（不含 .service），默认 davbox
EOF
}

ensure_run_dir() {
  mkdir -p "$RUN_DIR"
  chmod 700 "$RUN_DIR"
}

is_auto_bumped_addr() {
  local base="$1" got="$2"
  local bh="${base%:*}" bp="${base##*:}"
  local gh="${got%:*}" gp="${got##*:}"
  [[ "$bh" == "$gh" ]] || return 1
  [[ "$bp" =~ ^[0-9]+$ && "$gp" =~ ^[0-9]+$ ]] || return 1
  (( gp > bp && gp <= bp + 50 ))
}

load_conf() {
  LAST_LISTEN=""
  [[ -f "$CONF_FILE" ]] || return 0
  local k v loaded_addr=""
  while IFS='=' read -r k v; do
    [[ -z "${k:-}" || "$k" == \#* ]] && continue
    case "$k" in
      addr) loaded_addr="$v" ;;
      listen) LAST_LISTEN="$v" ;;
      data) DEFAULT_DATA="$v" ;;
      auth_mode) DEFAULT_AUTH="$v" ;;
      bin) DEFAULT_BIN="$v" ;;
    esac
  done < "$CONF_FILE"
  if [[ -n "$loaded_addr" ]]; then
    if [[ -z "$LAST_LISTEN" ]] && is_auto_bumped_addr "$FACTORY_ADDR" "$loaded_addr"; then
      LAST_LISTEN="$loaded_addr"
      DEFAULT_ADDR="$FACTORY_ADDR"
    else
      DEFAULT_ADDR="$loaded_addr"
    fi
  fi
}

save_conf() {
  ensure_run_dir
  cat > "$CONF_FILE" <<EOF
addr=$1
listen=$5
data=$2
auth_mode=$3
bin=$4
EOF
  chmod 600 "$CONF_FILE"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}

prompt_value() {
  local msg="$1" def="$2" val=""
  if is_tty; then
    read -r -p "$msg [$def]: " val || true
  fi
  val="$(trim "${val:-}")"
  printf '%s' "${val:-$def}"
}

confirm() {
  local msg="$1" def="${2:-Y}" ans=""
  if ! is_tty; then
    if [[ "$def" == [Yy] ]]; then
      return 0
    fi
    return 1
  fi
  read -r -p "$msg " ans || true
  ans="$(trim "${ans:-}")"
  if [[ -z "$ans" ]]; then
    ans="$def"
  fi
  if [[ "$ans" == [Yy] || "$ans" == [Yy][Ee][Ss] ]]; then
    return 0
  fi
  return 1
}

pid_alive() {
  local pid="${1:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

pid_is_davbox() {
  local pid="$1" cmd="" exe=""
  if [[ -r "/proc/$pid/cmdline" ]]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  else
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  fi
  if [[ "$cmd" == *davbox* ]]; then
    return 0
  fi
  if [[ -r "/proc/$pid/exe" ]]; then
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    if [[ "$exe" == *davbox* ]]; then
      return 0
    fi
  fi
  return 1
}

running_pid() {
  local pid=""
  [[ -f "$PID_FILE" ]] || return 1
  pid="$(trim "$(cat "$PID_FILE" 2>/dev/null || true)")"
  if pid_alive "$pid" && pid_is_davbox "$pid"; then
    printf '%s' "$pid"
    return 0
  fi
  rm -f "$PID_FILE"
  return 1
}

lan_ipv4s() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    return 0
  fi
  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' || true
  fi
}

print_access_lines() {
  local addr="$1"
  local host="${addr%:*}"
  local port="${addr##*:}"
  echo "  监听    $addr"
  if [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "[::]" ]]; then
    echo "  本机    http://127.0.0.1:${port}"
    echo "  管理页  http://127.0.0.1:${port}/admin"
    echo "  文件页  http://127.0.0.1:${port}/"
    local ip
    while read -r ip; do
      [[ -z "$ip" ]] && continue
      echo "  内网    http://${ip}:${port}"
      echo "  管理页  http://${ip}:${port}/admin"
      echo "  文件页  http://${ip}:${port}/"
    done < <(lan_ipv4s || true)
  else
    echo "  管理页  http://${host}:${port}/admin"
    echo "  文件页  http://${host}:${port}/"
  fi
}

connect_host() {
  local addr="$1" host
  host="${addr%:*}"
  if [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "[::]" ]]; then
    host="127.0.0.1"
  fi
  printf '%s' "$host"
}

port_of() {
  printf '%s' "${1##*:}"
}

port_busy() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}\$"; then
      return 0
    fi
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  return 1
}

listen_pids_from_proc() {
  local port="$1" hex ino pid fd tgt cmd
  hex="$(printf '%04X' "$port")"
  local inos=""
  local table local_addr st
  for table in /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$table" ]] || continue
    while read -r _ local_addr _ st _ _ _ _ ino _; do
      [[ "$st" == "0A" ]] || continue
      [[ "${local_addr##*:}" == "$hex" ]] || continue
      inos+="${ino} "
    done < <(tail -n +2 "$table" 2>/dev/null || true)
  done
  [[ -n "$inos" ]] || return 0
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
    [[ "$cmd" == *davbox* ]] || continue
    for fd in /proc/${pid}/fd/*; do
      tgt="$(readlink "$fd" 2>/dev/null || true)"
      for ino in $inos; do
        if [[ "$tgt" == "socket:[${ino}]" ]]; then
          printf '%s\n' "$pid"
          break 2
        fi
      done
    done
  done
}

listen_pids() {
  local port="$1" out=""
  if command -v lsof >/dev/null 2>&1; then
    out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  fi
  if [[ -z "$(trim "${out:-}")" ]] && command -v fuser >/dev/null 2>&1; then
    out="$(fuser "${port}/tcp" 2>/dev/null || true)"
  fi
  if [[ -z "$(trim "${out:-}")" ]] && command -v ss >/dev/null 2>&1; then
    out="$(ss -ltnp 2>/dev/null | awk -v port="$port" '
      {
        n = split($4, a, ":")
        lp = a[n]
        gsub(/\]/, "", lp)
        if (lp == port) {
          s = $0
          while (match(s, /pid=[0-9]+/)) {
            print substr(s, RSTART + 4, RLENGTH - 4)
            s = substr(s, RSTART + RLENGTH)
          }
        }
      }')"
  fi
  if [[ -z "$(trim "${out:-}")" ]]; then
    out="$(listen_pids_from_proc "$port" || true)"
  fi
  if [[ -n "$(trim "${out:-}")" ]]; then
    # shellcheck disable=SC2086
    printf '%s\n' $out | sort -u
  fi
}

pidfile_pid() {
  local file="$1" pid=""
  [[ -f "$file" ]] || return 1
  pid="$(trim "$(cat "$file" 2>/dev/null || true)")"
  if pid_alive "$pid" && pid_is_davbox "$pid"; then
    printf '%s' "$pid"
    return 0
  fi
  return 1
}

dev_running_pid() {
  pidfile_pid "$DEV_PID_FILE"
}

script_running_pid() {
  pidfile_pid "$PID_FILE"
}

conf_port() {
  local file="$1" daddr
  [[ -f "$file" ]] || return 1
  daddr="$(awk -F= '/^addr=/{print $2; exit}' "$file")"
  [[ -n "$daddr" ]] || return 1
  port_of "$daddr"
}

dev_saved_port() {
  conf_port "$DEV_CONF_FILE"
}

prod_saved_port() {
  conf_port "$CONF_FILE"
}

systemd_main_pid() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local p
  p="$(systemctl show -p MainPID --value "$(service_unit_name)" 2>/dev/null || true)"
  if [[ -n "$p" && "$p" != "0" ]] && pid_alive "$p"; then
    printf '%s' "$p"
    return 0
  fi
  return 1
}

pid_is_our_binary() {
  local pid="$1" exe="" cmd="" want
  want="$(readlink -f "$ROOT/davbox" 2>/dev/null || printf '%s' "$ROOT/davbox")"
  if [[ -r "/proc/${pid}/exe" ]]; then
    exe="$(readlink "/proc/${pid}/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"
    exe="$(readlink -f "$exe" 2>/dev/null || printf '%s' "$exe")"
    if [[ "$exe" == "$want" ]]; then
      return 0
    fi
  fi
  cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  if [[ "$cmd" == *"$ROOT/davbox"* ]]; then
    return 0
  fi
  return 1
}

stop_pid_wait() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 80); do
    if ! pid_alive "$pid"; then
      return 0
    fi
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  sleep 0.2
  if pid_alive "$pid"; then
    return 1
  fi
  return 0
}

forget_pidfiles() {
  local pid="$1" f cur
  for f in "$PID_FILE" "$DEV_PID_FILE"; do
    [[ -f "$f" ]] || continue
    cur="$(trim "$(cat "$f" 2>/dev/null || true)")"
    if [[ "$cur" == "$pid" ]]; then
      rm -f "$f"
    fi
  done
}

stop_dev_instance() {
  local pid=""
  if ! pid="$(dev_running_pid)"; then
    return 0
  fi
  echo "正在停止开发实例 PID $pid"
  if ! stop_pid_wait "$pid"; then
    echo "停止开发实例失败，进程仍在运行：$pid" >&2
    exit 1
  fi
  rm -f "$DEV_PID_FILE"
  echo "开发实例已停止"
}

stop_script_instance() {
  local pid=""
  if ! pid="$(script_running_pid)"; then
    return 0
  fi
  echo "正在停止脚本托管的生产实例 PID $pid"
  if ! stop_pid_wait "$pid"; then
    echo "停止脚本托管实例失败，进程仍在运行：$pid" >&2
    exit 1
  fi
  rm -f "$PID_FILE"
  echo "脚本托管实例已停止"
}

cmdline_listen_addr() {
  local pid="$1" tok next=0
  local cmd
  cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  for tok in $cmd; do
    if [[ "$next" -eq 1 ]]; then
      printf '%s' "$tok"
      return 0
    fi
    if [[ "$tok" == "-addr" ]]; then
      next=1
    fi
  done
  return 1
}

status_listen_addr() {
  local pid="" a=""
  if pid="$(systemd_main_pid)"; then
    a="$(cmdline_listen_addr "$pid" || true)"
    if [[ -n "$a" ]]; then
      printf '%s' "$a"
      return 0
    fi
  fi
  if pid="$(running_pid)"; then
    a="$(cmdline_listen_addr "$pid" || true)"
    if [[ -n "$a" ]]; then
      printf '%s' "$a"
      return 0
    fi
  fi
  if [[ -n "${LAST_LISTEN:-}" ]]; then
    printf '%s' "$LAST_LISTEN"
    return 0
  fi
  printf '%s' "$DEFAULT_ADDR"
}

stop_all_ours_except_systemd() {
  local spid="" pid
  spid="$(systemd_main_pid || true)"
  if dev_running_pid >/dev/null; then
    echo "停止开发脚本启动的实例。"
    stop_dev_instance
  fi
  if script_running_pid >/dev/null; then
    echo "停止生产脚本启动的实例。"
    stop_script_instance
  fi
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if [[ -n "$spid" && "$pid" == "$spid" ]]; then
      continue
    fi
    if pid_is_our_binary "$pid"; then
      echo "停止本仓库 davbox PID $pid"
      if ! stop_pid_wait "$pid"; then
        echo "停止失败，进程仍在运行：$pid" >&2
        exit 1
      fi
      forget_pidfiles "$pid"
    fi
  done
}

wait_port_free() {
  local port="$1" i
  for i in $(seq 1 50); do
    if ! port_busy "$port"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

next_free_port() {
  local start="$1" p
  for p in $(seq $((start + 1)) $((start + 50))); do
    if (( p > 65535 )); then
      break
    fi
    if ! port_busy "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

port_held_by_systemd() {
  local port="$1" spid="" occ=""
  if ! spid="$(systemd_main_pid)"; then
    return 1
  fi
  local saw=0
  while read -r occ; do
    [[ -z "$occ" ]] && continue
    saw=1
    if [[ "$occ" == "$spid" ]]; then
      return 0
    fi
  done < <(listen_pids "$port")
  if [[ "$saw" -eq 0 ]]; then
    local uaddr
    uaddr="$(systemctl show -p ExecStart --value "$(service_unit_name)" 2>/dev/null || true)"
    if [[ "$uaddr" == *":${port}"* || "$uaddr" == *":${port} "* ]]; then
      return 0
    fi
  fi
  return 1
}

# 停掉占用该端口的开发实例、脚本托管实例，以及 pid 文件丢失的本仓库 davbox。
# systemd 拉起的同名服务不在这里杀，交给 systemctl restart。
stop_ours_on_port() {
  local port="$1"
  local spid="" dpid="" ppid="" occ=""
  spid="$(systemd_main_pid || true)"
  dpid="$(dev_running_pid || true)"
  ppid="$(script_running_pid || true)"

  local saw=0
  while read -r occ; do
    [[ -z "$occ" ]] && continue
    saw=1
    if [[ -n "$spid" && "$occ" == "$spid" ]]; then
      continue
    fi
    if [[ -n "$dpid" && "$occ" == "$dpid" ]]; then
      echo "端口 $port 由开发脚本启动的实例占用（PID $dpid），正在停止后接管。"
      stop_dev_instance
      dpid=""
      continue
    fi
    if [[ -n "$ppid" && "$occ" == "$ppid" ]]; then
      echo "端口 $port 由生产脚本启动的实例占用（PID $ppid），正在停止后接管。"
      stop_script_instance
      ppid=""
      continue
    fi
    if pid_is_our_binary "$occ"; then
      echo "端口 $port 由本仓库 davbox（PID $occ）占用，正在停止后接管。"
      if ! stop_pid_wait "$occ"; then
        echo "停止失败，进程仍在运行：$occ" >&2
        exit 1
      fi
      forget_pidfiles "$occ"
    fi
  done < <(listen_pids "$port")

  if [[ "$saw" -eq 0 ]]; then
    local dport="" pport=""
    dport="$(dev_saved_port || true)"
    pport="$(prod_saved_port || true)"
    if [[ -n "$dpid" && "$dport" == "$port" ]]; then
      echo "端口 $port 与开发脚本记录一致（PID $dpid），正在停止后接管。"
      stop_dev_instance
    fi
    if [[ -n "$ppid" && "$pport" == "$port" ]]; then
      echo "端口 $port 与生产脚本记录一致（PID $ppid），正在停止后接管。"
      stop_script_instance
    fi
  fi
}

# 就地改写传入的地址变量（nameref），避免 $(...) 吃掉提示或吞掉 exit。
# 直接启动与注册 systemd 共用：先停本仓库全部开发/脚本实例，再抢回目标端口；
# 只有外来进程占用时才改相邻端口。
resolve_listen_addr() {
  local -n _addr_ref=$1
  local host="${_addr_ref%:*}"
  local port
  port="$(port_of "$_addr_ref")"
  stop_all_ours_except_systemd
  stop_ours_on_port "$port"
  wait_port_free "$port" || true
  if ! port_busy "$port"; then
    return 0
  fi
  if port_held_by_systemd "$port"; then
    return 0
  fi
  local np=""
  if ! np="$(next_free_port "$port")"; then
    echo "端口 $port 被其它进程占用，且没有相邻空闲端口。" >&2
    exit 1
  fi
  echo "端口 $port 被其它进程占用，改用相邻端口 $np。"
  _addr_ref="${host}:${np}"
}

tcp_ready() {
  local addr="$1" host port
  host="$(connect_host "$addr")"
  port="$(port_of "$addr")"
  if command -v timeout >/dev/null 2>&1; then
    timeout 0.3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    return 1
  fi
  bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
  return 1
}

normalize_auth() {
  local m
  m="$(trim "$1")"
  m="${m,,}"
  case "$m" in
    ""|builtin) printf 'builtin' ;;
    sso) printf 'sso' ;;
    *)
      echo "AUTH_MODE 只支持 builtin 或 sso，收到：$1" >&2
      exit 1
      ;;
  esac
}

is_loopback_addr() {
  local host="${1%:*}"
  case "$host" in
    127.0.0.1|localhost|::1|[::1]|127.*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_addr() {
  local addr="$1"
  if [[ ! "$addr" =~ :[0-9]+$ ]]; then
    echo "监听地址需要 host:port 形式，例如 0.0.0.0:18900" >&2
    exit 1
  fi
  local port
  port="$(port_of "$addr")"
  if (( port < 1 || port > 65535 )); then
    echo "端口不合法：$port" >&2
    exit 1
  fi
}

validate_data() {
  if [[ -z "$1" ]]; then
    echo "数据目录不能为空" >&2
    exit 1
  fi
}

require_binary() {
  local bin="$1"
  if [[ ! -e "$bin" ]]; then
    echo "未找到二进制：$bin" >&2
    echo "请先在源码目录执行 make build，或把 davbox 放到本脚本同目录。" >&2
    exit 1
  fi
  if [[ ! -f "$bin" ]]; then
    echo "不是普通文件：$bin" >&2
    exit 1
  fi
  if [[ ! -x "$bin" ]]; then
    echo "二进制不可执行：$bin" >&2
    exit 1
  fi
}

apply_env() {
  if [[ -n "${DAVBOX_ADDR:-}" ]]; then
    DEFAULT_ADDR="$DAVBOX_ADDR"
  fi
  if [[ -n "${DAVBOX_DATA:-}" ]]; then
    DEFAULT_DATA="$DAVBOX_DATA"
  fi
  if [[ -n "${AUTH_MODE:-}" ]]; then
    DEFAULT_AUTH="$AUTH_MODE"
  fi
  if [[ -n "${DAVBOX_BIN:-}" ]]; then
    DEFAULT_BIN="$DAVBOX_BIN"
  fi
}

abs_path() {
  local p="$1"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s' "$ROOT/${p#./}" ;;
  esac
}

service_unit_name() {
  printf '%s.service' "$SERVICE_NAME"
}

service_unit_path() {
  printf '/etc/systemd/system/%s' "$(service_unit_name)"
}

need_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "未找到 systemctl，当前系统没有 systemd。" >&2
    exit 1
  fi
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "注册系统服务需要 root 权限（未找到 sudo）。" >&2
    exit 1
  fi
}

service_user() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "$SUDO_USER"
    return 0
  fi
  id -un
}

service_group() {
  local u
  u="$(service_user)"
  id -gn "$u" 2>/dev/null || id -gn
}

systemd_is_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$(service_unit_name)" 2>/dev/null
}

systemd_is_enabled() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet "$(service_unit_name)" 2>/dev/null
}

systemd_unit_installed() {
  [[ -f "$(service_unit_path)" ]]
}

write_service_unit() {
  local dest="$1" bin_abs data_abs addr auth user group
  bin_abs="$(abs_path "$DEFAULT_BIN")"
  data_abs="$(abs_path "$DEFAULT_DATA")"
  addr="$DEFAULT_ADDR"
  auth="$DEFAULT_AUTH"
  user="$(service_user)"
  group="$(service_group)"
  cat >"$dest" <<EOF
[Unit]
Description=davbox WebDAV
After=network.target

[Service]
Type=simple
User=$user
Group=$group
WorkingDirectory=$ROOT
ExecStart=$bin_abs -addr $addr -data $data_abs
Environment=AUTH_MODE=$auth
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
UMask=0077
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF
}

print_status() {
  local pid="" boot="未开启"
  if systemd_is_enabled; then
    boot="已开启"
  fi
  if systemd_is_active; then
    echo "davbox 由 systemd 运行"
    echo "  单元    $(service_unit_name)"
    echo "  开机自启  $boot"
    echo "  二进制  $DEFAULT_BIN"
    print_access_lines "$(status_listen_addr)"
    echo "  数据    $DEFAULT_DATA"
    echo "  认证    $DEFAULT_AUTH"
    echo "  日志    journalctl -u $(service_unit_name)"
    return 0
  fi
  if pid="$(running_pid)"; then
    echo "davbox 生产实例正在运行（脚本托管）"
    echo "  PID     $pid"
    echo "  二进制  $DEFAULT_BIN"
    print_access_lines "$(status_listen_addr)"
    echo "  数据    $DEFAULT_DATA"
    echo "  认证    $DEFAULT_AUTH"
    echo "  日志    $LOG_FILE"
    echo "  开机自启  $boot"
  else
    echo "davbox 生产实例未运行"
    if systemd_unit_installed; then
      echo "  单元    $(service_unit_name) 已安装，开机自启：$boot"
    fi
  fi
}

do_stop() {
  if systemd_is_active; then
    echo "正在通过 systemd 停止 $(service_unit_name)"
    run_root systemctl stop "$(service_unit_name)"
    rm -f "$PID_FILE"
    echo "已停止"
    return 0
  fi
  local pid=""
  if ! pid="$(running_pid)"; then
    echo "davbox 生产实例未运行"
    return 0
  fi
  echo "正在停止 PID $pid"
  kill "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 80); do
    if ! pid_alive "$pid"; then
      break
    fi
    sleep 0.1
  done
  if pid_alive "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.2
  fi
  rm -f "$PID_FILE"
  if pid_alive "$pid"; then
    echo "停止失败，进程仍在运行：$pid" >&2
    exit 1
  fi
  echo "已停止"
}

show_log() {
  if systemd_is_active || systemd_unit_installed; then
    if command -v journalctl >/dev/null 2>&1; then
      journalctl -u "$(service_unit_name)" -n 80 --no-pager || true
      return 0
    fi
  fi
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "还没有日志"
    return 0
  fi
  tail -n 80 "$LOG_FILE"
}

extract_admin_pass() {
  [[ -f "$LOG_FILE" ]] || return 0
  sed -n 's/.*管理员初始口令（仅本次打印，请自行保存）：//p' "$LOG_FILE" | tail -n 1
}

wait_ready() {
  local pid="$1" addr="$2" i
  for i in $(seq 1 150); do
    if ! pid_alive "$pid"; then
      return 1
    fi
    if grep -q 'davbox 已启动' "$LOG_FILE" 2>/dev/null; then
      if tcp_ready "$addr"; then
        return 0
      fi
    fi
    if tcp_ready "$addr"; then
      return 0
    fi
    sleep 0.1
  done
  if pid_alive "$pid"; then
    return 0
  fi
  return 1
}

acquire_lock() {
  ensure_run_dir
  exec 9>"$LOCK_FILE"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
      echo "另一个启动脚本正在运行" >&2
      exit 1
    fi
  fi
}

do_start() {
  load_conf
  apply_env

  if systemd_is_active; then
    print_status
    if ! is_tty || [[ "${SKIP_PROMPTS:-0}" == "1" ]]; then
      return 0
    fi
    echo
    echo "  [1] 保持运行并退出"
    echo "  [2] 停止"
    echo "  [3] 重新启动"
    echo "  [4] 关闭开机自启"
    echo "  [5] 取消系统服务"
    local choice=""
    read -r -p "选择 [1]: " choice || true
    choice="$(trim "${choice:-1}")"
    case "$choice" in
      2)
        do_stop
        return 0
        ;;
      3)
        BIN="$ROOT/davbox"
        DEFAULT_BIN="$BIN"
        ensure_binary
        echo "正在通过 systemd 重启 $(service_unit_name)"
        run_root systemctl restart "$(service_unit_name)"
        print_status
        return 0
        ;;
      4)
        run_root systemctl disable "$(service_unit_name)"
        echo "已关闭开机自启，服务仍在运行。"
        return 0
        ;;
      5)
        service_uninstall
        return 0
        ;;
      *)
        echo "当前终端已空闲，服务由 systemd 继续运行。"
        return 0
        ;;
    esac
  fi

  if systemd_is_enabled; then
    BIN="$ROOT/davbox"
    DEFAULT_BIN="$BIN"
    ensure_binary
    echo "已注册 systemd 开机自启，通过系统服务启动。"
    if [[ "${BINARY_REBUILT:-0}" == "1" ]]; then
      run_root systemctl restart "$(service_unit_name)"
    else
      run_root systemctl start "$(service_unit_name)"
    fi
    print_status
    return 0
  fi

  local pid=""
  if pid="$(running_pid)"; then
    print_status
    if ! is_tty || [[ "${SKIP_PROMPTS:-0}" == "1" ]]; then
      return 0
    fi
    echo
    echo "  [1] 保持运行并退出"
    echo "  [2] 停止"
    echo "  [3] 重新启动"
    if command -v systemctl >/dev/null 2>&1; then
      echo "  [4] 注册为系统服务并开机自启"
    fi
    local choice=""
    read -r -p "选择 [1]: " choice || true
    choice="$(trim "${choice:-1}")"
    case "$choice" in
      2)
        do_stop
        return 0
        ;;
      3)
        do_stop
        ;;
      4)
        if ! command -v systemctl >/dev/null 2>&1; then
          echo "未找到 systemctl。" >&2
          return 0
        fi
        SERVICE_FROM_MENU=1
        service_install
        return 0
        ;;
      *)
        echo "当前终端已空闲，服务继续在后台运行。"
        return 0
        ;;
    esac
  fi

  acquire_lock
  if pid="$(running_pid)"; then
    print_status
    echo "当前终端已空闲，服务继续在后台运行。"
    return 0
  fi

  local addr="$DEFAULT_ADDR"
  local data="$DEFAULT_DATA"
  local auth="$DEFAULT_AUTH"
  local bin="$DEFAULT_BIN"

  echo "生产环境：后台启动已编译的 davbox。"
  echo
  echo "  二进制      $bin"
  echo "  监听地址    $addr"
  echo "  数据目录    $data"
  echo "  管理端认证  $auth"
  echo

  local edit="n"
  if is_tty && [[ "${SKIP_PROMPTS:-0}" != "1" ]]; then
    local ans=""
    read -r -p "按回车使用以上配置，输入 n 修改配置: " ans || true
    ans="$(trim "${ans:-}")"
    if [[ "$ans" == [Nn] ]]; then
      edit="y"
    fi
  fi

  if [[ "$edit" == "y" ]]; then
    bin="$(prompt_value "二进制路径" "$bin")"
    addr="$(prompt_value "监听地址" "$addr")"
    data="$(prompt_value "数据目录" "$data")"
    auth="$(prompt_value "管理端认证（builtin / sso）" "$auth")"
  fi

  local start_mode="1"
  if is_tty && [[ "${SKIP_PROMPTS:-0}" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
    echo "  [1] 后台启动（本次有效）"
    echo "  [2] 注册为系统服务并开机自启"
    read -r -p "选择 [1]: " start_mode || true
    start_mode="$(trim "${start_mode:-1}")"
  fi

  bin="$(trim "$bin")"
  addr="$(trim "$addr")"
  data="$(trim "$data")"
  auth="$(normalize_auth "$auth")"
  validate_addr "$addr"
  validate_data "$data"
  BIN="$ROOT/davbox"
  bin="$BIN"
  DEFAULT_BIN="$BIN"
  ensure_binary

  if [[ "$auth" == "sso" ]] && ! is_loopback_addr "$addr"; then
    echo "AUTH_MODE=sso 只应在回环 + 网关注入 X-Auth-User 并剥离该头时使用。" >&2
    exit 1
  fi

  mkdir -p "$data"

  if [[ "$start_mode" == "2" ]]; then
    DEFAULT_ADDR="$addr"
    DEFAULT_DATA="$data"
    DEFAULT_AUTH="$auth"
    DEFAULT_BIN="$bin"
    SERVICE_FROM_MENU=1
    service_install
    return 0
  fi

  local requested="$addr"
  resolve_listen_addr addr
  validate_addr "$addr"
  save_conf "$requested" "$data" "$auth" "$bin" "$addr"

  local first_admin=0
  if [[ "$auth" == "builtin" && ! -f "$data/admin.json" ]]; then
    first_admin=1
  fi

  ensure_run_dir
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  {
    echo
    echo "-------- $(date '+%Y-%m-%d %H:%M:%S') 生产启动 --------"
    echo "bin=$bin addr=$addr data=$data AUTH_MODE=$auth"
  } >> "$LOG_FILE"

  echo "正在后台启动…"
  # 9>&-：不要把启动锁传给后台进程，否则再次运行本脚本会被 flock 挡住。
  nohup env AUTH_MODE="$auth" "$bin" -addr "$addr" -data "$data" >>"$LOG_FILE" 2>&1 </dev/null 9>&- &
  pid=$!
  echo "$pid" > "$PID_FILE"
  chmod 600 "$PID_FILE"
  disown "$pid" 2>/dev/null || true

  if ! wait_ready "$pid" "$addr"; then
    echo "启动失败，最近日志：" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE"
    exit 1
  fi

  echo
  echo "生产实例已在后台运行，当前终端可以继续使用。"
  echo
  echo "  PID     $pid"
  echo "  二进制  $bin"
  print_access_lines "$addr"
  echo "  数据    $data"
  echo "  认证    $auth"
  echo "  日志    $LOG_FILE"
  echo "  停止    $ROOT/start-prod.sh stop"
  echo "  开机自启  $ROOT/start-prod.sh service install"
  echo

  if [[ "$first_admin" -eq 1 ]]; then
    local pass=""
    pass="$(extract_admin_pass || true)"
    if [[ -n "$pass" ]]; then
      echo "  管理员初始口令（请立刻保存）：$pass"
      echo "  明文也写在 $data/admin-password.txt"
      echo
    fi
  fi
}

service_install() {
  need_systemd
  if [[ "${SERVICE_FROM_MENU:-0}" != "1" ]]; then
    load_conf
    apply_env
  fi
  BIN="$ROOT/davbox"
  DEFAULT_BIN="$BIN"
  ensure_binary
  validate_addr "$DEFAULT_ADDR"
  validate_data "$DEFAULT_DATA"
  if [[ "$DEFAULT_AUTH" == "sso" ]] && ! is_loopback_addr "$DEFAULT_ADDR"; then
    echo "AUTH_MODE=sso 只应在回环 + 网关注入 X-Auth-User 并剥离该头时使用。" >&2
    exit 1
  fi
  mkdir -p "$(abs_path "$DEFAULT_DATA")"
  local requested="$DEFAULT_ADDR"
  echo "注册系统服务：先停止本仓库已有实例，再监听 $requested"
  resolve_listen_addr DEFAULT_ADDR
  validate_addr "$DEFAULT_ADDR"
  save_conf "$requested" "$DEFAULT_DATA" "$DEFAULT_AUTH" "$DEFAULT_BIN" "$DEFAULT_ADDR"

  local tmp
  tmp="$(mktemp)"
  write_service_unit "$tmp"
  echo "将写入 $(service_unit_path) 并设置开机自启。"
  echo
  echo "  用户      $(service_user)"
  echo "  二进制    $(abs_path "$DEFAULT_BIN")"
  echo "  监听      $DEFAULT_ADDR"
  echo "  数据      $(abs_path "$DEFAULT_DATA")"
  echo "  认证      $DEFAULT_AUTH"
  echo
  if is_tty && [[ "${SKIP_PROMPTS:-0}" != "1" && "${SERVICE_FROM_MENU:-0}" != "1" ]]; then
    if ! confirm "写入 systemd 并开机自启？ [Y/n]" "Y"; then
      rm -f "$tmp"
      echo "已取消"
      return 0
    fi
  fi

  run_root install -m 644 "$tmp" "$(service_unit_path)"
  rm -f "$tmp"
  run_root systemctl daemon-reload
  run_root systemctl enable "$(service_unit_name)"
  echo "已注册 $(service_unit_name)，开机自启已打开。"

  if is_tty && [[ "${SKIP_PROMPTS:-0}" != "1" ]]; then
    if ! confirm "现在启动服务？ [Y/n]" "Y"; then
      echo "未启动。之后可执行：$ROOT/start-prod.sh service start"
      return 0
    fi
  fi
  if systemd_is_active; then
    run_root systemctl restart "$(service_unit_name)"
  else
    run_root systemctl start "$(service_unit_name)"
  fi
  print_status
}

service_uninstall() {
  need_systemd
  if is_tty && [[ "${SKIP_PROMPTS:-0}" != "1" ]]; then
    if ! confirm "取消开机自启并移除 $(service_unit_name)？ [y/N]" "N"; then
      echo "已取消"
      return 0
    fi
  fi
  if systemd_is_active; then
    run_root systemctl stop "$(service_unit_name)"
  fi
  if systemd_is_enabled || systemd_unit_installed; then
    run_root systemctl disable "$(service_unit_name)" 2>/dev/null || true
  fi
  if systemd_unit_installed; then
    run_root rm -f "$(service_unit_path)"
  fi
  run_root systemctl daemon-reload
  echo "已移除系统服务 $(service_unit_name)"
}

service_cmd() {
  local sub="${1:-}"
  case "$sub" in
    install)
      service_install
      ;;
    uninstall)
      service_uninstall
      ;;
    status)
      load_conf
      apply_env
      need_systemd
      print_status
      if command -v systemctl >/dev/null 2>&1; then
        echo
        systemctl --no-pager --full status "$(service_unit_name)" || true
      fi
      ;;
    start)
      load_conf
      apply_env
      need_systemd
      BIN="$ROOT/davbox"
      DEFAULT_BIN="$BIN"
      ensure_binary
      if [[ "${BINARY_REBUILT:-0}" == "1" ]]; then
        run_root systemctl restart "$(service_unit_name)"
      else
        run_root systemctl start "$(service_unit_name)"
      fi
      print_status
      ;;
    stop)
      load_conf
      apply_env
      need_systemd
      run_root systemctl stop "$(service_unit_name)"
      echo "已停止 $(service_unit_name)"
      ;;
    restart)
      load_conf
      apply_env
      need_systemd
      BIN="$ROOT/davbox"
      DEFAULT_BIN="$BIN"
      ensure_binary
      run_root systemctl restart "$(service_unit_name)"
      print_status
      ;;
    enable)
      need_systemd
      run_root systemctl enable "$(service_unit_name)"
      echo "已打开开机自启"
      ;;
    disable)
      need_systemd
      run_root systemctl disable "$(service_unit_name)"
      echo "已关闭开机自启"
      ;;
    ""|help|-h|--help)
      usage
      ;;
    *)
      echo "未知 service 命令：$sub" >&2
      usage >&2
      exit 1
      ;;
  esac
}

cmd="${1:-start}"
case "$cmd" in
  start)
    do_start
    ;;
  stop)
    load_conf
    apply_env
    do_stop
    ;;
  restart)
    SKIP_PROMPTS=1
    load_conf
    apply_env
    do_stop
    do_start
    ;;
  status)
    load_conf
    apply_env
    print_status
    ;;
  log)
    show_log
    ;;
  service)
    shift || true
    service_cmd "${1:-}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "未知命令：$cmd" >&2
    usage >&2
    exit 1
    ;;
esac
