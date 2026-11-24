#!/usr/bin/env bash
# NavPanel 一键安装 / 升级脚本（HTML 版生产部署）
#
# 两种用法：
#   1) 仓库内执行（会拷贝当前源码）
#        sudo bash deploy/install.sh                      # 默认装到 /opt/navpanel
#        sudo bash deploy/install.sh --port 8080          # 换监听端口
#        sudo bash deploy/install.sh --data-dir /data/nav # 换数据目录（默认 /var/lib/navpanel）
#   2) 一行命令远程安装（脚本被单独下载时自动拉源码）
#        curl -fsSL <install.sh 地址> -o install.sh && bash install.sh <管理员口令>
#        curl -fsSL <install.sh 地址> | bash -s -- <管理员口令>
#        curl -fsSL <install.sh 地址> | bash        # 全默认安装，口令随机生成并在末尾打印
#     源码获取顺序：--archive 指定的 tar.gz → 仓库 archive 直链 → git clone
#     用 --repo / --ref 指定仓库地址与分支（默认 https://cnb.cool/supbose/python/siteWeb，main）
#
# 已安装过再次执行 = 升级：代码覆盖、依赖更新、前端重建、服务重启；.env 与数据目录不动
# （除非显式 --force 重建 .env）。
#
# 安全默认：随机生成 SECRET_KEY 与管理员口令、.env 权限 600、系统默认只读 +
# 仅数据目录可写；NAVPANEL_PUBLIC_MODE 初始为 0（访客只能看到登录页），需要公开再自行改。

set -euo pipefail

SERVICE_NAME="navpanel"
INSTALL_DIR="${INSTALL_DIR:-/opt/navpanel}"
DATA_DIR="${DATA_DIR:-/var/lib/navpanel}"
PORT="${PORT:-8000}"
RUN_USER="${RUN_USER:-navpanel}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
PIP_INDEX="${PIP_INDEX:-}"
CREATE_USER=1
AUTO_APT=1
CHECK_DEPS=0
INSTALL_SERVICE=1
INSTALL_DEPS=1
START_SERVICE=1
FORCE_ENV=0

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
  SOURCE_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
else
  SOURCE_DIR=""   # 通过管道执行（curl | bash），没有脚本文件路径
fi
REPO_URL="${NAVPANEL_REPO_URL:-https://cnb.cool/supbose/python/siteWeb}"
REF="${NAVPANEL_REF:-main}"
ARCHIVE_URL="${NAVPANEL_ARCHIVE_URL:-}"
TMP_SOURCE=""
POSITIONAL_PASSWORD=0
SHA256_EXPECT=""

# 安装向导入口：显式 --wizard；或在交互终端里无参数执行（且向导脚本就位）。
# 管道 / CI（stdin 不是 TTY）保持原有静默安装，不会被向导拦住。
if [[ -n "${SOURCE_DIR:-}" && -f "$SOURCE_DIR/deploy/install-wizard.sh" ]]; then
  if [[ "${1:-}" == "--wizard" ]]; then
    shift
    exec bash "$SOURCE_DIR/deploy/install-wizard.sh" "$@"
  fi
  if [[ $# -eq 0 && -t 0 ]]; then
    exec bash "$SOURCE_DIR/deploy/install-wizard.sh"
  fi
fi

log() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

# 有些环境（systemd 精简 PATH、cron、容器）里 /usr/sbin 不在 PATH，先找 PATH 再找常见绝对路径
detect_cmd() { # detect_cmd 名称 [候选绝对路径...] → 输出可执行路径
  local name="$1" candidate
  shift
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  for candidate in "$@"; do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# ------- 依赖自检与按需安装（缺什么装什么） -------
dep_have() { detect_cmd "$@" >/dev/null 2>&1; }

detect_pkg_mgr() {
  local m
  for m in apt-get dnf yum apk zypper; do
    command -v "$m" >/dev/null 2>&1 && { printf '%s' "$m"; return 0; }
  done
  return 1
}

pkg_name_for() { # pkg_name_for <依赖> <包管理器> → 包名（空串表示该系统没有对应包）
  case "$1:$2" in
    python3:*)                                        printf 'python3' ;;
    venv:apt-get)                                     printf 'python3-venv' ;;
    venv:dnf|venv:yum|venv:zypper)                    printf 'python3-pip' ;;
    venv:apk)                                         printf 'py3-pip' ;;
    useradd:apt-get)                                  printf 'passwd' ;;
    useradd:dnf|useradd:yum)                          printf 'shadow-utils' ;;
    useradd:zypper)                                   printf 'shadow' ;;
    useradd:apk)                                      printf 'shadow' ;;
    systemctl:apt-get|systemctl:dnf|systemctl:yum|systemctl:zypper) printf 'systemd' ;;
    systemctl:apk)                                    printf '' ;;
    curl:*)                                           printf 'curl' ;;
    tar:*)                                            printf 'tar' ;;
    sha256sum:apt-get|sha256sum:dnf|sha256sum:yum|sha256sum:zypper|sha256sum:apk) printf 'coreutils' ;;
    *)                                                printf '' ;;
  esac
}

