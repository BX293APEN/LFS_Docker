#!/usr/bin/env bash
# =============================================================================
# lfs.sh  ―  Docker コンテナ内エントリーポイント
# 役割: LFS base → BLFS (X.org / Mesa / Qt6 / KDE Plasma / NetworkManager)
#       → tar.gz 出力
#
# 設定は .env を編集してください。スクリプト本体は変更不要です。
#
# 進捗確認 (別ターミナルで)：
#   docker logs -f Docker_LFS
# =============================================================================

set -eo pipefail

# ─────────────────────────────────────────────
# 環境変数 (.env → compose.yml → ここ)
# ─────────────────────────────────────────────
LFS_VERSION="${LFS_VERSION:-12.2}"
LFS_ARCH="${LFS_ARCH:-x86_64}"
LFS_TGT="${LFS_TGT:-x86_64-lfs-linux-gnu}"
LFS_MIRROR="${LFS_MIRROR:-https://www.linuxfromscratch.org/lfs/downloads}"
BLFS_MIRROR="${BLFS_MIRROR:-https://www.linuxfromscratch.org/blfs/downloads}"
CPU_CORE="${CPU_CORE:-4}"

LOCALE="${LOCALE:-ja_JP.UTF-8 UTF-8}"
LOCALE_NAME="${LANG:-ja_JP.UTF-8}"
TZ="${TZ:-Asia/Tokyo}"
ROOT_PASSWORD="${ROOT_PASSWORD:-password}"

WS="${WS:-build}"
LFS="/${WS}/lfs-rootfs"
OUTPUT_TAR="/${WS}/lfs-rootfs.tar.gz"
FLAG_DIR="/${WS}/FLAGS"
DONE_FLAG="${FLAG_DIR}/.build_done"

WGETLIST_URL="${LFS_MIRROR}/${LFS_VERSION}/wget-list-systemd"
MD5SUMS_URL="${LFS_MIRROR}/${LFS_VERSION}/md5sums"

echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') BLFS ビルド開始"
echo "  LFS バージョン: ${LFS_VERSION}"
echo "  アーキ        : ${LFS_ARCH} (${LFS_TGT})"
echo "  ロケール      : ${LOCALE_NAME}"
echo "  タイムゾーン  : ${TZ}"
echo "  並列数        : ${CPU_CORE}"
echo "  出力先        : ${OUTPUT_TAR}"
echo "  目標          : KDE Plasma + NetworkManager + sudo + nano"
echo "============================================"

if [[ -f "$DONE_FLAG" ]]; then
    echo "[INFO] ビルド済みフラグを検出。スキップします。"
    echo "  削除して再ビルドする場合: rm ${DONE_FLAG}"
    exit 0
fi

mkdir -p "${FLAG_DIR}"
chmod 777 -R "${FLAG_DIR}"

# =============================================================================
# 共通関数
# =============================================================================
flag()    { echo "${FLAG_DIR}/.${1}_done"; }
flagged() { [[ -f "$(flag "$1")" ]]; }
done_flag() { touch "$(flag "$1")"; }

