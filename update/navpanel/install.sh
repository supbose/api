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

# ---------- 0. 前置检查 ----------
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限执行（sudo bash deploy/install.sh）"
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
command -v python3 >/dev/null || die "缺少 python3"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字：$PORT"

# 运行用户与组
if [[ $CREATE_USER -eq 1 ]]; then
  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    command -v useradd >/dev/null || die "缺少 useradd（可 --no-user 跳过用户创建）"
    log "创建系统用户 $RUN_USER"
    useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$RUN_USER" \
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
  if command -v rsync >/dev/null; then
    rsync -a --delete \
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
  python3 -m venv "$INSTALL_DIR/.venv" || die "创建 venv 失败（Debian/Ubuntu 需先 apt install python3-venv）"
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
  command -v systemctl >/dev/null || die "缺少 systemctl（可用 --no-systemd 只装代码）"
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
  systemctl daemon-reload
fi

# ---------- 7. 启动与自检 ----------
if [[ $INSTALL_SERVICE -eq 1 && $START_SERVICE -eq 1 ]]; then
  log "启动服务 $SERVICE_NAME"
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "enable 失败，可稍后手动 systemctl enable $SERVICE_NAME"
  systemctl restart "$SERVICE_NAME" || die "启动失败：journalctl -u $SERVICE_NAME -n 50 查看原因"

  HEALTH="http://127.0.0.1:${PORT}/api/health"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 "$HEALTH" >/dev/null 2>&1; then
      log "自检通过：$HEALTH"
      curl -fsS "$HEALTH" && echo
      break
    fi
    sleep 1
  done
  systemctl is-active --quiet "$SERVICE_NAME" || die "服务未处于 active：journalctl -u $SERVICE_NAME -n 50"
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