install_pkgs() { # install_pkgs <包管理器> <包...>
  local mgr="$1" p rc=0
  shift
  [[ $# -gt 0 ]] || return 0
  case "$mgr" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1 || warn "apt-get update 失败，继续尝试安装"
      if apt-get install -y -qq "$@" >/dev/null 2>&1; then
        log "已安装：$*"
        return 0
      fi
      # 某个包在当前源里不存在时，逐个装，能装的照装
      for p in "$@"; do
        if apt-get install -y -qq "$p" >/dev/null 2>&1; then
          log "已安装：$p"
        else
          warn "安装 $p 失败（跳过）"
          rc=1
        fi
      done ;;
    dnf) dnf install -y -q "$@" >/dev/null 2>&1 || rc=1 ;;
    yum) yum install -y -q "$@" >/dev/null 2>&1 || rc=1 ;;
    apk) apk add --no-cache "$@" >/dev/null 2>&1 || rc=1 ;;
    zypper) zypper --non-interactive install "$@" >/dev/null 2>&1 || rc=1 ;;
    *) warn "未识别的包管理器：$mgr"; rc=1 ;;
  esac
  return $rc
}

ensure_deps() { # 检查运行依赖，缺什么装什么；--check-deps 只查，--no-auto-deps 只提示
  local mgr missing=() pkgs=() uniq=() p pkg ver exists
  mgr="$(detect_pkg_mgr || true)"

  [[ -n "${PYTHON_BIN:-}" ]] || missing+=("python3")
  if [[ -n "${PYTHON_BIN:-}" ]] && ! "$PYTHON_BIN" -c 'import ensurepip' >/dev/null 2>&1; then
    missing+=("venv")
  fi
  dep_have curl || missing+=("curl")
  dep_have tar || missing+=("tar")
  if [[ -n "$SHA256_EXPECT" ]] && ! dep_have sha256sum; then
    missing+=("sha256sum")
  fi
  if [[ $CREATE_USER -eq 1 ]] && ! dep_have useradd /usr/sbin/useradd /sbin/useradd; then
    missing+=("useradd")
  fi
  if [[ $INSTALL_SERVICE -eq 1 ]] && ! dep_have systemctl /usr/bin/systemctl /bin/systemctl; then
    missing+=("systemctl")
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "依赖检查通过：python3 + venv、curl、tar 以及运行所需命令都已就绪"
    if [[ $CHECK_DEPS -eq 1 ]]; then exit 0; fi
    return 0
  fi

  log "缺少依赖：${missing[*]}"
  if [[ $CHECK_DEPS -eq 1 ]]; then
    warn "--check-deps：只做检查，未安装任何包（包管理器：${mgr:-未识别}）"
    return 1
  fi

  for p in "${missing[@]}"; do
    pkg="$(pkg_name_for "$p" "$mgr")"
    [[ -n "$pkg" ]] && pkgs+=("$pkg")
  done
  if [[ "$mgr" == "apt-get" && -n "${PYTHON_BIN:-}" && " ${missing[*]} " == *" venv "* ]]; then
    ver="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    [[ -n "$ver" ]] && pkgs+=("python${ver}-venv")
  fi
  for p in "${pkgs[@]}"; do
    exists=0
    for pkg in "${uniq[@]}"; do [[ "$pkg" == "$p" ]] && { exists=1; break; }; done
    [[ $exists -eq 0 ]] && uniq+=("$p")
  done
  pkgs=("${uniq[@]}")

  if [[ $AUTO_APT -eq 0 ]]; then
    die "已禁用自动安装（--no-auto-deps）：请先手动安装 ${missing[*]}（例：${mgr:-apt-get} install -y ${pkgs[*]:-${missing[*]}}）再重跑"
  fi
  [[ -n "$mgr" ]] || die "未识别包管理器（apt-get/dnf/yum/apk/zypper），请手动安装：${missing[*]}"
  log "使用 $mgr 安装：${pkgs[*]}"
  install_pkgs "$mgr" "${pkgs[@]}" || warn "部分包安装失败，继续按现有能力尝试"

  [[ -n "${PYTHON_BIN:-}" ]] || PYTHON_BIN="$(detect_cmd python3 /usr/bin/python3 /usr/local/bin/python3 || true)"
  [[ -n "${PYTHON_BIN:-}" ]] || die "python3 仍未就绪：请手动安装 python3 后重跑"
  if ! "$PYTHON_BIN" -c 'import ensurepip' >/dev/null 2>&1; then
    "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  "$PYTHON_BIN" -c 'import ensurepip' >/dev/null 2>&1 \
    || die "venv 缺 ensurepip：手动执行 ${mgr} install -y python3-venv（或 python3.X-venv）后重跑"
  dep_have curl || dep_have wget || die "仍然没有 curl 或 wget：手动安装后重跑"
  log "依赖补齐完成"
}