log_step() { echo; echo "[====] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_skip() { echo "[SKIP] $* (済)"; }

mount_chroot() {
    mkdir -p "${LFS}"/{dev,proc,sys,run}
    mountpoint -q "${LFS}/proc" || mount --types proc  /proc "${LFS}/proc"
    mountpoint -q "${LFS}/sys"  || { mount --rbind /sys "${LFS}/sys";  mount --make-rslave "${LFS}/sys"; }
    mountpoint -q "${LFS}/dev"  || { mount --rbind /dev "${LFS}/dev";  mount --make-rslave "${LFS}/dev"; }
    mountpoint -q "${LFS}/run"  || mount --bind   /run "${LFS}/run"
}

umount_chroot() {
    umount -R "${LFS}/dev"  2>/dev/null || true
    umount -R "${LFS}/sys"  2>/dev/null || true
    umount    "${LFS}/run"  2>/dev/null || true
    umount    "${LFS}/proc" 2>/dev/null || true
}

cleanup() { umount_chroot; }
trap cleanup EXIT

# =============================================================================
# Step 1: FHS ディレクトリ構造
# =============================================================================
if ! flagged step1_dirs; then
    log_step "Step1: FHS ディレクトリ作成"
    mkdir -p "${LFS}"/{boot,dev,etc/{opt,sysconfig},home,lib/firmware,lib64,mnt,opt}
    mkdir -p "${LFS}"/{proc,root,run,srv,sys,tmp}
    mkdir -p "${LFS}/usr"/{,local/}{bin,include,lib,lib64,sbin,share,src}
    mkdir -p "${LFS}/usr/share"/{color,dict,doc,info,locale,man,misc,terminfo,zoneinfo}
    mkdir -p "${LFS}/var"/{cache,lib/{color,locate,misc},local,log,mail,mnt,opt,spool,tmp}
    ln -sfn usr/bin  "${LFS}/bin"
    ln -sfn usr/lib  "${LFS}/lib"
    ln -sfn usr/sbin "${LFS}/sbin"
    ln -sfn ../run   "${LFS}/var/run"
    ln -sfn ../run/lock "${LFS}/var/lock"
    chmod 1777 "${LFS}/tmp" "${LFS}/var/tmp"
    chmod 0750 "${LFS}/root"
    groupadd lfs 2>/dev/null || true
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true
    mkdir -p "${LFS}/tools" && chown lfs:lfs "${LFS}/tools"
    done_flag step1_dirs
    log_info "Step1 完了"
else
    log_skip "Step1"
fi

# =============================================================================
# Step 2: LFS ソースダウンロード
# =============================================================================
if ! flagged step2_sources; then
    log_step "Step2: LFS ソースダウンロード"
    mkdir -p "${LFS}/sources"
    chmod a+wt "${LFS}/sources"
    cd "${LFS}/sources"
    wget -qO wget-list "${WGETLIST_URL}" || { echo "[ERROR] wget-list 取得失敗: ${WGETLIST_URL}"; exit 1; }
    wget -qO md5sums   "${MD5SUMS_URL}"  || true
    wget --continue --input-file=wget-list \
         --directory-prefix="${LFS}/sources" \
         --no-clobber --timeout=60 --tries=3 \
         2>&1 | tee "/${WS}/download-lfs.log" || true
    [[ -f md5sums ]] && md5sum --quiet -c md5sums 2>/dev/null && log_info "MD5 OK" || true
    done_flag step2_sources
    log_info "Step2 完了"
else
    log_skip "Step2"
fi

# =============================================================================
# Step 3: クロスツールチェーン (lfs ユーザー)
# =============================================================================
if ! flagged step3_toolchain; then
    log_step "Step3: クロスツールチェーン ビルド"

    cat > /home/lfs/.bashrc << LFSRC
set +h
umask 022
LFS="${LFS}"
LC_ALL=POSIX
LFS_TGT="${LFS_TGT}"
PATH="${LFS}/tools/bin:/usr/bin:/bin"
CONFIG_SITE="${LFS}/usr/share/config.site"
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS="-j${CPU_CORE}"
LFSRC
    chown lfs:lfs /home/lfs/.bashrc

    cat > /tmp/build-toolchain.sh << 'TCEOF'
#!/bin/bash
set -eo pipefail
source ~/.bashrc

pkg_build() {
    local name="$1" tarball="$2" fn="$3"
    echo "[TC] $(date '+%H:%M:%S') ${name}"
    cd "${LFS}/sources"
    local dir; dir=$(tar -tf "${tarball}" | head -1 | cut -d/ -f1)
    tar -xf "${tarball}"
    cd "${dir}"
    ${fn}
    cd "${LFS}/sources"
    rm -rf "${dir}"
}

do_binutils_p1() {
    mkdir build && cd build
    ../configure --prefix="${LFS}/tools" --with-sysroot="${LFS}" \
        --target="${LFS_TGT}" --disable-nls --enable-gprofng=no \
        --disable-werror --enable-new-dtags --enable-default-hash-style=gnu
    make && make install
}

do_gcc_p1() {
    for dep in mpfr gmp mpc; do
        tar -xf ../${dep}-*.tar.*; mv ${dep}-* ${dep}
    done
    case $(uname -m) in x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;; esac
    mkdir build && cd build
    ../configure --target="${LFS_TGT}" --prefix="${LFS}/tools" \
        --with-glibc-version=2.40 --with-sysroot="${LFS}" --with-newlib \
        --without-headers --enable-default-pie --enable-default-ssp \
        --disable-nls --disable-shared --disable-multilib --disable-threads \
        --disable-libatomic --disable-libgomp --disable-libquadmath \
        --disable-libssp --disable-libvtv --disable-libstdcxx \
        --enable-languages=c,c++
    make && make install
    cd ..
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
        "$(dirname "$("${LFS_TGT}-gcc" -print-libgcc-file-name)")/include/limits.h"
}

do_linux_headers() {
    make mrproper && make headers
    find usr/include -type f ! -name '*.h' -delete
    cp -rv usr/include "${LFS}/usr"
}

do_glibc() {
    ln -sfnv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64"
    ln -sfnv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64/ld-lsb-x86-64.so.3"
    patch -Np1 -i "../$(ls ../glibc-*.patch 2>/dev/null | head -1)" 2>/dev/null || true
    mkdir build && cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(../scripts/config.guess)" --enable-kernel=4.19 \
        --with-headers="${LFS}/usr/include" --disable-nscd \
        libc_cv_slibdir=/usr/lib
    make && make DESTDIR="${LFS}" install
    sed '/RTLDLIST=/s@/usr@@g' -i "${LFS}/usr/bin/ldd"
}

do_libstdcpp() {
    mkdir build && cd build
    ../libstdc++-v3/configure --host="${LFS_TGT}" \
        --build="$(../config.guess)" --prefix=/usr \
        --disable-multilib --disable-nls --disable-libstdcxx-pch \
        --with-gxx-include-dir="/tools/${LFS_TGT}/include/c++/$(cat ../gcc/BASE-VER)"
    make && make DESTDIR="${LFS}" install
    rm -v "${LFS}/usr/lib/lib"{stdc++{,exp},supc++}.la 2>/dev/null || true
}

pkg_build "Binutils Pass1"    "$(ls ${LFS}/sources/binutils-*.tar.*)"  do_binutils_p1
pkg_build "GCC Pass1"         "$(ls ${LFS}/sources/gcc-*.tar.*)"       do_gcc_p1
pkg_build "Linux API Headers" "$(ls ${LFS}/sources/linux-*.tar.*)"     do_linux_headers
pkg_build "Glibc"             "$(ls ${LFS}/sources/glibc-*.tar.*)"     do_glibc
pkg_build "Libstdc++"         "$(ls ${LFS}/sources/gcc-*.tar.*)"       do_libstdcpp

echo "[TC] クロスツールチェーン完了"
TCEOF
    chmod +x /tmp/build-toolchain.sh
    su - lfs -c "bash /tmp/build-toolchain.sh" 2>&1 | tee "/${WS}/toolchain.log"
    done_flag step3_toolchain
    log_info "Step3 完了"
else
    log_skip "Step3"
fi

# =============================================================================
# Step 4: 一時ツール + LFS base システム (chroot)
# =============================================================================
if ! flagged step4_lfs_base; then
    log_step "Step4: LFS base システム chroot ビルド"
    mount_chroot
    cp /etc/resolv.conf "${LFS}/etc/resolv.conf"
    mountpoint -q "${LFS}/sources" || mount --bind "${LFS}/sources" "${LFS}/sources"

    cat > "${LFS}/tmp/build-base.sh" << 'BASEEOF'
#!/bin/bash
set -eo pipefail
export MAKEFLAGS="-j__CPU_CORE__"
export TERM=xterm-256color
SRC=/sources

build() {
    local name="$1" tarball="$2" fn="$3"
    echo "[BASE] $(date '+%H:%M:%S') ${name}"
    cd "${SRC}"
    local dir; dir=$(tar -tf "${tarball}" | head -1 | cut -d/ -f1)
    tar -xf "${tarball}"
    cd "${dir}"
    ${fn}
    cd "${SRC}"
    rm -rf "${dir}"
}

# ── 基本 /etc ファイル ──────────────────────────────────────
cat > /etc/hosts        << 'EOF'
127.0.0.1  localhost lfs
::1        localhost
EOF
cat > /etc/passwd       << 'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1::/dev/null:/usr/bin/false
daemon:x:6:6:Daemon:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus:/run/dbus:/usr/bin/false
systemd-journal:x:190:190:systemd Journal:/dev/null:/usr/bin/false
uuidd:x:80:80:UUID:/dev/null:/usr/bin/false
nobody:x:65534:65534:Nobody:/dev/null:/usr/bin/false
EOF
cat > /etc/group        << 'EOF'
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp utmp /var/log/lastlog
chmod 664   /var/log/lastlog
chmod 600   /var/log/btmp

# ── Man-pages ───────────────────────────────────────────────
do_manpages() { make prefix=/usr install; }
build "Man-pages" "$(ls ${SRC}/man-pages-*.tar.*)" do_manpages

# ── Iana-etc ────────────────────────────────────────────────
do_iana() { cp services protocols /etc/; }
build "Iana-etc" "$(ls ${SRC}/iana-etc-*.tar.*)" do_iana

# ── Glibc (final) ───────────────────────────────────────────
do_glibc_final() {
    patch -Np1 -i "../$(ls ../glibc-*.patch 2>/dev/null | head -1)" 2>/dev/null || true
    mkdir build && cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure --prefix=/usr --disable-werror \
        --enable-kernel=4.19 --enable-stack-protector=strong \
        --disable-nscd libc_cv_slibdir=/usr/lib
    make && make install
    sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
    # ロケール
    mkdir -p /usr/lib/locale
    localedef -i ja_JP -f UTF-8 ja_JP.UTF-8 2>/dev/null || true
    localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true
    # nsswitch.conf
    cat > /etc/nsswitch.conf << 'NSSEOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
NSSEOF
    # タイムゾーン
    tar -xf ../../tzdata*.tar.gz
    ZONEINFO=/usr/share/zoneinfo
    mkdir -pv ${ZONEINFO}/{posix,right}
    for tz in etcetera southamerica northamerica europe africa antarctica \
               asia australasia backward; do
        zic -L /dev/null -d ${ZONEINFO}       ${tz} 2>/dev/null || true
        zic -L /dev/null -d ${ZONEINFO}/posix ${tz} 2>/dev/null || true
        zic -L leapseconds -d ${ZONEINFO}/right ${tz} 2>/dev/null || true
    done
    cp zone.tab zone1970.tab iso3166.tab ${ZONEINFO}
    zic -d ${ZONEINFO} -p America/New_York 2>/dev/null || true
    ln -sfv /usr/share/zoneinfo/__TZ__ /etc/localtime
    # /etc/ld.so.conf
    cat > /etc/ld.so.conf << 'LDEOF'
/usr/local/lib
/opt/lib
LDEOF
}
build "Glibc-final" "$(ls ${SRC}/glibc-*.tar.*)" do_glibc_final

# ── Zlib ────────────────────────────────────────────────────
do_zlib() {
    ./configure --prefix=/usr
    make && make install
    rm -fv /usr/lib/libz.a
}
build "Zlib" "$(ls ${SRC}/zlib-*.tar.*)" do_zlib

# ── Bzip2 ───────────────────────────────────────────────────
do_bzip2() {
    patch -Np1 -i ../bzip2-*.patch 2>/dev/null || true
    sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
    sed -i "s|man, doc|share/man, share/doc|g" Makefile
    make -f Makefile-libbz2_so && make clean
    make && make PREFIX=/usr install
    cp -av libbz2.so.* /usr/lib
    ln -sv libbz2.so.1.0.8 /usr/lib/libbz2.so
    cp -v bzip2-shared /usr/bin/bzip2
    for i in /usr/bin/{bzcat,bunzip2}; do ln -sfv bzip2 ${i}; done
    rm -fv /usr/lib/libbz2.a
}
build "Bzip2" "$(ls ${SRC}/bzip2-*.tar.*)" do_bzip2

# ── Xz ──────────────────────────────────────────────────────
do_xz() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/xz-$(cat build-aux/m4/ax_require_defined.m4 | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "5.6")
    make && make install
}
build "Xz" "$(ls ${SRC}/xz-*.tar.*)" do_xz

# ── Lz4 ─────────────────────────────────────────────────────
do_lz4() {
    make BUILD_STATIC=no PREFIX=/usr && make BUILD_STATIC=no PREFIX=/usr install
}
build "Lz4" "$(ls ${SRC}/lz4-*.tar.*)" do_lz4

# ── Zstd ────────────────────────────────────────────────────
do_zstd() {
    make prefix=/usr && make prefix=/usr install
    rm -v /usr/lib/libzstd.a
}
build "Zstd" "$(ls ${SRC}/zstd-*.tar.*)" do_zstd

# ── File ────────────────────────────────────────────────────
do_file() {
    ./configure --prefix=/usr && make && make install
}
build "File" "$(ls ${SRC}/file-*.tar.*)" do_file

# ── Readline ────────────────────────────────────────────────
do_readline() {
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install
    sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf 2>/dev/null || true
    ./configure --prefix=/usr --disable-static \
        --with-curses --docdir=/usr/share/doc/readline-8.2
    make SHLIB_LIBS="-lncursesw"
    make SHLIB_LIBS="-lncursesw" install
}
build "Readline" "$(ls ${SRC}/readline-*.tar.*)" do_readline

# ── M4 ──────────────────────────────────────────────────────
do_m4() {
    ./configure --prefix=/usr && make && make install
}
build "M4" "$(ls ${SRC}/m4-*.tar.*)" do_m4

# ── Bc ──────────────────────────────────────────────────────
do_bc() {
    CC=gcc ./configure --prefix=/usr -G -O3 -r && make && make install
}
build "Bc" "$(ls ${SRC}/bc-*.tar.*)" do_bc

