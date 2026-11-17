#!/bin/bash
# oci-start-fixed 一键安装脚本（全新 VPS / 首次安装）
#
# 用法（一条命令，新 VPS 上直接执行）：
#   bash <(curl -fsSL https://4258806.github.io/oci-start-fixed-install.sh)
#
# 注意：必须用 bash <(...) 这种写法，不能用 curl | bash——管道会占用标准输入，
# 脚本就没法在终端上问你要 Token 了。
#
# 为什么要 Token：本仓库是私有的，GitHub 不允许匿名下载里面的文件（包括这个
# 安装脚本要拉的 release 资产）。脚本运行时会问你要一个 GitHub 细粒度 PAT，
# 只需要 oci-start-fixed 这一个仓库的 Contents: 只读权限（创建时选
# "Only select repositories" → 4258806/oci-start-fixed → Repository permissions
# 里 Contents 选 Read-only）。Token 只在本次安装使用，绝不写入任何文件。
# 也可以提前用环境变量传入，就不用交互输入：
#   GITHUB_TOKEN=<token> bash <(curl -fsSL https://4258806.github.io/oci-start-fixed-install.sh)
# 或用参数：bash <(curl ...) --token <token>（会进 shell 历史，不推荐）
#
# 脚本做的事：装 Java 17 → 从本仓库最新 release 拉 jar + oci-start.sh +
# oci-start.service + tmpfiles 片段 → 全量 SHA-256 校验（校验不过直接退出，
# 什么都不装）→ 生成随机的 H2 数据库密码写进 oci-start.env（600）→ 装 systemd
# 单元并启动 → 等面板 /login 能访问后打印地址。
# 要求：root、systemd、Debian/Ubuntu 或 RHEL 系。默认端口 26117，默认只绑
# 127.0.0.1（首次登录面板会提示换端口；远程访问请用 SSH 隧道或反代）。
# 已装过的机器不要重复跑（会直接拒绝）；升级用面板内更新或 oci-start.sh update。
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

die() { log_error "$1"; exit 1; }

REPO="4258806/oci-start-fixed"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
INSTALL_DIR="/root/oci-start"
JAR_PATH="${INSTALL_DIR}/oci-start-release.jar"
ENV_FILE="${INSTALL_DIR}/oci-start.env"
UNIT_FILE="/etc/systemd/system/oci-start.service"
TMPFILES_DST="/etc/tmpfiles.d/oci-start.conf"
JAR_NAME="oci-start-release.jar"
PORT=26117

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --token) GITHUB_TOKEN="${2:-}"; shift 2 ;;
        --token=*) GITHUB_TOKEN="${1#--token=}"; shift ;;
        *) die "未知参数：$1（只支持 --token <token>，一般不用传，脚本会提示输入）" ;;
    esac
done

# ---- 前置检查 ----
[ "$(id -u)" = 0 ] || die "请用 root 执行（全新 VPS 上一般就是 root）"
command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl：本脚本只支持带 systemd 的系统（Debian/Ubuntu/RHEL 系均可）"
[ -f "$JAR_PATH" ] && die "检测到已安装（$JAR_PATH 已存在）：不要重复安装，升级请用面板内更新或 oci-start.sh update"
[ -f "${INSTALL_DIR}/data/vps_db.mv.db" ] && die "检测到已有数据库（${INSTALL_DIR}/data/vps_db.mv.db）：不要重复安装，避免覆盖数据"

# ---- Token：环境变量 / 参数都没有时，交互提示输入（不回显，不保存）----
if [ -z "$GITHUB_TOKEN" ]; then
    echo "本仓库是私有的，需要一个 GitHub 细粒度 PAT 才能下载安装文件。"
    echo "创建方法：GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token，"
    echo "只选 oci-start-fixed 这一个仓库，Contents 权限给 Read-only 即可。"
    printf "请粘贴 Token（输入时不显示，粘贴后按回车）："
    IFS= read -r -s GITHUB_TOKEN < /dev/tty || IFS= read -r -s GITHUB_TOKEN
    echo
    [ -n "$GITHUB_TOKEN" ] || die "未输入 Token，退出"
