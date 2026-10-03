#!/usr/bin/env bash
# 由 start-dev.sh / start-prod.sh source：二进制与源码指纹、按需编译。
# 依赖调用方已设置 ROOT；可选 BIN、STAMP_FILE。

BIN="${BIN:-$ROOT/davbox}"
STAMP_FILE="${STAMP_FILE:-$ROOT/.run/binary.stamp}"
BINARY_REBUILT=0

setup_build_path() {
  export PATH="${HOME}/.local/go/bin:/usr/local/go/bin:${HOME}/go/bin:${HOME}/sdk/go/bin:${PATH}"
  if [[ -d "${HOME}/.nvm/versions/node" ]]; then
    local nvm_latest
    nvm_latest="$(ls -d "${HOME}/.nvm/versions/node"/v* 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -n "${nvm_latest:-}" && -d "${nvm_latest}/bin" ]]; then
      export PATH="${nvm_latest}/bin:${PATH}"
    fi
  fi
}

source_tree_present() {
  [[ -f "$ROOT/go.mod" && -d "$ROOT/cmd" ]]
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "未找到命令：$1" >&2
    exit 1
  fi
}

go_mod_version() {
  awk '/^go / { print $2; exit }' "$ROOT/go.mod" 2>/dev/null || printf '1.26'
}

find_go() {
  if command -v go >/dev/null 2>&1; then
    return 0
  fi
  local c
  for c in \
    "${HOME}/.local/go/bin/go" \
    /usr/local/go/bin/go \
    "${HOME}/go/bin/go" \
    "${HOME}/sdk/go/bin/go"
  do
    if [[ -x "$c" ]]; then
      export PATH="$(dirname "$c"):${PATH}"
      return 0
    fi
  done
  return 1
}

install_go() {
  local dest="${HOME}/.local/go"
  local ver="go1.26.8"
  local os arch tarball url tmp
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)
      echo "无法自动安装 Go：未知架构 $(uname -m)" >&2
      return 1
      ;;
  esac
  mkdir -p "${HOME}/.local"
  echo "正在安装 ${ver} 到 ${dest}"
  tmp="$(mktemp -d)"
  tarball="${ver}.${os}-${arch}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  if ! curl -fL --progress-bar -o "${tmp}/${tarball}" "$url"; then
    echo "下载失败：$url" >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$dest"
  tar -C "${HOME}/.local" -xzf "${tmp}/${tarball}"
  rm -rf "$tmp"
  export PATH="${dest}/bin:${PATH}"
}

ensure_go() {
  if find_go; then
    return 0
  fi
  echo "未找到 go（go.mod 需要 $(go_mod_version)+）。"
  if declare -F is_tty >/dev/null && declare -F confirm >/dev/null && is_tty && [[ "${SKIP_PROMPTS:-0}" != "1" ]]; then
    if confirm "下载 Go 到 ${HOME}/.local/go ？ [Y/n]" "Y"; then
      install_go
      if find_go; then
        echo "已安装 $(go version)"
        return 0
      fi
    fi
  fi
  echo "请先安装 Go 后再编译：" >&2
  echo "  curl -fsSL https://go.dev/dl/go1.26.8.linux-amd64.tar.gz | tar -C \"\$HOME/.local\" -xz" >&2
  echo "  export PATH=\"\$HOME/.local/go/bin:\$PATH\"" >&2
  exit 1
}

ensure_npm() {
  if command -v npm >/dev/null 2>&1; then
    return 0
  fi
  echo "未找到 npm。构建前端需要 Node.js。" >&2
  echo "安装后保证 npm 在 PATH 中，或使用 nvm。" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "需要 sha256sum 才能校验二进制版本" >&2
    exit 1
  fi
}