fetch_to() { # fetch_to URL DEST
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 10 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 15 -O "$2" "$1"
  else
    return 1
  fi
}

archive_candidates() {
  local repo="${REPO_URL%/}" ref="$REF" name
  name="$(basename "$repo")"
  [[ -n "$ARCHIVE_URL" ]] && printf '%s\n' "$ARCHIVE_URL"
  [[ "$repo" == *github.com* ]] && printf '%s\n' "$repo/archive/refs/heads/$ref.tar.gz"
  printf '%s\n' \
    "$repo/-/archive/$ref/$name-$ref.tar.gz" \
    "$repo/-/archive/$ref.tar.gz" \
    "$repo/archive/refs/heads/$ref.tar.gz" \
    "$repo/-/archive/refs/heads/$ref.tar.gz"
}

fetch_source() {
  TMP_SOURCE="$(mktemp -d 2>/dev/null)" || die "无法创建临时目录（检查 TMPDIR=${TMPDIR:-/tmp} 是否存在且可写）"
  trap 'rm -rf -- "${TMP_SOURCE:?}"' EXIT
  local tgz="$TMP_SOURCE/src.tar.gz" url="" candidate
  log "本地没有源码，从 ${REPO_URL}（ref=${REF}）获取"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if fetch_to "$candidate" "$tgz" 2>/dev/null && tar -tzf "$tgz" >/dev/null 2>&1; then
      url="$candidate"
      break
    fi
  done < <(archive_candidates)
  if [[ -n "$url" ]]; then
    log "已下载源码包：$url"
    if [[ -n "$SHA256_EXPECT" ]]; then
      command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum，无法校验下载包"
      local actual
      actual="$(sha256sum "$tgz" | cut -d' ' -f1)"
      [[ "$actual" == "$SHA256_EXPECT" ]] \
        || die "下载包校验失败：期望 $SHA256_EXPECT，实际 $actual（可能是镜像未更新或文件被替换）"
      log "校验通过：sha256 $actual"
    fi
    tar -xzf "$tgz" -C "$TMP_SOURCE" || die "解包失败：$url"
    SOURCE_DIR="$(find "$TMP_SOURCE" -mindepth 1 -maxdepth 1 -type d | head -1)"
  elif [[ -z "$ARCHIVE_URL" ]]; then
        warn "这份 install.sh 里没有内置源码包地址（第 3 行缺 export NAVPANEL_ARCHIVE_URL），通常是把仓库的 deploy/install.sh 原样传到了服务器"
    die "改用打包生成的 install.sh（dist/publish/install.sh），或显式给地址：bash install.sh --archive https://你的域名/navpanel/navpanel.tar.gz"
  elif command -v git >/dev/null 2>&1; then
    log "压缩包直链均不可用，改用 git clone"
    git clone --depth 1 --branch "$REF" "$REPO_URL" "$TMP_SOURCE/repo" \
      || die "git clone 失败：检查仓库地址与访问权限（私有仓库需带令牌的 URL，或改用 --archive 指定可访问的 tar.gz）"
    SOURCE_DIR="$TMP_SOURCE/repo"
  else
    die "无法获取源码：压缩包直链不可用且没有 git；用 --archive <tar.gz> 或 --repo <git 地址> 指定可访问来源"
  fi
  [[ -f "$SOURCE_DIR/app/main.py" ]] || die "取到的源码不完整（缺 app/main.py）：$SOURCE_DIR"
  log "源码就绪：$SOURCE_DIR"
}