fi

# ---- 基础工具 ----
if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
    log_info "安装 curl / coreutils..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y curl coreutils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl coreutils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl coreutils
    else
        die "找不到 apt/yum/dnf，请先手动装好 curl 与 sha256sum"
    fi
fi

# ---- Java 17：只认大版本号，低于 17 就装 17（本项目用 JDK 17 构建，Java 11 跑不起来）----
java_major() {
    command -v java >/dev/null 2>&1 || { echo 0; return; }
    java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/' | grep -E '^[0-9]+$' || echo 0
}
JAVA_MAJOR="$(java_major)"
if [ "$JAVA_MAJOR" -lt 17 ]; then
    log_info "未检测到 Java 17（当前：${JAVA_MAJOR:-无}），开始安装 openjdk-17..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y && DEBIAN_FRONTEND=noninteractive apt install -y openjdk-17-jre-headless
    elif command -v yum >/dev/null 2>&1; then
        yum install -y java-17-openjdk-headless
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y java-17-openjdk-headless
    else
        die "找不到 apt/yum/dnf，请手动安装 Java 17"
    fi
    # 机器上可能同时有多个 Java 版本，确保默认 java 是 17+
    for candidate in /usr/lib/jvm/java-17-openjdk-*/bin/java /usr/lib/jvm/jre-17-openjdk-*/bin/java; do
        if [ -x "$candidate" ] && command -v update-alternatives >/dev/null 2>&1; then
            update-alternatives --set java "$candidate" 2>/dev/null || true
            break
        fi
    done
    JAVA_MAJOR="$(java_major)"
    [ "$JAVA_MAJOR" -ge 17 ] || die "Java 17 安装后仍不可用（当前：${JAVA_MAJOR:-无}），请手动安装 Java 17 后再跑"
fi
log_info "Java 版本：$(java -version 2>&1 | head -1)"

# ---- 拉最新 release 信息（带 Token；私有仓库匿名访问会 404）----
log_info "获取本仓库最新 release..."
API_JSON="$(curl -fsSL --connect-timeout 10 --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$API_URL")" \
    || die "获取 release 信息失败：请检查 Token 是否有效（需 oci-start-fixed 的 Contents 只读权限）以及网络"
TAG="$(printf '%s' "$API_JSON" | grep '"tag_name":' | head -1 | cut -d '"' -f 4)"
[ -n "$TAG" ] || die "release 信息里没有 tag_name，请检查仓库是否已有 release"
log_info "最新版本：${TAG}"

asset_url() {
    # 在 release JSON 里按资产名找 browser_download_url（与 oci-start.sh update_latest 同款解析）
    printf '%s' "$API_JSON" | grep "browser_download_url.*\"$1\"" | head -1 | cut -d '"' -f 4
}
JAR_URL="$(asset_url "$JAR_NAME")"
SUMS_URL="$(asset_url "SHA256SUMS")"
SCRIPT_URL="$(asset_url "oci-start.sh")"
SERVICE_URL="$(asset_url "oci-start.service")"
TMPFILES_URL="$(asset_url "oci-start-tmpfiles.conf")"
[ -n "$JAR_URL" ] || die "该 release 没有 ${JAR_NAME} 资产，拒绝安装"
[ -n "$SUMS_URL" ] || die "该 release 没有 SHA256SUMS 校验文件，拒绝安装"
[ -n "$SCRIPT_URL" ] || die "该 release 没有 oci-start.sh 资产，拒绝安装"
[ -n "$SERVICE_URL" ] || die "该 release 没有 oci-start.service 资产，拒绝安装"
[ -n "$TMPFILES_URL" ] || die "该 release 没有 oci-start-tmpfiles.conf 资产，拒绝安装"