list_source_files() {
  local paths=()
  [[ -d "$ROOT/cmd" ]] && paths+=("$ROOT/cmd")
  [[ -d "$ROOT/internal" ]] && paths+=("$ROOT/internal")
  [[ -d "$ROOT/web/src" ]] && paths+=("$ROOT/web/src")
  local f
  for f in go.mod go.sum Makefile web/index.html web/package.json web/package-lock.json \
    web/vite.config.ts web/tsconfig.json web/embed.go; do
    [[ -e "$ROOT/$f" ]] && paths+=("$ROOT/$f")
  done
  if [[ ${#paths[@]} -eq 0 ]]; then
    return 0
  fi
  find "${paths[@]}" -type f \
    ! -path '*/node_modules/*' \
    ! -path '*/dist/*' \
    | LC_ALL=C sort
}

source_fingerprint() {
  local tmp out
  tmp="$(mktemp)"
  (
    cd "$ROOT"
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      printf '%s  %s\n' "$(sha256_file "$f")" "${f#"$ROOT"/}"
    done < <(list_source_files)
  ) >"$tmp"
  out="$(sha256_file "$tmp")"
  rm -f "$tmp"
  printf '%s' "$out"
}

write_binary_stamp() {
  mkdir -p "$(dirname "$STAMP_FILE")"
  local src bin_hash
  src="$(source_fingerprint)"
  bin_hash="$(sha256_file "$BIN")"
  cat >"$STAMP_FILE" <<EOF
src=$src
bin=$bin_hash
EOF
  chmod 600 "$STAMP_FILE"
}

stamp_matches_current() {
  [[ -x "$BIN" && -f "$STAMP_FILE" ]] || return 1
  local src bin_hash rec_src rec_bin
  src="$(source_fingerprint)"
  bin_hash="$(sha256_file "$BIN")"
  rec_src="$(awk -F= '/^src=/{print $2; exit}' "$STAMP_FILE")"
  rec_bin="$(awk -F= '/^bin=/{print $2; exit}' "$STAMP_FILE")"
  [[ -n "$rec_src" && -n "$rec_bin" && "$src" == "$rec_src" && "$bin_hash" == "$rec_bin" ]]
}

binary_matches_git() {
  [[ -x "$BIN" && -d "$ROOT/.git" ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  find_go || return 1
  if [[ -n "$(git -C "$ROOT" status --porcelain -- cmd internal web go.mod go.sum Makefile 2>/dev/null)" ]]; then
    return 1
  fi
  local rev meta
  rev="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || return 1
  [[ -n "$rev" ]] || return 1
  meta="$(go version -m "$BIN" 2>/dev/null)" || return 1
  if ! grep -q "vcs.revision=${rev}" <<<"$meta"; then
    return 1
  fi
  if grep -q "vcs.modified=true" <<<"$meta"; then
    return 1
  fi
  return 0
}

ensure_binary() {
  BINARY_REBUILT=0
  BIN="${BIN:-$ROOT/davbox}"
  if ! source_tree_present; then
    if [[ -x "$BIN" ]]; then
      echo "当前目录没有完整源码，使用现有二进制 $BIN"
      return 0
    fi
    echo "未找到二进制，且没有源码可编译。" >&2
    exit 1
  fi
  setup_build_path
  if [[ -x "$BIN" ]]; then
    echo "已有二进制 $BIN"
    if stamp_matches_current; then
      echo "二进制与源码版本一致。"
      return 0
    fi
    if [[ ! -f "$STAMP_FILE" ]] && binary_matches_git; then
      write_binary_stamp
      echo "二进制与源码版本一致。"
      return 0
    fi
    echo "二进制与源码版本不一致，重新编译。"
  else
    echo "未找到二进制，开始从源码构建。"
  fi
  need_cmd make
  ensure_go
  ensure_npm
  (cd "$ROOT" && make build)
  if [[ ! -x "$BIN" ]]; then
    echo "构建完成但未找到 $BIN" >&2
    exit 1
  fi
  write_binary_stamp
  BINARY_REBUILT=1
}