usage() {
  cat <<'EOF'
NavPanel 一键安装 / 升级脚本（HTML 版生产部署）

两种用法：
  仓库内：  sudo bash deploy/install.sh [参数]
  一行命令：curl -fsSL <install.sh 地址> | bash -s -- [参数] [管理员口令]

脚本被单独下载执行时（当前目录没有 app/main.py、web/index.html），
会自动按 --repo / --ref 拉取源码（tar.gz 直链优先，失败回退 git clone）。

打包生成的 install.sh 会在第 3 行内置源码包地址（export NAVPANEL_ARCHIVE_URL）；
直接把仓库里的 deploy/install.sh 传上服务器没有这一行，需用 --archive 指定。

可选参数：
  --install-dir DIR     代码安装目录，默认 /opt/navpanel
  --data-dir DIR        数据目录（SQLite/图标/背景图），默认 /var/lib/navpanel
  --port PORT           HTTP 监听端口，默认 8000（只监听 127.0.0.1，对外请走反向代理）
  --admin-username NAME 管理员账号名，默认 admin（仅首次创建库时生效）
  --admin-password PWD  管理员口令，默认随机生成并写入 .env
  --run-user USER       运行用户，默认 navpanel（--no-user 时不改）
  --pip-index URL       pip 镜像源，例如 https://pypi.tuna.tsinghua.edu.cn/simple
  --repo URL            源码仓库地址，默认 https://cnb.cool/supbose/python/siteWeb
  --ref BRANCH          git 分支或标签，默认 main
  --archive URL         直接指定源码 tar.gz 地址（优先级最高，私有仓库可用带签名的临时链接）
  --sha256 HEX          下载源码包后校验 SHA256，不匹配则拒绝安装（可从 SHA256SUMS 取）
  --wizard              进入交互式安装向导（安装/卸载、域名与 SSL、镜像源）
  --no-user             不创建系统用户（已自备用户时用）
  --no-systemd          不安装 systemd 单元（只装代码与产物，例如容器内手动启动）
  --no-deps             跳过 pip 安装（离线/已预装依赖）
  --no-auto-apt         等价 --no-auto-deps：缺依赖时只提示，不自动安装
  --no-auto-deps        缺依赖（python3-venv/useradd/curl/tar 等）时只提示，不自动安装
  --check-deps          只检查运行依赖是否齐全并退出（不装包、不改系统）
  --no-start            装完不启动服务
  --force               已存在 .env 时也重建（会重新生成密钥与口令）
  -h, --help            显示本帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="${2:?缺目录}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:?缺目录}"; shift 2 ;;
    --port) PORT="${2:?缺端口}"; shift 2 ;;
    --admin-username) ADMIN_USERNAME="${2:?缺账号}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2:?缺口令}"; shift 2 ;;
    --run-user) RUN_USER="${2:?缺用户}"; shift 2 ;;
    --pip-index) PIP_INDEX="${2:?缺地址}"; shift 2 ;;
    --no-user) CREATE_USER=0; shift ;;
    --no-systemd) INSTALL_SERVICE=0; shift ;;
    --no-deps) INSTALL_DEPS=0; shift ;;
    --no-auto-apt|--no-auto-deps) AUTO_APT=0; shift ;;
    --check-deps) CHECK_DEPS=1; shift ;;
    --no-start) START_SERVICE=0; shift ;;
    --force) FORCE_ENV=1; shift ;;
    --repo) REPO_URL="${2:?缺地址}"; shift 2 ;;
    --ref) REF="${2:?缺分支}"; shift 2 ;;
    --archive) ARCHIVE_URL="${2:?缺地址}"; shift 2 ;;
    --sha256) SHA256_EXPECT="${2:?缺校验值}"; shift 2 ;;
    --wizard) : ; shift ;;  # 已在前面 exec，这里兜底
    -h|--help) usage; exit 0 ;;
    -*) die "未知参数：$1（用 --help 看用法）" ;;
    *)
      # 唯一的位置参数当作管理员口令，方便一行命令写成 bash install.sh <口令>
      if [[ $POSITIONAL_PASSWORD -eq 1 || -n "$ADMIN_PASSWORD" ]]; then
        die "多余的位置参数：$1"
      fi
      ADMIN_PASSWORD="$1"
      POSITIONAL_PASSWORD=1
      shift
      ;;
  esac