# ── Flex ────────────────────────────────────────────────────
do_flex() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/flex-2.6.4 --disable-static
    make && make install
    ln -sv flex /usr/bin/lex
    ln -sv flex.1 /usr/share/man/man1/lex.1
}
build "Flex" "$(ls ${SRC}/flex-*.tar.*)" do_flex

# ── Tcl ─────────────────────────────────────────────────────
do_tcl() {
    SRCDIR=$(pwd)
    cd unix
    ./configure --prefix=/usr --mandir=/usr/share/man
    make
    sed -e "s|$SRCDIR/unix|/usr/lib|" \
        -e "s|$SRCDIR|/usr/include|" \
        -i tclConfig.sh
    sed -e "s|$SRCDIR/unix/pkgs/tdbc1.1.7|/usr/lib/tdbc1.1.7|" \
        -e "s|$SRCDIR/pkgs/tdbc1.1.7/generic||" \
        -e "s|$SRCDIR/pkgs/tdbc1.1.7/library||" \
        -e "s|$SRCDIR/pkgs/tdbc1.1.7|/usr/include|" \
        -i pkgs/tdbc1.1.7/tdbcConfig.sh
    make install
    chmod -v u+w /usr/lib/libtcl8.6.so 2>/dev/null || true
    make install-private-headers
    ln -sfv tclsh8.6 /usr/bin/tclsh
    mv /usr/share/man/man3/{Thread,Tcl_Thread}.3 2>/dev/null || true
}
build "Tcl" "$(ls ${SRC}/tcl*-src.tar.*)" do_tcl

# ── Expect ──────────────────────────────────────────────────
do_expect() {
    ./configure --prefix=/usr --with-tcl=/usr/lib \
        --enable-shared --disable-rpath \
        --mandir=/usr/share/man --with-tclinclude=/usr/include
    make && make install
    ln -svf expect5.45.4/libexpect5.45.4.so /usr/lib/libexpect5.45.4.so 2>/dev/null || true
}
build "Expect" "$(ls ${SRC}/expect*.tar.*)" do_expect

# ── DejaGNU ─────────────────────────────────────────────────
do_dejagnu() {
    mkdir build && cd build
    ../configure --prefix=/usr && makeinfo --plaintext -o doc/dejagnu.txt ../doc/dejagnu.texi 2>/dev/null || true
    make install
}
build "DejaGNU" "$(ls ${SRC}/dejagnu-*.tar.*)" do_dejagnu

# ── Pkgconf ─────────────────────────────────────────────────
do_pkgconf() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/pkgconf-2.3.0
    make && make install
    ln -sv pkgconf /usr/bin/pkg-config
    ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
}
build "Pkgconf" "$(ls ${SRC}/pkgconf-*.tar.*)" do_pkgconf

# ── Binutils (final) ────────────────────────────────────────
do_binutils_final() {
    mkdir build && cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
        --enable-gold --enable-ld=default --enable-plugins \
        --enable-shared --disable-werror --enable-64-bit-bfd \
        --enable-new-dtags --enable-default-hash-style=gnu \
        --with-system-zlib --enable-install-libiberty
    make tooldir=/usr && make tooldir=/usr install
    rm -fv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a
}
build "Binutils-final" "$(ls ${SRC}/binutils-*.tar.*)" do_binutils_final

# ── GMP ─────────────────────────────────────────────────────
do_gmp() {
    ./configure --prefix=/usr --enable-cxx --disable-static \
        --docdir=/usr/share/doc/gmp-6.3.0
    make && make install
}
build "GMP" "$(ls ${SRC}/gmp-*.tar.*)" do_gmp

# ── MPFR ────────────────────────────────────────────────────
do_mpfr() {
    ./configure --prefix=/usr --disable-static \
        --enable-thread-safe --docdir=/usr/share/doc/mpfr-4.2.1
    make && make install
}
build "MPFR" "$(ls ${SRC}/mpfr-*.tar.*)" do_mpfr

# ── MPC ─────────────────────────────────────────────────────
do_mpc() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/mpc-1.3.1
    make && make install
}
build "MPC" "$(ls ${SRC}/mpc-*.tar.*)" do_mpc

# ── Attr ────────────────────────────────────────────────────
do_attr() {
    ./configure --prefix=/usr --disable-static --sysconfdir=/etc \
        --docdir=/usr/share/doc/attr-2.5.2
    make && make install
}
build "Attr" "$(ls ${SRC}/attr-*.tar.*)" do_attr

# ── Acl ─────────────────────────────────────────────────────
do_acl() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/acl-2.3.2
    make && make install
}
build "Acl" "$(ls ${SRC}/acl-*.tar.*)" do_acl

# ── Libcap ──────────────────────────────────────────────────
do_libcap() {
    sed -i '/install -m.*STA/d' libcap/Makefile
    make prefix=/usr lib=lib && make prefix=/usr lib=lib install
}
build "Libcap" "$(ls ${SRC}/libcap-*.tar.*)" do_libcap

# ── Libxcrypt ───────────────────────────────────────────────
do_libxcrypt() {
    ./configure --prefix=/usr --enable-hashes=strong,glibc \
        --enable-obsolete-api=no --disable-static \
        --disable-failure-tokens
    make && make install
}
build "Libxcrypt" "$(ls ${SRC}/libxcrypt-*.tar.*)" do_libxcrypt

# ── Shadow ──────────────────────────────────────────────────
do_shadow() {
    sed -i 's/groups$(EXEEXT) //' src/Makefile.in
    find man -name Makefile.in -exec sed -i 's/groups\.1 / /'   {} \;
    find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
    find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;
    sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' \
        -e 's:/var/spool/mail:/var/mail:'                   \
        -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                  \
        -i etc/login.defs
    touch /usr/bin/passwd
    ./configure --sysconfdir=/etc --disable-static \
        --with-{b,yes}crypt --without-libbsd \
        --with-group-name-max-length=32
    make && make exec_prefix=/usr install
    make -C man install-man
    pwconv && grpconv
    mkdir -p /etc/default
    useradd -D --gid 999
    sed -i '/MAIL/s/yes/no/' /etc/default/useradd
}
build "Shadow" "$(ls ${SRC}/shadow-*.tar.*)" do_shadow

# ── GCC (final) ─────────────────────────────────────────────
do_gcc_final() {
    case $(uname -m) in x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;; esac
    mkdir build && cd build
    ../configure --prefix=/usr --enable-languages=c,c++ \
        --enable-default-pie --enable-default-ssp \
        --enable-host-pie --disable-multilib \
        --disable-bootstrap --disable-fixincludes \
        --with-system-zlib
    make && make install
    chown -v -R root:root /usr/lib/gcc/$(gcc -dumpmachine)/*/include{,-fixed}
    ln -svr /usr/bin/cpp /usr/lib
    ln -sv gcc.1 /usr/share/man/man1/cc.1
    ln -sfv ../../libexec/gcc/$(gcc -dumpmachine)/*/liblto_plugin.so \
        /usr/lib/bfd-plugins/
    mkdir -pv /usr/share/gdb/auto-load/usr/lib
    mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib 2>/dev/null || true
}
build "GCC-final" "$(ls ${SRC}/gcc-*.tar.*)" do_gcc_final

# ── Ncurses ─────────────────────────────────────────────────
do_ncurses() {
    ./configure --prefix=/usr --mandir=/usr/share/man \
        --with-shared --without-debug --without-normal \
        --with-cxx-shared --enable-pc-files \
        --with-pkg-config-libdir=/usr/lib/pkgconfig \
        --enable-widec --with-versioned-syms
    make && make install
    for lib in ncurses form panel menu; do
        ln -sfv lib${lib}w.so /usr/lib/lib${lib}.so
        ln -sfv ${lib}w.pc    /usr/lib/pkgconfig/${lib}.pc
    done
    ln -sfv libncursesw.so /usr/lib/libcurses.so
}
build "Ncurses" "$(ls ${SRC}/ncurses-*.tar.*)" do_ncurses

# ── Sed ─────────────────────────────────────────────────────
do_sed() { ./configure --prefix=/usr && make && make install; }
build "Sed" "$(ls ${SRC}/sed-*.tar.*)" do_sed

# ── Psmisc ──────────────────────────────────────────────────
do_psmisc() { ./configure --prefix=/usr && make && make install; }
build "Psmisc" "$(ls ${SRC}/psmisc-*.tar.*)" do_psmisc

# ── Gettext ─────────────────────────────────────────────────
do_gettext() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/gettext-0.22.5
    make && make install
    chmod -v 0755 /usr/lib/preloadable_libintl.so 2>/dev/null || true
}
build "Gettext" "$(ls ${SRC}/gettext-*.tar.*)" do_gettext

# ── Bison ───────────────────────────────────────────────────
do_bison() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
    make && make install
}
build "Bison" "$(ls ${SRC}/bison-*.tar.*)" do_bison

# ── Grep ────────────────────────────────────────────────────
do_grep() { ./configure --prefix=/usr && make && make install; }
build "Grep" "$(ls ${SRC}/grep-*.tar.*)" do_grep

