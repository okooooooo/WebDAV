#!/usr/bin/env bash
# 开发环境：可按需从源码重新编译，然后后台启动，不占用当前终端。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# shellcheck source=start-lib.sh
. "$ROOT/start-lib.sh"
setup_build_path

RUN_DIR="$ROOT/.run/dev"
PID_FILE="$RUN_DIR/davbox.pid"
LOG_FILE="$RUN_DIR/davbox.log"
CONF_FILE="$RUN_DIR/start.conf"
LOCK_FILE="$RUN_DIR/start.lock"
BIN="$ROOT/davbox"
STAMP_FILE="$ROOT/.run/binary.stamp"

DEFAULT_ADDR="0.0.0.0:18900"
DEFAULT_DATA="./data"
DEFAULT_AUTH="builtin"

usage() {
  cat <<'EOF'
用法（开发环境）：
  ./start-dev.sh           交互式后台启动；二进制与源码一致则直接启动，否则先编译
  ./start-dev.sh start     同上
  ./start-dev.sh stop      停止
  ./start-dev.sh restart   停止后按上次配置再启动
  ./start-dev.sh status    查看状态
  ./start-dev.sh log       打印最近日志
  ./start-dev.sh help      显示本说明

生产环境请用 ./start-prod.sh（只启动已编译的二进制，不调用 go / npm）。
EOF
}

ensure_run_dir() {
  mkdir -p "$RUN_DIR"
  chmod 700 "$RUN_DIR"
}

load_conf() {
  [[ -f "$CONF_FILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    [[ -z "${k:-}" || "$k" == \#* ]] && continue
    case "$k" in
      addr) DEFAULT_ADDR="$v" ;;
      data) DEFAULT_DATA="$v" ;;
      auth_mode) DEFAULT_AUTH="$v" ;;
    esac
  done < "$CONF_FILE"
}

save_conf() {
  ensure_run_dir
  umask 077
  cat > "$CONF_FILE" <<EOF
addr=$1
data=$2
auth_mode=$3
EOF
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
  local pid="$1" cmd=""
  if [[ -r "/proc/$pid/cmdline" ]]; then
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  else
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  fi
  if [[ "$cmd" == *davbox* ]]; then
    return 0
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

print_status() {
  local pid=""
  if pid="$(running_pid)"; then
    echo "davbox 开发实例正在运行"
    echo "  PID     $pid"
    print_access_lines "$DEFAULT_ADDR"
    echo "  数据    $DEFAULT_DATA"
    echo "  认证    $DEFAULT_AUTH"
    echo "  日志    $LOG_FILE"
  else
    echo "davbox 开发实例未运行"
  fi
}

do_stop() {
  local pid=""
  if ! pid="$(running_pid)"; then
    echo "davbox 开发实例未运行"
    return 0
  fi
  echo "正在停止 PID $pid"
  kill "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
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
  local pid="$1" i
  for i in $(seq 1 150); do
    if ! pid_alive "$pid"; then
      return 1
    fi
    if grep -q 'davbox 已启动' "$LOG_FILE" 2>/dev/null; then
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

  echo "开发环境：将在后台启动 davbox。直接回车使用下列配置。"
  echo
  echo "  监听地址    $addr"
  echo "  数据目录    $data"
  echo "  管理端认证  $auth"
  echo

  local edit="n"
  if is_tty && [[ "${SKIP_PROMPTS:-0}" != "1" ]]; then
    local ans=""
    read -r -p "按回车启动，输入 n 修改配置: " ans || true
    ans="$(trim "${ans:-}")"
    if [[ "$ans" == [Nn] ]]; then
      edit="y"
    fi
  fi

  if [[ "$edit" == "y" ]]; then
    addr="$(prompt_value "监听地址" "$addr")"
    data="$(prompt_value "数据目录" "$data")"
    auth="$(prompt_value "管理端认证（builtin / sso）" "$auth")"
  fi

  addr="$(trim "$addr")"
  data="$(trim "$data")"
  auth="$(normalize_auth "$auth")"
  validate_addr "$addr"
  validate_data "$data"

  local port
  port="$(port_of "$addr")"
  if port_busy "$port"; then
    echo "端口 $port 已被占用，请换一个监听地址。" >&2
    exit 1
  fi

  ensure_binary
  save_conf "$addr" "$data" "$auth"
  mkdir -p "$data"

  local first_admin=0
  if [[ "$auth" == "builtin" && ! -f "$data/admin.json" ]]; then
    first_admin=1
  fi

  ensure_run_dir
  umask 077
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  {
    echo
    echo "-------- $(date '+%Y-%m-%d %H:%M:%S') 开发启动 --------"
    echo "addr=$addr data=$data AUTH_MODE=$auth"
  } >> "$LOG_FILE"

  echo "正在后台启动…"
  # 9>&-：不要把启动锁传给后台进程，否则再次运行本脚本会被 flock 挡住。
  nohup env AUTH_MODE="$auth" "$BIN" -addr "$addr" -data "$data" >>"$LOG_FILE" 2>&1 </dev/null 9>&- &
  pid=$!
  echo "$pid" > "$PID_FILE"
  chmod 600 "$PID_FILE"
  disown "$pid" 2>/dev/null || true

  if ! wait_ready "$pid"; then
    echo "启动失败，最近日志：" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE"
    exit 1
  fi

  echo
  echo "开发实例已在后台运行，当前终端可以继续使用。"
  echo
  echo "  PID     $pid"
  print_access_lines "$addr"
  echo "  数据    $data"
  echo "  认证    $auth"
  echo "  日志    $LOG_FILE"
  echo "  停止    $ROOT/start-dev.sh stop"
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

cmd="${1:-start}"
case "$cmd" in
  start)
    do_start
    ;;
  stop)
    do_stop
    ;;
  restart)
    SKIP_PROMPTS=1
    do_stop
    do_start
    ;;
  status)
    load_conf
    print_status
    ;;
  log)
    show_log
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