# ---- 下载全部资产到临时目录并全量校验 ----
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
log_info "下载安装文件到临时目录..."
dl() { # dl <url> <dest>
    curl -fL --connect-timeout 30 --max-time 600 -H "Authorization: Bearer ${GITHUB_TOKEN}" -o "$2" "$1" \
        || die "下载失败：$1（请检查 Token 与网络）"
    [ -s "$2" ] || die "下载的文件为空：$2"
}
dl "$JAR_URL" "${WORKDIR}/${JAR_NAME}"
dl "$SUMS_URL" "${WORKDIR}/SHA256SUMS"
dl "$SCRIPT_URL" "${WORKDIR}/oci-start.sh"
dl "$SERVICE_URL" "${WORKDIR}/oci-start.service"
dl "$TMPFILES_URL" "${WORKDIR}/oci-start-tmpfiles.conf"

log_info "SHA-256 全量校验..."
(cd "$WORKDIR" && sha256sum -c SHA256SUMS) || die "SHA-256 校验失败：下载的文件与发布页公布的不一致，拒绝安装（临时文件已清理）"
# 额外确认 jar 是真的 Java 归档
if command -v file >/dev/null 2>&1; then
    file "${WORKDIR}/${JAR_NAME}" | grep -q "Java archive\|Zip archive" \
        || die "下载的 jar 不是有效的 Java 归档，拒绝安装"
fi
log_success "校验通过（版本 ${TAG}）"

# ---- 落盘 ----
log_info "安装文件到 ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/data" "${INSTALL_DIR}/logs" /root/.oci
install -m 644 "${WORKDIR}/${JAR_NAME}" "$JAR_PATH"
install -m 755 "${WORKDIR}/oci-start.sh" "${INSTALL_DIR}/oci-start.sh"
ln -sf "${INSTALL_DIR}/oci-start.sh" /usr/local/bin/oci-start
install -m 644 "${WORKDIR}/oci-start.service" "$UNIT_FILE"
install -m 644 "${WORKDIR}/oci-start-tmpfiles.conf" "$TMPFILES_DST"

# H2 数据库密码：随机生成，只写进 oci-start.env（600），绝不进仓库
if [ ! -f "$ENV_FILE" ]; then
    if command -v openssl >/dev/null 2>&1; then
        H2PW="$(openssl rand -hex 24)"
    else
        H2PW="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    printf 'H2_PASSWORD=%s\n' "$H2PW" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log_info "已生成随机的 H2 数据库密码（在 ${ENV_FILE}，请随数据目录一起备份，丢了数据库就打不开）"
fi

# ---- 启动服务 ----
log_info "启动服务..."
systemd-tmpfiles --create "$TMPFILES_DST" 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now oci-start || die "启动服务失败，请看 journalctl -u oci-start"

log_info "等待面板启动（首次启动约 40 秒）..."
for _ in $(seq 1 30); do
    if curl -fs -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/login" 2>/dev/null; then
        break
    fi
    sleep 3
done
curl -fs -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/login" 2>/dev/null \
    || die "服务已启动但 ${PORT} 端口无响应，请看 journalctl -u oci-start 与 ${INSTALL_DIR}/logs/application.log"

log_success "安装完成（版本 ${TAG}）"
echo
echo "面板地址：http://127.0.0.1:${PORT}/login"
echo "默认账号：admin / admin（首次登录务必马上改密码）"
echo "注意：面板默认只绑 127.0.0.1，只能本机访问；远程访问请用 SSH 隧道："
echo "  ssh -L ${PORT}:127.0.0.1:${PORT} root@<这台VPS的IP> -p <SSH端口>"
echo "然后在自己电脑浏览器打开 http://127.0.0.1:${PORT}/login"
echo "管理命令：oci-start {start|stop|restart|status|update|uninstall}"
echo "升级：oci-start update（从本仓库最新 release 拉取，同样要过 SHA-256 校验）"