# ── Bash ────────────────────────────────────────────────────
do_bash() {
    ./configure --prefix=/usr --without-bash-malloc \
        --with-installed-readline \
        --docdir=/usr/share/doc/bash-5.2.37
    make && make install
    ln -sfv bash /usr/bin/sh
}
build "Bash" "$(ls ${SRC}/bash-*.tar.*)" do_bash

# ── Libtool ─────────────────────────────────────────────────
do_libtool() {
    ./configure --prefix=/usr && make && make install
    rm -fv /usr/lib/libltdl.a
}
build "Libtool" "$(ls ${SRC}/libtool-*.tar.*)" do_libtool

# ── GDBM ────────────────────────────────────────────────────
do_gdbm() {
    ./configure --prefix=/usr --disable-static --enable-libgdbm-compat
    make && make install
}
build "GDBM" "$(ls ${SRC}/gdbm-*.tar.*)" do_gdbm

# ── Gperf ───────────────────────────────────────────────────
do_gperf() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/gperf-3.1
    make && make install
}
build "Gperf" "$(ls ${SRC}/gperf-*.tar.*)" do_gperf

# ── Expat ───────────────────────────────────────────────────
do_expat() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/expat-2.6.4
    make && make install
}
build "Expat" "$(ls ${SRC}/expat-*.tar.*)" do_expat

# ── Inetutils ───────────────────────────────────────────────
do_inetutils() {
    ./configure --prefix=/usr --bindir=/usr/bin \
        --localstatedir=/var --disable-logger \
        --disable-whois --disable-rcp --disable-rexec \
        --disable-rlogin --disable-rsh --disable-servers
    make && make install
    mv -v /usr/{,s}bin/ifconfig 2>/dev/null || true
}
build "Inetutils" "$(ls ${SRC}/inetutils-*.tar.*)" do_inetutils

# ── Less ─────────────────────────────────────────────────────
do_less() { ./configure --prefix=/usr --sysconfdir=/etc && make && make install; }
build "Less" "$(ls ${SRC}/less-*.tar.*)" do_less

# ── Perl ────────────────────────────────────────────────────
do_perl() {
    sh Configure -des                              \
        -D prefix=/usr                             \
        -D vendorprefix=/usr                       \
        -D privlib=/usr/lib/perl5/5.40/core_perl   \
        -D archlib=/usr/lib/perl5/5.40/core_perl   \
        -D sitelib=/usr/lib/perl5/5.40/site_perl   \
        -D sitearch=/usr/lib/perl5/5.40/site_perl  \
        -D vendorlib=/usr/lib/perl5/5.40/vendor_perl \
        -D vendorarch=/usr/lib/perl5/5.40/vendor_perl \
        -D man1dir=/usr/share/man/man1             \
        -D man3dir=/usr/share/man/man3             \
        -D pager="/usr/bin/less -isR"              \
        -D useshrplib                              \
        -D usethreads
    make && make install
}
build "Perl" "$(ls ${SRC}/perl-*.tar.*)" do_perl

# ── XML::Parser ─────────────────────────────────────────────
do_xml_parser() {
    perl Makefile.PL && make && make install
}
build "XML::Parser" "$(ls ${SRC}/XML-Parser-*.tar.*)" do_xml_parser

# ── Intltool ────────────────────────────────────────────────
do_intltool() {
    sed -i 's:\\\${:\\\$\\{:' intltool-update.in
    ./configure --prefix=/usr && make && make install
}
build "Intltool" "$(ls ${SRC}/intltool-*.tar.*)" do_intltool

# ── Autoconf ────────────────────────────────────────────────
do_autoconf() { ./configure --prefix=/usr && make && make install; }
build "Autoconf" "$(ls ${SRC}/autoconf-*.tar.*)" do_autoconf

# ── Automake ────────────────────────────────────────────────
do_automake() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/automake-1.17
    make && make install
}
build "Automake" "$(ls ${SRC}/automake-*.tar.*)" do_automake

# ── OpenSSL ─────────────────────────────────────────────────
do_openssl() {
    ./config --prefix=/usr --openssldir=/etc/ssl \
        --libdir=lib shared zlib-dynamic
    make && sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile
    make MANSUFFIX=ssl install
    mv -v /usr/share/doc/openssl /usr/share/doc/openssl-3.4.0 2>/dev/null || true
}
build "OpenSSL" "$(ls ${SRC}/openssl-*.tar.*)" do_openssl

# ── Kmod ────────────────────────────────────────────────────
do_kmod() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --with-openssl --with-xz --with-zstd --with-zlib \
        --disable-manpages
    make && make install
    for target in depmod insmod modinfo modprobe rmmod; do
        ln -sfv ../bin/kmod /usr/sbin/${target}
    done
    ln -sfv kmod /usr/bin/lsmod
}
build "Kmod" "$(ls ${SRC}/kmod-*.tar.*)" do_kmod

# ── Libelf (elfutils) ───────────────────────────────────────
do_libelf() {
    ./configure --prefix=/usr --disable-debuginfod --enable-libdebuginfod=dummy
    make && make -C libelf install
    install -vm644 config/libelf.pc /usr/lib/pkgconfig
    rm /usr/lib/libelf.a
}
build "Libelf" "$(ls ${SRC}/elfutils-*.tar.*)" do_libelf

# ── Libffi ──────────────────────────────────────────────────
do_libffi() {
    ./configure --prefix=/usr --disable-static --with-gcc-arch=native
    make && make install
}
build "Libffi" "$(ls ${SRC}/libffi-*.tar.*)" do_libffi

# ── Python ──────────────────────────────────────────────────
do_python() {
    ./configure --prefix=/usr --enable-shared \
        --with-system-expat --enable-optimizations
    make && make install
    cat > /usr/lib/python3.13/EXTERNALLY-MANAGED << 'EOF'
[externally-managed]
Error=This Python is part of LFS/BLFS.
EOF
    ln -sfv python3 /usr/bin/python
}
build "Python" "$(ls ${SRC}/Python-*.tar.*)" do_python

# ── Flit-core ───────────────────────────────────────────────
do_flit() { pip3 install --no-build-isolation --no-index . 2>/dev/null || python3 setup.py install; }
build "Flit-core" "$(ls ${SRC}/flit_core-*.tar.*)" do_flit 2>/dev/null || true

# ── Wheel / Setuptools ──────────────────────────────────────
for pkg in wheel setuptools; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] && { cd ${SRC}; dir=$(tar -tf "$f" | head -1 | cut -d/ -f1); tar -xf "$f"; cd "$dir"; pip3 install --no-build-isolation . 2>/dev/null || python3 setup.py install 2>/dev/null || true; cd ${SRC}; rm -rf "$dir"; } || true
done

# ── Ninja ───────────────────────────────────────────────────
do_ninja() {
    python3 configure.py --bootstrap
    install -vm755 ninja /usr/bin/
    install -vDm644 misc/bash-completion /usr/share/bash-completion/completions/ninja
}
build "Ninja" "$(ls ${SRC}/ninja-*.tar.*)" do_ninja

# ── Meson ───────────────────────────────────────────────────
do_meson() {
    pip3 install --no-build-isolation --no-index . 2>/dev/null || \
    python3 setup.py install --optimize=1
}
build "Meson" "$(ls ${SRC}/meson-*.tar.*)" do_meson

# ── Coreutils ───────────────────────────────────────────────
do_coreutils() {
    patch -Np1 -i ../coreutils-*.patch 2>/dev/null || true
    autoreconf -fiv 2>/dev/null || true
    FORCE_UNSAFE_CONFIGURE=1 ./configure \
        --prefix=/usr --enable-no-install-program=kill,uptime
    make && make install
    mv -v /usr/bin/chroot /usr/sbin
    mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8 2>/dev/null || true
    sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8 2>/dev/null || true
}
build "Coreutils" "$(ls ${SRC}/coreutils-*.tar.*)" do_coreutils

# ── Diffutils / Findutils / Gawk / Tar ──────────────────────
for pkg in diffutils findutils gawk tar; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" | head -1 | cut -d/ -f1)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    ./configure --prefix=/usr && make && make install
    cd ${SRC} && rm -rf "$dir"
done

# ── Grep / Gzip / Patch ─────────────────────────────────────
for pkg in grep gzip patch; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" | head -1 | cut -d/ -f1)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    ./configure --prefix=/usr && make && make install
    cd ${SRC} && rm -rf "$dir"
done

# ── Make ────────────────────────────────────────────────────
do_make() { ./configure --prefix=/usr && make && make install; }
build "Make" "$(ls ${SRC}/make-*.tar.*)" do_make

# ── Patch / Which / Texinfo ─────────────────────────────────
for pkg in which texinfo; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" | head -1 | cut -d/ -f1)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    ./configure --prefix=/usr && make && make install
    cd ${SRC} && rm -rf "$dir"
done

# ── Vim ─────────────────────────────────────────────────────
do_vim() {
    echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
    ./configure --prefix=/usr
    make && make install
    ln -sv vim /usr/bin/vi
    cat > /etc/vimrc << 'VIMEOF'
set nocompatible
set backspace=2
set mouse-=a
syntax on
set ruler
VIMEOF
}
build "Vim" "$(ls ${SRC}/vim-*.tar.*)" do_vim

