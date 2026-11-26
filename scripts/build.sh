#!/usr/bin/env bash
# 在 CentOS 7 x86_64 容器内编译 pcsc-lite，产出动态库、静态库与头文件。
# 由 .github/workflows/build-pcsc-lite.yml 调用，也可本地 docker run 执行。
set -Eeuo pipefail

VERSION="${VERSION:-2.0.3}"
SRC_TAG="${SRC_TAG:-${VERSION}}"
WORK_ROOT="${WORK_ROOT:-/tmp/pcsc-lite-build}"
DIST_DIR="${DIST_DIR:-/workspace/dist}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/workspace}"
PREFIX="${PREFIX:-/usr/local}"
JOBS="${JOBS:-$(nproc)}"

# 可选特性默认关闭：libpcsclite 本身只依赖 pthread，关掉这些不影响库，
# 只影响 pcscd 的 USB 热插拔 / 访问控制。需要时置 1（会自动装对应 devel 包）。
ENABLE_LIBUDEV="${ENABLE_LIBUDEV:-0}"
ENABLE_LIBSYSTEMD="${ENABLE_LIBSYSTEMD:-0}"
ENABLE_POLKIT="${ENABLE_POLKIT:-0}"

SRC_URL="https://github.com/LudovicRousseau/PCSC/archive/refs/tags/${SRC_TAG}.tar.gz"
MACRO_BASE="https://raw.githubusercontent.com/autoconf-archive/autoconf-archive/master/m4"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 1. CentOS 7 已 EOL，官方 mirrorlist 失效，切到 vault ----------
log "配置 CentOS 7 yum 源 (vault)"
REPO="/etc/yum.repos.d/CentOS-Base.repo"
if [[ -f "$REPO" ]]; then
  sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' \
    "$REPO"
fi
yum makecache >/dev/null 2>&1 || true

# ---------- 2. 依赖 ----------
log "安装编译依赖"
PKG_LIST="gcc make autoconf automake libtool pkgconfig flex curl tar gzip bzip2 file"
if [[ "$ENABLE_LIBUDEV" == "1" || "$ENABLE_LIBSYSTEMD" == "1" ]]; then
  PKG_LIST="$PKG_LIST systemd-devel"
fi
if [[ "$ENABLE_POLKIT" == "1" ]]; then
  PKG_LIST="$PKG_LIST polkit-devel"
fi
# shellcheck disable=SC2086
yum install -y $PKG_LIST

# ---------- 3. 源码 + 缺失的 autoconf 宏 ----------
log "下载 pcsc-lite ${VERSION} 源码"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$(dirname "$DIST_DIR")"
curl -fsSL "$SRC_URL" -o "$WORK_ROOT/pcsc.tar.gz"
tar -xzf "$WORK_ROOT/pcsc.tar.gz" -C "$WORK_ROOT"
SRC_DIR="$WORK_ROOT/PCSC-${SRC_TAG}"
[[ -d "$SRC_DIR" ]] || die "源码目录不存在: $SRC_DIR"

log "补齐 autoconf-archive 宏 (源码未自带)"
mkdir -p "$SRC_DIR/m4"
for m in ax_pthread ax_recursive_eval; do
  curl -fsSL "${MACRO_BASE}/${m}.m4" -o "${SRC_DIR}/m4/${m}.m4"
done

# ---------- 4. 生成 configure ----------
log "autoreconf"
cd "$SRC_DIR"
autoreconf -fi

# ---------- 5. configure：同时开启 shared + static ----------
log "configure (shared + static)"
CONF_ARGS=(
  "--prefix=${PREFIX}"
  "--enable-shared"
  "--enable-static"
  "--disable-documentation"
  "--with-systemdsystemunitdir=no"
)
if [[ "$ENABLE_LIBUDEV" != "1" ]]; then
  CONF_ARGS+=("--disable-libudev")
fi
if [[ "$ENABLE_LIBSYSTEMD" != "1" ]]; then
  CONF_ARGS+=("--disable-libsystemd")
fi
if [[ "$ENABLE_POLKIT" != "1" ]]; then
  CONF_ARGS+=("--disable-polkit")
fi
./configure "${CONF_ARGS[@]}" CFLAGS="-O2 -g -fPIC"

# ---------- 6. 编译安装到 staging ----------
log "make -j${JOBS}"
make -j"${JOBS}"
make install DESTDIR="$WORK_ROOT/stage"

# ---------- 7. 整理产物 ----------
STAGE_ROOT="${WORK_ROOT}/stage${PREFIX}"
[[ -d "$STAGE_ROOT" ]] || die "安装目录不存在: $STAGE_ROOT"

log "整理产物到 ${DIST_DIR}"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/include" "$DIST_DIR/lib/pkgconfig" "$DIST_DIR/sbin"

cp -a "${STAGE_ROOT}/include/PCSC" "$DIST_DIR/include/"
# .la 含 staging 绝对路径，对外无用，排除
find "${STAGE_ROOT}/lib" -maxdepth 1 -name 'libpcsclite.*' ! -name '*.la' \
  -exec cp -a {} "$DIST_DIR/lib/" \;
if [[ -f "${STAGE_ROOT}/lib/pkgconfig/libpcsclite.pc" ]]; then
  cp -a "${STAGE_ROOT}/lib/pkgconfig/libpcsclite.pc" "$DIST_DIR/lib/pkgconfig/"
fi
if [[ -x "${STAGE_ROOT}/sbin/pcscd" ]]; then
  cp -a "${STAGE_ROOT}/sbin/pcscd" "$DIST_DIR/sbin/"
fi

# 硬性校验：动态库和静态库都必须存在
[[ -f "$DIST_DIR/lib/libpcsclite.a" ]] || die "静态库 libpcsclite.a 未生成"
[[ -f "$DIST_DIR/lib/libpcsclite.so" ]] || die "动态库 libpcsclite.so 未生成"

# ---------- 8. 校验信息 ----------
log "产物校验"
file "$DIST_DIR"/lib/libpcsclite.*
{
  echo "pcsc-lite ${VERSION} / CentOS 7 x86_64"
  echo "build date : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "configure  : ${CONF_ARGS[*]}"
  echo "features   : libudev=${ENABLE_LIBUDEV} libsystemd=${ENABLE_LIBSYSTEMD} polkit=${ENABLE_POLKIT}"
} > "$DIST_DIR/BUILD_INFO"
(
  cd "$DIST_DIR"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

# ---------- 9. 打包 ----------
ARCHIVE="${ARCHIVE_DIR}/pcsc-lite-${VERSION}-centos7-x86_64.tar.gz"
log "打包 ${ARCHIVE}"
tar -czf "$ARCHIVE" -C "$DIST_DIR" .
sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"

log "完成，产物清单："
find "$DIST_DIR" -maxdepth 3 -type f | sort