done

# ---------- 0. 前置检查与依赖 ----------
[[ $CHECK_DEPS -eq 1 || ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限执行（sudo bash deploy/install.sh）"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字：$PORT"
PYTHON_BIN="${PYTHON_BIN:-$(detect_cmd python3 /usr/bin/python3 /usr/local/bin/python3 || true)}"
if ! ensure_deps; then
  if [[ $CHECK_DEPS -eq 1 ]]; then
    warn "依赖检查未通过"
    exit 1
  fi
fi
[[ -n "${PYTHON_BIN:-}" ]] || die "缺少 python3：安装后重跑（或先用 --check-deps 看缺什么）"
if [[ -z "$SOURCE_DIR" || ! -f "$SOURCE_DIR/app/main.py" ]]; then
  fetch_source
fi

for item in app/main.py deploy/navpanel.service scripts/serve_html.py requirements.txt; do
  [[ -e "$SOURCE_DIR/$item" ]] || die "源码不完整，缺少 $item；请在仓库根目录执行本脚本"
done
# 前端产物：发布包只带 dist/web，从仓库执行时才同时有 web/ 源
if [[ ! -e "$SOURCE_DIR/web/index.html" && ! -e "$SOURCE_DIR/dist/web/index.html" ]]; then
  die "源码不完整：web/ 与 dist/web 都不存在，没有可用的前端产物"
fi

# 运行用户与组
if [[ $CREATE_USER -eq 1 ]]; then
  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    USERADD_BIN="$(detect_cmd useradd /usr/sbin/useradd /sbin/useradd)" \
      || die "缺少 useradd（Debian/Ubuntu 装 passwd 包；或加 --no-user 跳过用户创建）"
    log "创建系统用户 $RUN_USER"
    "$USERADD_BIN" --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$RUN_USER" \
      || die "创建用户失败"
  else
    log "用户 $RUN_USER 已存在，跳过创建"
  fi
  RUN_GROUP="$(id -gn "$RUN_USER")"
else
  RUN_USER="${SUDO_USER:-root}"
  RUN_GROUP="$(id -gn "$RUN_USER")"
  warn "--no-user：以现有用户 $RUN_USER:$RUN_GROUP 运行，systemd 单元保持原 User 设置"
fi

# ---------- 1. 代码就位 ----------
if [[ "$SOURCE_DIR" == "$(readlink -f "$INSTALL_DIR")" ]]; then
  log "源码已在 $INSTALL_DIR，跳过复制（原地升级）"
else
  log "复制代码到 $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  if RSYNC_BIN="$(detect_cmd rsync /usr/bin/rsync /usr/local/bin/rsync)"; then
    "$RSYNC_BIN" -a --delete \
      --exclude '.git' --exclude '.env' --exclude 'data/' \
      --exclude 'dist/release/' --exclude 'dist/publish/' \
      --exclude '.venv/' --exclude '.screenshots/' --exclude '*.zip' \
      --exclude '__pycache__/' --exclude '.pytest_cache/' \
      --exclude 'frontend/node_modules/' --exclude 'frontend/dist/' \
      "$SOURCE_DIR"/ "$INSTALL_DIR"/
  else
    tar -C "$SOURCE_DIR" -cf - \
      --exclude=.git --exclude=.env --exclude=data --exclude=.venv \
      --exclude=dist/release --exclude=dist/publish \
      --exclude=.screenshots --exclude=__pycache__ --exclude=.pytest_cache \
      --exclude=frontend/node_modules --exclude=frontend/dist . \
      | tar -C "$INSTALL_DIR" -xf -
  fi
fi

# ---------- 2. 虚拟环境与依赖 ----------
if [[ ! -x "$INSTALL_DIR/.venv/bin/python" ]]; then
  log "创建虚拟环境 $INSTALL_DIR/.venv"
  "$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv" || die "创建 venv 失败（Debian/Ubuntu 需先 apt install python3-venv）"
fi
if [[ $INSTALL_DEPS -eq 1 ]]; then
  log "安装运行依赖"
  PIP_ARGS=(install -q -r "$INSTALL_DIR/requirements.txt")
  [[ -n "$PIP_INDEX" ]] && PIP_ARGS+=(--index-url "$PIP_INDEX")
  "$INSTALL_DIR/.venv/bin/python" -m pip "${PIP_ARGS[@]}" || die "pip 安装失败（可加 --pip-index 换源）"
else
  warn "--no-deps：跳过依赖安装，启动前请确保 venv 里已有依赖"
fi

# ---------- 3. 配置 .env ----------
ENV_FILE="$INSTALL_DIR/.env"
gen_secret() {
  "$INSTALL_DIR/.venv/bin/python" -c 'import secrets; print(secrets.token_urlsafe(32))'
}
set_env() { # set_env KEY VALUE
  local key="$1" value="$2"
  if grep -qE "^[#[:space:]]*${key}=" "$ENV_FILE"; then
    # 同时处理注释行，避免出现两份定义
    "$INSTALL_DIR/.venv/bin/python" - "$ENV_FILE" "$key" "$value" <<'PY'
import sys
from pathlib import Path
path, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines, done = [], False
for line in path.read_text(encoding="utf-8").splitlines():
    stripped = line.lstrip("# ").strip()
    if stripped.startswith(f"{key}="):
        if not done:
            lines.append(f"{key}={value}")
            done = True
        continue
    lines.append(line)
if not done:
    lines.append(f"{key}={value}")
path.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")
PY
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

if [[ -f "$ENV_FILE" && $FORCE_ENV -eq 0 ]]; then
  log ".env 已存在，保留原配置（密钥与口令不覆盖）"
else
  log "生成 $ENV_FILE"
  cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
  set_env NAVPANEL_DATA_DIR "$DATA_DIR"
  set_env NAVPANEL_FRONTEND "html"
  set_env NAVPANEL_WEB_DIR "$INSTALL_DIR/dist/web"
  set_env NAVPANEL_PUBLIC_MODE "0"
  set_env NAVPANEL_ADMIN_USERNAME "$ADMIN_USERNAME"
  set_env NAVPANEL_SECRET_KEY "$(gen_secret)"
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    set_env NAVPANEL_ADMIN_PASSWORD "$ADMIN_PASSWORD"
  else
    ADMIN_PASSWORD="$(gen_secret | cut -c1-20)"
    set_env NAVPANEL_ADMIN_PASSWORD "$ADMIN_PASSWORD"
  fi
fi
chown "$RUN_USER:$RUN_GROUP" "$ENV_FILE" 2>/dev/null || true
chmod 600 "$ENV_FILE"

# ---------- 4. 目录与权限 ----------
log "准备数据目录 $DATA_DIR"
mkdir -p "$DATA_DIR"
chown -R "$RUN_USER:$RUN_GROUP" "$DATA_DIR" 2>/dev/null || true
chmod 750 "$DATA_DIR"
chown -R "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR" 2>/dev/null || true

# ---------- 5. HTML 版前端产物（包内已压缩则直接用） ----------
if [[ -f "$INSTALL_DIR/dist/web/index.html" ]]; then
  log "使用包内已压缩的前端产物（dist/web，跳过现场构建）"
elif [[ ! -d "$INSTALL_DIR/web" ]]; then
  die "安装包里既没有 dist/web 也没有 web/，包不完整（重新下载发布包）"
else
  log "包内没有压缩产物，现场构建（web/ → dist/web）"
  ( cd "$INSTALL_DIR" && "$INSTALL_DIR/.venv/bin/python" scripts/minify_web.py --source web --dest dist/web ) \
    || die "前端构建失败"
  ( cd "$INSTALL_DIR" && "$INSTALL_DIR/.venv/bin/python" scripts/minify_web.py --source web --dest dist/web --check ) \
    || die "产物校验失败"
fi
chown -R "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR/dist" 2>/dev/null || true

# ---------- 6. systemd 单元 ----------
if [[ $INSTALL_SERVICE -eq 1 ]]; then
  SYSTEMCTL_BIN="$(detect_cmd systemctl /usr/bin/systemctl /bin/systemctl)" \
    || die "缺少 systemctl（可用 --no-systemd 只装代码）"
  UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
  log "生成 $UNIT_PATH"
  sed \
    -e "s#/opt/navpanel#$INSTALL_DIR#g" \
    -e "s#--port 8000#--port $PORT#g" \
    "$INSTALL_DIR/deploy/navpanel.service" > "$UNIT_PATH"

  # 数据目录不是 /var/lib/navpanel 时，StateDirectory 管不到，改用 ReadWritePaths
  if [[ "$DATA_DIR" != "/var/lib/navpanel" ]]; then
    sed -i -e '/^StateDirectory=/d' -e '/^StateDirectoryMode=/d' \
           -e "s#^ReadWritePaths=.*#ReadWritePaths=$DATA_DIR#" "$UNIT_PATH"
  fi
  if [[ $CREATE_USER -eq 0 ]]; then
    sed -i -e "s#^User=.*#User=$RUN_USER#" -e "s#^Group=.*#Group=$RUN_GROUP#" "$UNIT_PATH"
  fi
  chmod 0644 "$UNIT_PATH"
  "$SYSTEMCTL_BIN" daemon-reload
fi

# ---------- 7. 启动与自检 ----------
if [[ $INSTALL_SERVICE -eq 1 && $START_SERVICE -eq 1 ]]; then
  log "启动服务 $SERVICE_NAME"
  "$SYSTEMCTL_BIN" enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "enable 失败，可稍后手动 systemctl enable $SERVICE_NAME"
  "$SYSTEMCTL_BIN" restart "$SERVICE_NAME" || die "启动失败：journalctl -u $SERVICE_NAME -n 50 查看原因"

  HEALTH="http://127.0.0.1:${PORT}/api/health"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 "$HEALTH" >/dev/null 2>&1; then
      log "自检通过：$HEALTH"
      curl -fsS "$HEALTH" && echo
      break
    fi
    sleep 1
  done
  "$SYSTEMCTL_BIN" is-active --quiet "$SERVICE_NAME" || die "服务未处于 active：journalctl -u $SERVICE_NAME -n 50"
fi

# ---------- 8. 结果摘要 ----------
cat <<EOF

$(log "安装完成")
  安装目录：$INSTALL_DIR
  数据目录：$DATA_DIR
  配置文件：$ENV_FILE （600，含 SECRET_KEY 与管理员口令）
  前端产物：$INSTALL_DIR/dist/web
  运行用户：$RUN_USER:$RUN_GROUP
EOF
if [[ $INSTALL_SERVICE -eq 1 ]]; then
  cat <<EOF
  systemd：/etc/systemd/system/${SERVICE_NAME}.service
  监听：   http://127.0.0.1:$PORT （对外请配反向代理 + TLS）
  常用命令：systemctl {status,restart,logs} $SERVICE_NAME
EOF
fi
if [[ -f "$ENV_FILE" ]] && grep -q '^NAVPANEL_ADMIN_PASSWORD=.\+' "$ENV_FILE"; then
  cat <<EOF
  管理员账号：$(grep '^NAVPANEL_ADMIN_USERNAME=' "$ENV_FILE" | cut -d= -f2)
  管理员口令：$(grep '^NAVPANEL_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2)
  首次登录后请改密，并妥善保管 $ENV_FILE
EOF
else
  cat <<EOF
  管理员口令未预设：首次启动生成在 $DATA_DIR/initial_admin_password.txt（登录后请改密并删除该文件）
EOF
fi