# ── MarkupSafe / Jinja2 ─────────────────────────────────────
for pkg in MarkupSafe Jinja2; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" | head -1 | cut -d/ -f1)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    pip3 install --no-build-isolation --no-index . 2>/dev/null || python3 setup.py install
    cd ${SRC} && rm -rf "$dir"
done

# ── Udev (systemd) ──────────────────────────────────────────
do_udev() {
    sed -i -e 's/GROUP="render"/GROUP="video"/' \
           -e 's/GROUP="sgx", //' rules.d/50-udev-default.rules.in
    sed -i -e '/systemd-sysctl/s/^/#/' rules.d/99-systemd.rules.in
    sed -i -e "s|'install_sysconfdir_samples': True|'install_sysconfdir_samples': False|" \
        meson.build 2>/dev/null || true
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D mode=release -D dev-kvm-mode=0660 \
        -D link-udev-shared=false -D logind=false \
        -D vconsole=false -D firstboot=false \
        -D randomseed=false -D backlight=false \
        -D rfkill=false -D xdg-utils=false \
        -D tmpfiles=false -D sysusers=false \
        -D hibernate=false -D ldconfig=false \
        -D resolve=false -D coredump=false \
        -D pkgconfig-path=/usr/lib/pkgconfig \
        -D install-tests=false
    ninja udevadm systemd-hwdb udev:{rules,hwdb}_update
    DESTDIR=/ ninja install-udevd install-udevadm \
        install-udev_rules install-udev_hwdb 2>/dev/null || ninja install
    tar -xf ../../udev-lfs-*.tar.xz 2>/dev/null || true
    make -f udev-lfs-*/Makefile.lfs install 2>/dev/null || true
    udevadm hwdb --update 2>/dev/null || true
}
build "Udev(systemd)" "$(ls ${SRC}/systemd-*.tar.*)" do_udev

# ── Man-DB ──────────────────────────────────────────────────
do_mandb() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/man-db-2.13.0 \
        --sysconfdir=/etc --disable-setuid \
        --enable-cache-owner=bin \
        --with-browser=/usr/bin/lynx \
        --with-vgrind=/usr/bin/vgrind \
        --with-grap=/usr/bin/grap \
        --with-systemdtmpfilesdir= --with-systemdsystemunitdir=
    make && make install
}
build "Man-DB" "$(ls ${SRC}/man-db-*.tar.*)" do_mandb

# ── Procps-ng ───────────────────────────────────────────────
do_procps() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/procps-ng-4.0.4 \
        --disable-static --disable-kill \
        --with-systemd
    make && make install
}
build "Procps-ng" "$(ls ${SRC}/procps-ng-*.tar.*)" do_procps

# ── Util-linux ──────────────────────────────────────────────
do_utillinux() {
    mkdir -pv /var/lib/hwclock
    ./configure --bindir=/usr/bin --libdir=/usr/lib \
        --runstatedir=/run --sbindir=/usr/sbin \
        --disable-chfn-chsh --disable-login \
        --disable-nologin --disable-su \
        --disable-setpriv --disable-runuser \
        --disable-pylibmount --disable-static \
        --disable-liblastlog2 --without-python \
        --without-systemd --without-systemdsystemunitdir \
        ADJTIME_PATH=/var/lib/hwclock/adjtime \
        --docdir=/usr/share/doc/util-linux-2.40.2
    make && make install
}
build "Util-linux" "$(ls ${SRC}/util-linux-*.tar.*)" do_utillinux

# ── E2fsprogs ───────────────────────────────────────────────
do_e2fsprogs() {
    mkdir build && cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
        --enable-elf-shlibs --disable-libblkid \
        --disable-libuuid --disable-uuidd --disable-fsck
    make && make install
    rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
}
build "E2fsprogs" "$(ls ${SRC}/e2fsprogs-*.tar.*)" do_e2fsprogs

# ── SysVinit ────────────────────────────────────────────────
do_sysvinit() {
    patch -Np1 -i ../sysvinit-*.patch 2>/dev/null || true
    make && make install
}
build "SysVinit" "$(ls ${SRC}/sysvinit-*.tar.*)" do_sysvinit

echo ""
echo "[BASE] LFS base システムビルド完了"
BASEEOF

    sed -i \
        -e "s|__CPU_CORE__|${CPU_CORE}|g" \
        -e "s|__TZ__|${TZ}|g" \
        "${LFS}/tmp/build-base.sh"
    chmod +x "${LFS}/tmp/build-base.sh"

    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root TERM="${TERM}" \
        PS1='(lfs) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j${CPU_CORE}" \
        /bin/bash /tmp/build-base.sh \
        2>&1 | tee "/${WS}/lfs-base.log"

    umount "${LFS}/sources" 2>/dev/null || true
    done_flag step4_lfs_base
    log_info "Step4 完了"
else
    log_skip "Step4"
fi

# =============================================================================
# Step 5: BLFS ソース追加ダウンロード
# =============================================================================
if ! flagged step5_blfs_sources; then
    log_step "Step5: BLFS ソース追加ダウンロード"
    mkdir -p "${LFS}/sources"
    cd "${LFS}/sources"

    # BLFS Book に対応するパッケージ群を直接 URL 指定でダウンロード
    # (BLFS は LFS のような統一 wget-list がないため個別に取得)
    BLFS_PKGS=(
        # ── sudo ──
        "https://www.sudo.ws/dist/sudo-1.9.15p5.tar.gz"
        # ── nano ──
        "https://www.nano-editor.org/dist/v8/nano-8.3.tar.xz"
        # ── D-Bus ──
        "https://dbus.freedesktop.org/releases/dbus/dbus-1.15.8.tar.xz"
        # ── libgpg-error / libgcrypt / libassuan / npth / gnupg ──
        "https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.50.tar.bz2"
        "https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2"
        "https://www.gnupg.org/ftp/gcrypt/libassuan/libassuan-3.0.0.tar.bz2"
        "https://www.gnupg.org/ftp/gcrypt/npth/npth-1.8.tar.bz2"
        # ── polkit (KDE 必須) ──
        "https://gitlab.freedesktop.org/polkit/polkit/-/archive/125/polkit-125.tar.bz2"
        # ── libxml2 / libxslt ──
        "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz"
        "https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.42.tar.xz"
        # ── ICU ──
        "https://github.com/unicode-org/icu/releases/download/release-75-1/icu4c-75_1-src.tgz"
        # ── Boost ──
        "https://github.com/boostorg/boost/releases/download/boost-1.86.0/boost-1.86.0-cmake.tar.xz"
        # ── SQLite ──
        "https://sqlite.org/2024/sqlite-autoconf-3470200.tar.gz"
        # ── libtasn1 / p11-kit / make-ca ──
        "https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.19.0.tar.gz"
        "https://github.com/p11-glue/p11-kit/releases/download/0.25.5/p11-kit-0.25.5.tar.xz"
        "https://github.com/lcp/make-ca/archive/v1.14/make-ca-1.14.tar.gz"
        # ── GLib2 ──
        "https://download.gnome.org/sources/glib/2.82/glib-2.82.4.tar.xz"
        # ── dconf ──
        "https://download.gnome.org/sources/dconf/0.40/dconf-0.40.0.tar.xz"
        # ── Wayland / Wayland-protocols ──
        "https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.23.1/downloads/wayland-1.23.1.tar.xz"
        "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.38/downloads/wayland-protocols-1.38.tar.xz"
        # ── libdrm ──
        "https://dri.freedesktop.org/libdrm/libdrm-2.4.123.tar.xz"
        # ── Mesa ──
        "https://archive.mesa3d.org/mesa-24.3.4.tar.xz"
        # ── libpng / libjpeg / libwebp / libtiff / FreeType2 ──
        "https://downloads.sourceforge.net/libpng/libpng-1.6.45.tar.xz"
        "https://www.ijg.org/files/jpegsrc.v9f.tar.gz"
        "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz"
        "https://download.osgeo.org/libtiff/tiff-4.7.0.tar.gz"
        "https://downloads.sourceforge.net/freetype/freetype-2.13.3.tar.xz"
        "https://downloads.sourceforge.net/freetype/freetype-doc-2.13.3.tar.xz"
        "https://downloads.sourceforge.net/freetype/ft2demos-2.13.3.tar.xz"
        # ── Fontconfig ──
        "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.gz"
        # ── Pixman ──
        "https://www.cairographics.org/releases/pixman-0.43.4.tar.gz"
        # ── Cairo / HarfBuzz / Pango ──
        "https://www.cairographics.org/releases/cairo-1.18.2.tar.xz"
        "https://github.com/harfbuzz/harfbuzz/releases/download/10.2.0/harfbuzz-10.2.0.tar.xz"
        "https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz"
        # ── ATK / at-spi2-core ──
        "https://download.gnome.org/sources/atk/2.38/atk-2.38.0.tar.xz"
        "https://download.gnome.org/sources/at-spi2-core/2.54/at-spi2-core-2.54.1.tar.xz"
        # ── GDK-Pixbuf / GTK ──
        "https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz"
        "https://download.gnome.org/sources/gtk+/3.24/gtk+-3.24.43.tar.xz"
        # ── X.org (Xwayland) 依存 ──
        "https://xorg.freedesktop.org/archive/individual/proto/xorgproto-2024.1.tar.xz"
        "https://xcb.freedesktop.org/dist/xcb-proto-1.17.0.tar.xz"
        "https://xcb.freedesktop.org/dist/libxcb-1.17.0.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libX11-1.8.10.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXext-1.3.6.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXrender-0.9.12.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXrandr-1.5.4.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXi-1.8.2.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXfixes-6.0.1.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXcursor-1.2.3.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXinerama-1.1.5.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXcomposite-0.4.6.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libXdamage-1.1.6.tar.xz"
        "https://xorg.freedesktop.org/archive/individual/lib/libxkbcommon-1.7.0.tar.xz"
        # ── libinput ──
        "https://gitlab.freedesktop.org/libinput/libinput/-/releases/1.26.2/downloads/libinput-1.26.2.tar.xz"
        # ── NetworkManager 依存 ──
        "https://networkmanager.dev/tar/NetworkManager/NetworkManager-1.48.10.tar.xz"
        "https://github.com/nicowillis/mobile-broadband-provider-info/archive/20240727/mobile-broadband-provider-info-20240727.tar.gz"
        # ── Qt6 ──
        "https://download.qt.io/official_releases/qt/6.8/6.8.1/single/qt-everywhere-src-6.8.1.tar.xz"
        # ── KDE Framework (plasma-desktop-minimal) ──
        "https://download.kde.org/stable/plasma/6.2.5/plasma-desktop-6.2.5.tar.xz"
        "https://download.kde.org/stable/plasma/6.2.5/plasma-workspace-6.2.5.tar.xz"
        "https://download.kde.org/stable/plasma/6.2.5/kwin-6.2.5.tar.xz"
        "https://download.kde.org/stable/plasma/6.2.5/plasma-nm-6.2.5.tar.xz"
        # ── SDDM (ディスプレイマネージャー) ──
        "https://github.com/sddm/sddm/releases/download/v0.21.0/sddm-0.21.0.tar.xz"
        # ── Konsole ──
        "https://download.kde.org/stable/release-service/24.12.1/src/konsole-24.12.1.tar.xz"
        # ── Extra-cmake-modules (KDE ビルドに必須) ──
        "https://download.kde.org/stable/frameworks/6.9/extra-cmake-modules-6.9.0.tar.xz"
        # ── KDE Frameworks (最小セット) ──
        "https://download.kde.org/stable/frameworks/6.9/ki18n-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kconfig-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kcoreaddons-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kwidgetsaddons-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kwindowsystem-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/solid-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kauth-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kcrash-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kjobwidgets-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kservice-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kio-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/kiconthemes-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/knotifications-6.9.0.tar.xz"
        "https://download.kde.org/stable/frameworks/6.9/plasma-framework-6.9.0.tar.xz"
    )

    log_info "BLFS パッケージのダウンロード中... (数十分かかります)"
    for url in "${BLFS_PKGS[@]}"; do
        fname=$(basename "$url")
        if [[ -f "${fname}" ]]; then
            echo "  [CACHED] ${fname}"
        else
            echo "  [DL] ${fname}"
            wget -q --timeout=120 --tries=3 "${url}" -O "${fname}.tmp" \
                && mv "${fname}.tmp" "${fname}" \
                || { echo "  [WARN] ダウンロード失敗: ${url}"; rm -f "${fname}.tmp"; }
        fi
    done

    # CMake (BLFS ビルドに必須)
    CMAKE_VER="3.31.4"
    CMAKE_URL="https://cmake.org/files/v${CMAKE_VER%.*}/cmake-${CMAKE_VER}.tar.gz"
    fname="cmake-${CMAKE_VER}.tar.gz"
    [[ -f "$fname" ]] || wget -q --tries=3 "${CMAKE_URL}" -O "$fname" || true

    done_flag step5_blfs_sources
    log_info "Step5 完了"
else
    log_skip "Step5"
fi

# =============================================================================
# Step 6: BLFS ビルド (chroot 内)
# =============================================================================
if ! flagged step6_blfs; then
    log_step "Step6: BLFS ビルド (sudo / nano / NetworkManager / KDE Plasma)"
    mount_chroot
    cp /etc/resolv.conf "${LFS}/etc/resolv.conf"
    mountpoint -q "${LFS}/sources" || mount --bind "${LFS}/sources" "${LFS}/sources"

    cat > "${LFS}/tmp/build-blfs.sh" << 'BLFSEOF'
#!/bin/bash
set -eo pipefail
export MAKEFLAGS="-j__CPU_CORE__"
export TERM=xterm-256color
export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig"
SRC=/sources

build() {
    local name="$1" tarball="$2" fn="$3"
    [[ -f "${SRC}/${tarball}" ]] || { echo "[SKIP] ${name}: tarball なし"; return 0; }
    echo "[BLFS] $(date '+%H:%M:%S') ${name}"
    cd "${SRC}"
    local dir; dir=$(tar -tf "${tarball}" | head -1 | cut -d/ -f1)
    tar -xf "${tarball}"
    cd "${dir}"
    ${fn} || echo "[WARN] ${name} でエラーが発生しましたが続行します"
    cd "${SRC}"
    rm -rf "${dir}"
}

cmake_build() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          "$@" ..
    make && make install
}

# ── CMake ────────────────────────────────────────────────────
do_cmake() {
    sed -i '/"lib64"/s/64//' Modules/GNUInstallDirs.cmake
    ./bootstrap --prefix=/usr --system-libs \
        --mandir=/share/man --no-system-jsoncpp \
        --no-system-cppdap --no-system-librhash \
        --docdir=/share/doc/cmake-3.31.4 -- -DCMAKE_USE_OPENSSL=ON
    make && make install
}
build "CMake" "cmake-3.31.4.tar.gz" do_cmake

# ── sudo ─────────────────────────────────────────────────────
do_sudo() {
    ./configure --prefix=/usr --libexecdir=/usr/lib \
        --with-secure-path --with-all-insults \
        --with-env-editor --docdir=/usr/share/doc/sudo-1.9.15p5 \
        --with-passprompt="[sudo] %u のパスワード: "
    make && make install
    # wheel グループに sudo 権限付与
    cat > /etc/sudoers.d/wheel << 'SUDOEOF'
%wheel ALL=(ALL:ALL) ALL
SUDOEOF
    chmod 440 /etc/sudoers.d/wheel
}
build "sudo" "sudo-1.9.15p5.tar.gz" do_sudo

# ── nano ─────────────────────────────────────────────────────
do_nano() {
    ./configure --prefix=/usr \
        --sysconfdir=/etc     \
        --enable-utf8         \
        --docdir=/usr/share/doc/nano-8.3
    make && make install
    install -v -m644 doc/sample.nanorc /etc/nanorc
    cat > /etc/nanorc << 'NANOEOF'
set autoindent
set constantshow
set fill 72
set historylog
set mouse
set nohelp
set positionlog
set quickblank
set regexp
include "/usr/share/nano/*.nanorc"
NANOEOF
}
build "nano" "nano-8.3.tar.xz" do_nano

# ── libgpg-error ─────────────────────────────────────────────
do_libgpgerror() {
    ./configure --prefix=/usr && make && make install
}
build "libgpg-error" "libgpg-error-1.50.tar.bz2" do_libgpgerror

# ── libgcrypt ────────────────────────────────────────────────
do_libgcrypt() {
    ./configure --prefix=/usr && make && make install
}
build "libgcrypt" "libgcrypt-1.11.0.tar.bz2" do_libgcrypt

# ── D-Bus ────────────────────────────────────────────────────
do_dbus() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --localstatedir=/var \
        --runstatedir=/run   \
        --disable-static     \
        --disable-doxygen-docs \
        --disable-xml-docs   \
        --docdir=/usr/share/doc/dbus-1.15.8 \
        --with-system-socket=/run/dbus/system_bus_socket
    make && make install
    ln -sfv /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
}
build "D-Bus" "dbus-1.15.8.tar.xz" do_dbus

# ── libtasn1 / p11-kit ───────────────────────────────────────
do_libtasn1() { ./configure --prefix=/usr --disable-static && make && make install; }
build "libtasn1" "libtasn1-4.19.0.tar.gz" do_libtasn1

do_p11kit() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D trust_paths=/etc/pki/anchors
    ninja && ninja install
    ln -sfv /usr/libexec/p11-kit/trust-extract-compat \
        /usr/bin/update-ca-certificates
}
build "p11-kit" "p11-kit-0.25.5.tar.xz" do_p11kit

# ── libxml2 ──────────────────────────────────────────────────
do_libxml2() {
    ./configure --prefix=/usr --disable-static \
        --with-history --with-icu \
        --docdir=/usr/share/doc/libxml2-2.13.5
    make && make install
}
build "libxml2" "libxml2-2.13.5.tar.xz" do_libxml2

# ── libxslt ──────────────────────────────────────────────────
do_libxslt() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/libxslt-1.1.42
    make && make install
}
build "libxslt" "libxslt-1.1.42.tar.xz" do_libxslt

# ── ICU ──────────────────────────────────────────────────────
do_icu() {
    cd source
    ./configure --prefix=/usr && make && make install
}
build "ICU" "icu4c-75_1-src.tgz" do_icu

# ── SQLite ───────────────────────────────────────────────────
do_sqlite() {
    ./configure --prefix=/usr --disable-static \
        --enable-fts5 \
        CPPFLAGS="-DSQLITE_ENABLE_FTS3=1 \
                   -DSQLITE_ENABLE_FTS4=1 \
                   -DSQLITE_ENABLE_COLUMN_METADATA=1 \
                   -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 \
                   -DSQLITE_ENABLE_DBSTAT_VTAB=1 \
                   -DSQLITE_SECURE_DELETE=1 \
                   -DSQLITE_ENABLE_FTS3_TOKENIZER=1"
    make && make install
}
build "SQLite" "sqlite-autoconf-3470200.tar.gz" do_sqlite

# ── GLib2 ────────────────────────────────────────────────────
do_glib() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D introspection=disabled -D man-pages=disabled
    ninja && ninja install
}
build "GLib2" "glib-2.82.4.tar.xz" do_glib

# ── Boost ────────────────────────────────────────────────────
do_boost() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          -D boost.locale.icu=ON      \
          ..
    make && make install
}
build "Boost" "boost-1.86.0-cmake.tar.xz" do_boost

# ── Wayland ──────────────────────────────────────────────────
do_wayland() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D documentation=false -D dtd_validation=false
    ninja && ninja install
}
build "Wayland" "wayland-1.23.1.tar.xz" do_wayland

do_wayland_protocols() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release
    ninja && ninja install
}
build "Wayland-protocols" "wayland-protocols-1.38.tar.xz" do_wayland_protocols

# ── libdrm ───────────────────────────────────────────────────
do_libdrm() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D udev=true -D valgrind=disabled
    ninja && ninja install
}
build "libdrm" "libdrm-2.4.123.tar.xz" do_libdrm

# ── libpng ───────────────────────────────────────────────────
do_libpng() {
    ./configure --prefix=/usr --disable-static
    make && make install
}
build "libpng" "libpng-1.6.45.tar.xz" do_libpng

# ── libjpeg ──────────────────────────────────────────────────
do_libjpeg() { ./configure --prefix=/usr --disable-static && make && make install; }
build "libjpeg" "jpegsrc.v9f.tar.gz" do_libjpeg

# ── libwebp ──────────────────────────────────────────────────
do_libwebp() {
    ./configure --prefix=/usr --disable-static \
        --enable-libwebpmux --enable-libwebpdemux \
        --enable-libwebpdecoder --enable-libwebpextras
    make && make install
}
build "libwebp" "libwebp-1.5.0.tar.gz" do_libwebp

# ── libtiff ──────────────────────────────────────────────────
do_libtiff() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          ..
    make && make install
}
build "libtiff" "tiff-4.7.0.tar.gz" do_libtiff

# ── FreeType2 ────────────────────────────────────────────────
do_freetype() {
    sed -ri "s:.*(AUX_MODULES.*valid):\1:" modules.cfg
    sed -r "s:.*(#.*SUBPIXEL_RENDERING) .*:\1:" \
        -i include/freetype/config/ftoption.h
    ./configure --prefix=/usr --enable-freetype-config --disable-static
    make && make install
}
build "FreeType2" "freetype-2.13.3.tar.xz" do_freetype

# ── Fontconfig ───────────────────────────────────────────────
do_fontconfig() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --localstatedir=/var --disable-docs \
        --docdir=/usr/share/doc/fontconfig-2.15.0
    make && make install
}
build "Fontconfig" "fontconfig-2.15.0.tar.gz" do_fontconfig

# ── Pixman ───────────────────────────────────────────────────
do_pixman() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D libpng=enabled -D tests=disabled
    ninja && ninja install
}
build "Pixman" "pixman-0.43.4.tar.gz" do_pixman

# ── HarfBuzz ─────────────────────────────────────────────────
do_harfbuzz() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D graphite2=disabled
    ninja && ninja install
}
build "HarfBuzz" "harfbuzz-10.2.0.tar.xz" do_harfbuzz

# ── Cairo ────────────────────────────────────────────────────
do_cairo() {
    ./configure --prefix=/usr \
        --disable-static      \
        --enable-tee
    make && make install
}
build "Cairo" "cairo-1.18.2.tar.xz" do_cairo

# ── Pango ────────────────────────────────────────────────────
do_pango() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D introspection=disabled
    ninja && ninja install
}
build "Pango" "pango-1.54.0.tar.xz" do_pango

# ── ATK ──────────────────────────────────────────────────────
do_atk() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D introspection=false
    ninja && ninja install
}
build "ATK" "atk-2.38.0.tar.xz" do_atk

# ── at-spi2-core ─────────────────────────────────────────────
do_atspi() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D introspection=no -D docs=false
    ninja && ninja install
}
build "at-spi2-core" "at-spi2-core-2.54.1.tar.xz" do_atspi

# ── GDK-Pixbuf ───────────────────────────────────────────────
do_gdkpixbuf() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D man=false -D introspection=disabled
    ninja && ninja install
}
build "GDK-Pixbuf" "gdk-pixbuf-2.42.12.tar.xz" do_gdkpixbuf

# ── X.org プロトコル & xcb ────────────────────────────────────
do_xorgproto() { ./configure --prefix=/usr && make && make install; }
build "xorgproto"  "xorgproto-2024.1.tar.xz"  do_xorgproto

do_xcbproto() { ./configure --prefix=/usr && make && make install; }
build "xcb-proto"  "xcb-proto-1.17.0.tar.xz"  do_xcbproto

do_libxcb() {
    ./configure --prefix=/usr --without-doxygen --docdir=/usr/share/doc/libxcb-1.17.0
    make && make install
}
build "libxcb"     "libxcb-1.17.0.tar.xz"     do_libxcb

# X.org ライブラリ群 (共通ビルド関数)
xlib_build() { ./configure --prefix=/usr --disable-static && make && make install; }

build "libX11"       "libX11-1.8.10.tar.xz"      xlib_build
build "libXext"      "libXext-1.3.6.tar.xz"       xlib_build
build "libXrender"   "libXrender-0.9.12.tar.xz"   xlib_build
build "libXrandr"    "libXrandr-1.5.4.tar.xz"     xlib_build
build "libXi"        "libXi-1.8.2.tar.xz"         xlib_build
build "libXfixes"    "libXfixes-6.0.1.tar.xz"     xlib_build
build "libXcursor"   "libXcursor-1.2.3.tar.xz"    xlib_build
build "libXinerama"  "libXinerama-1.1.5.tar.xz"   xlib_build
build "libXcomposite" "libXcomposite-0.4.6.tar.xz" xlib_build
build "libXdamage"   "libXdamage-1.1.6.tar.xz"    xlib_build

# ── libxkbcommon ─────────────────────────────────────────────
do_libxkbcommon() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D enable-docs=false -D enable-wayland=true \
        -D enable-x11=true
    ninja && ninja install
}
build "libxkbcommon" "libxkbcommon-1.7.0.tar.xz" do_libxkbcommon

# ── libinput ─────────────────────────────────────────────────
do_libinput() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D debug-gui=false -D tests=false \
        -D documentation=false -D udev-dir=/usr/lib/udev
    ninja && ninja install
}
build "libinput" "libinput-1.26.2.tar.xz" do_libinput

# ── Mesa ─────────────────────────────────────────────────────
do_mesa() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D platforms=wayland,x11     \
        -D gallium-drivers=auto      \
        -D vulkan-drivers=auto       \
        -D valgrind=disabled         \
        -D libunwind=disabled
    ninja && ninja install
}
build "Mesa" "mesa-24.3.4.tar.xz" do_mesa

# ── GTK3 ─────────────────────────────────────────────────────
do_gtk3() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --enable-broadway-backend \
        --enable-wayland-backend  \
        --enable-x11-backend      \
        --disable-introspection
    make && make install
}
build "GTK3" "gtk+-3.24.43.tar.xz" do_gtk3

# ── polkit ───────────────────────────────────────────────────
do_polkit() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D man=false -D introspection=false \
        -D authfw=shadow -D tests=false
    ninja && ninja install
}
build "polkit" "polkit-125.tar.bz2" do_polkit

# ── NetworkManager ────────────────────────────────────────────
do_nm() {
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        --sysconfdir=/etc --localstatedir=/var \
        -D nmtui=true       \
        -D ovs=false        \
        -D ppp=false        \
        -D selinux=false    \
        -D qt=false         \
        -D introspection=false \
        -D systemd_journal=false \
        -D docs=false
    ninja && ninja install

    # NetworkManager サービス設定
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/00-defaults.conf << 'NMEOF'
[main]
plugins=keyfile

[keyfile]
path=/etc/NetworkManager/system-connections

[device]
wifi.backend=wpa_supplicant
NMEOF

    # 起動スクリプト
    cat > /etc/rc.d/init.d/networkmanager << 'NMSVCEOF'
#!/bin/bash
source /lib/lsb/init-functions
case $1 in
  start)  dbus-daemon --system --fork 2>/dev/null; NetworkManager --no-daemon & ;;
  stop)   killall NetworkManager 2>/dev/null || true ;;
  status) pgrep NetworkManager > /dev/null && echo "running" || echo "stopped" ;;
esac
NMSVCEOF
    chmod +x /etc/rc.d/init.d/networkmanager 2>/dev/null || true
}
build "NetworkManager" "NetworkManager-1.48.10.tar.xz" do_nm

# ── Qt6 ──────────────────────────────────────────────────────
do_qt6() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr            \
          -DCMAKE_BUILD_TYPE=Release             \
          -DCMAKE_INSTALL_LIBDIR=lib             \
          -DQT_BUILD_EXAMPLES=OFF               \
          -DQT_BUILD_TESTS=OFF                  \
          -DQT_FEATURE_wayland=ON               \
          -DQT_FEATURE_xcb=ON                   \
          -DQT_FEATURE_opengl=ON                \
          -DQT_FEATURE_reduce_relocations=OFF   \
          ..
    make "-j__CPU_CORE__" && make install
    # Qt6 環境変数
    cat > /etc/profile.d/qt6.sh << 'QT6EOF'
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
QT6EOF
}
build "Qt6" "qt-everywhere-src-6.8.1.tar.xz" do_qt6

# ── extra-cmake-modules ──────────────────────────────────────
do_ecm() { cmake_build; }
build "extra-cmake-modules" "extra-cmake-modules-6.9.0.tar.xz" do_ecm

# ── KDE Frameworks (最小セット) ──────────────────────────────
kde_fw_build() { cmake_build; }
for fw in ki18n kconfig kcoreaddons kwidgetsaddons kwindowsystem \
          solid kauth kcrash kjobwidgets kservice kio kiconthemes \
          knotifications plasma-framework; do
    ver="6.9.0"
    build "KF6/${fw}" "${fw}-${ver}.tar.xz" kde_fw_build
done

# ── kwin ─────────────────────────────────────────────────────
do_kwin() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          ..
    make && make install
}
build "KWin" "kwin-6.2.5.tar.xz" do_kwin

# ── plasma-desktop ───────────────────────────────────────────
do_plasma_desktop() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          ..
    make && make install
}
build "plasma-desktop" "plasma-desktop-6.2.5.tar.xz" do_plasma_desktop

# ── plasma-workspace ─────────────────────────────────────────
do_plasma_workspace() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          ..
    make && make install
}
build "plasma-workspace" "plasma-workspace-6.2.5.tar.xz" do_plasma_workspace

# ── plasma-nm (NetworkManager KDE applet) ────────────────────
do_plasma_nm() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          ..
    make && make install
}
build "plasma-nm" "plasma-nm-6.2.5.tar.xz" do_plasma_nm

# ── Konsole ──────────────────────────────────────────────────
do_konsole() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          ..
    make && make install
}
build "Konsole" "konsole-24.12.1.tar.xz" do_konsole

# ── SDDM ─────────────────────────────────────────────────────
do_sddm() {
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release  \
          -DCMAKE_INSTALL_LIBDIR=lib  \
          -D ENABLE_WAYLAND=ON        \
          ..
    make && make install

    # SDDM ユーザー
    groupadd -g 64 sddm 2>/dev/null || true
    useradd  -c "SDDM Daemon" -d /var/lib/sddm \
             -u 64 -g sddm -s /usr/bin/nologin \
             sddm 2>/dev/null || true

    # SDDM 設定
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/kde_settings.conf << 'SDDMEOF'
[Autologin]
Relogin=false
Session=plasmawayland
User=

[General]
HaltCommand=/usr/sbin/shutdown -h -P now
RebootCommand=/usr/sbin/shutdown -r now

[Theme]
Current=breeze

[Users]
MaximumUid=60513
MinimumUid=1000
SDDMEOF

    # SDDM 自動起動 (SysVinit)
    cat > /etc/rc.d/init.d/sddm << 'SDDMSVC'
#!/bin/bash
source /lib/lsb/init-functions
case $1 in
  start)  dbus-daemon --system --fork 2>/dev/null
          NetworkManager --no-daemon &
          sleep 2
          sddm & ;;
  stop)   killall sddm 2>/dev/null || true ;;
  status) pgrep sddm > /dev/null && echo "running" || echo "stopped" ;;
esac
SDDMSVC
    chmod +x /etc/rc.d/init.d/sddm 2>/dev/null || true

    # /etc/inittab で起動レベル5に SDDM を設定
    grep -q sddm /etc/inittab 2>/dev/null || \
    cat >> /etc/inittab << 'INITTABEOF'
# KDE/SDDM
x:5:respawn:/etc/rc.d/init.d/sddm start
INITTABEOF
}
build "SDDM" "sddm-0.21.0.tar.xz" do_sddm

# ── 日本語フォント ────────────────────────────────────────────
echo "[BLFS] 日本語フォント (Noto CJK) のダウンロード"
mkdir -p /usr/share/fonts/noto-cjk
NOTO_URL="https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/Japanese"
for f in NotoSansCJKjp-Regular.otf NotoSansCJKjp-Bold.otf; do
    [[ -f "/usr/share/fonts/noto-cjk/${f}" ]] || \
    wget -q "${NOTO_URL}/${f}" -O "/usr/share/fonts/noto-cjk/${f}" 2>/dev/null || true
done
fc-cache -fv 2>/dev/null || true

# ── ロケール / タイムゾーン / 基本設定 ───────────────────────
echo "[BLFS] ロケール設定"
echo "__LOCALE__" >> /etc/locale.gen
locale-gen 2>/dev/null || \
    localedef -i ja_JP -f UTF-8 ja_JP.UTF-8 2>/dev/null || true

cat > /etc/locale.conf << LOCEOF
LANG=__LOCALE_NAME__
LC_ALL=__LOCALE_NAME__
LOCEOF

cat > /etc/vconsole.conf << 'VCEOF'
KEYMAP=jp106
FONT=latarcyrheb-sun16
VCEOF

echo "[BLFS] hostname"
echo "lfs" > /etc/hostname

echo "[BLFS] root パスワード"
echo "root:__ROOT_PASSWORD__" | chpasswd

echo "[BLFS] /etc/fstab"
cat > /etc/fstab << 'FSTABEOF'
# UUID をデプロイ時に morning.sh が自動設定します
# UUID=XXXX  /         ext4   defaults,noatime 0 1
# UUID=XXXX  /boot/efi vfat   defaults         0 2
FSTABEOF

echo ""
echo "[BLFS] ビルド完了！"
echo "  - sudo, nano : インストール済み"
echo "  - NetworkManager : インストール済み"
echo "  - KDE Plasma 6 (plasma-desktop + kwin + SDDM) : インストール済み"
BLFSEOF

    sed -i \
        -e "s|__CPU_CORE__|${CPU_CORE}|g"           \
        -e "s|__TZ__|${TZ}|g"                       \
        -e "s|__LOCALE__|${LOCALE}|g"               \
        -e "s|__LOCALE_NAME__|${LOCALE_NAME}|g"     \
        -e "s|__ROOT_PASSWORD__|${ROOT_PASSWORD}|g" \
        "${LFS}/tmp/build-blfs.sh"
    chmod +x "${LFS}/tmp/build-blfs.sh"

    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root TERM="${TERM}" \
        PS1='(blfs) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j${CPU_CORE}" \
        PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig" \
        /bin/bash /tmp/build-blfs.sh \
        2>&1 | tee "/${WS}/blfs-build.log"

    umount "${LFS}/sources" 2>/dev/null || true
    done_flag step6_blfs
    log_info "Step6 完了"
else
    log_skip "Step6"
fi

# =============================================================================
# Step 7: tar.gz に固める
# =============================================================================
cleanup
trap - EXIT

log_step "Step7: rootfs → tar.gz"
tar czpf "${OUTPUT_TAR}"          \
    --one-file-system             \
    --numeric-owner               \
    --preserve-permissions        \
    --sparse                      \
    --exclude="${LFS}/sources"    \
    --exclude="${LFS}/tools"      \
    -C "/${WS}"                   \
    lfs-rootfs

sha256sum "${OUTPUT_TAR}" > "${OUTPUT_TAR}.sha256"
date '+%Y-%m-%d %H:%M:%S' > "${DONE_FLAG}"

echo ""
echo "============================================"
echo "[DONE] $(date '+%Y-%m-%d %H:%M:%S') BLFS ビルド完了！"
echo "  出力: ${OUTPUT_TAR}"
echo "  サイズ: $(du -sh ${OUTPUT_TAR} | cut -f1)"
echo ""
echo "朝起きたら:"
echo "  sudo bash morning.sh"
echo "============================================"
