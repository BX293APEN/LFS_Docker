#!/usr/bin/env bash
# =============================================================================
# lfs.sh  ―  Docker コンテナ内エントリーポイント
# 役割: LFS base → BLFS CLI ツール群 → tar.gz 出力
#
# ターゲット構成: CLI のみ（KDE不要）
#   sudo / nano / git / curl / wget / htop / tmux /
#   tree / rsync / unzip / less / vim / bash-completion
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

# ミラーフォールバックリスト（順番に試す）
LFS_MIRRORS=(
    "${LFS_MIRROR:-https://www.linuxfromscratch.org/lfs/downloads}"
    "https://ftp.osuosl.org/pub/lfs/lfs-packages/${LFS_VERSION:-12.2}"
    "https://mirror.pseudoform.org/lfs/${LFS_VERSION:-12.2}"
    "https://ftp.lfs-matrix.net/pub/lfs/lfs-packages/${LFS_VERSION:-12.2}"
)
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

echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') LFS CLI ビルド開始"
echo "  LFS バージョン: ${LFS_VERSION}"
echo "  アーキ        : ${LFS_ARCH} (${LFS_TGT})"
echo "  ロケール      : ${LOCALE_NAME}"
echo "  タイムゾーン  : ${TZ}"
echo "  並列数        : ${CPU_CORE}"
echo "  出力先        : ${OUTPUT_TAR}"
echo "  目標          : CLI (sudo nano git curl wget htop tmux ...)"
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

# ミラーフォールバック付き wget
# 使い方: mirror_wget <パス> <ファイル名>
# 例: mirror_wget "12.2/wget-list-systemd" "wget-list"
mirror_wget() {
    local rel_path="$1"
    local dest="$2"
    for mirror in "${LFS_MIRRORS[@]}"; do
        local url="${mirror}/${rel_path}"
        echo "  [TRY] ${url}"
        if wget -qO "${dest}" --timeout=60 --tries=2 "${url}"; then
            echo "  [OK]  ${mirror}"
            return 0
        fi
    done
    echo "[ERROR] 全ミラーで取得失敗: ${rel_path}"
    return 1
}

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
# lfs ユーザー/グループ: コンテナ再起動のたびに /etc/passwd がリセットされるため
# フラグに関わらず毎回作成する
# =============================================================================
groupadd lfs 2>/dev/null || true
useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true
log_info "lfs ユーザー確認済 (uid=$(id -u lfs 2>/dev/null || echo '?'))"

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
    mkdir -p "${LFS}/tools"
    # LFS Book Chapter 4: lfs ユーザーがビルドできるよう LFS ツリー全体を chown
    chown -R lfs:lfs "${LFS}"
    done_flag step1_dirs
    log_info "Step1 完了"
else
    log_skip "Step1"
fi

# Step1 フラグの外: コンテナ再起動で uid がリセットされても
# lfs ユーザーが LFS ツリーに書き込めるよう毎回 chown する
log_info "LFS ツリーの所有者を lfs に設定中..."
chown -R lfs:lfs "${LFS}"
log_info "chown 完了"

# =============================================================================
# Step 2: LFS ソースダウンロード（ミラーフォールバック付き）
# =============================================================================
if ! flagged step2_sources; then
    log_step "Step2: LFS ソースダウンロード"
    mkdir -p "${LFS}/sources"
    chmod a+wt "${LFS}/sources"
    cd "${LFS}/sources"

    # wget-list を取得（ミラーフォールバック）
    log_info "wget-list 取得中..."
    mirror_wget "${LFS_VERSION}/wget-list-systemd" "wget-list" || \
        mirror_wget "${LFS_VERSION}/wget-list" "wget-list" || \
        { echo "[ERROR] wget-list が取得できませんでした。ミラーを .env で変更してください。"; exit 1; }

    mirror_wget "${LFS_VERSION}/md5sums" "md5sums" || true

    log_info "ソースパッケージ ダウンロード中..."
    wget --continue --input-file=wget-list \
         --directory-prefix="${LFS}/sources" \
         --no-clobber --timeout=60 --tries=3 \
         2>&1 | tee "/${WS}/download-lfs.log" || true

    # ── expat は wget-list のURLが取得できないことがあるので GitHub から直接取得 ──
    if [[ ! -f "expat-2.6.2.tar.xz" ]]; then
        log_info "expat-2.6.2.tar.xz が見つからないため GitHub から直接取得します..."
        wget -q --timeout=120 --tries=3 \
            "https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz" \
            -O expat-2.6.2.tar.xz \
            || { echo "[ERROR] expat のダウンロードに失敗しました"; exit 1; }
        log_info "expat-2.6.2.tar.xz 取得完了"
    fi

    # ── md5チェックで失敗ファイルを検出・報告 ──
    if [[ -f md5sums ]]; then
        log_info "MD5 チェック中..."
        FAILED=$(md5sum -c md5sums 2>/dev/null | grep ": FAILED" | sed 's/: FAILED//' || true)
        if [[ -z "$FAILED" ]]; then
            log_info "MD5 OK: 全ファイル正常"
        else
            echo "[WARN] MD5 不一致ファイル（破損の可能性あり）:"
            echo "$FAILED"
        fi
    fi
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

    # lfs ホームディレクトリが確実に存在するよう保証
    mkdir -p /home/lfs
    chown lfs:lfs /home/lfs
    chmod 700 /home/lfs

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

    # .bashrc の展開結果をログに出力して確認
    log_info "[DEBUG] /home/lfs/.bashrc の内容:"
    cat /home/lfs/.bashrc

    # build-toolchain.sh を lfs がアクセスできる場所に配置
    mkdir -p /home/lfs
    cat > /home/lfs/build-toolchain.sh << 'TCEOF'
#!/bin/bash
set -eo pipefail
source ~/.bashrc

# ── 環境変数の検証 ─────────────────────────────────────────
echo "[DEBUG] LFS       = ${LFS}"
echo "[DEBUG] LFS_TGT   = ${LFS_TGT}"
echo "[DEBUG] PATH      = ${PATH}"
echo "[DEBUG] MAKEFLAGS = ${MAKEFLAGS}"

[[ -z "${LFS}" ]]        && { echo "[ERROR] LFS が未定義です。.bashrc の展開を確認してください。"; exit 1; }
[[ -d "${LFS}/sources" ]] || { echo "[ERROR] ${LFS}/sources が存在しません。Step2 を確認してください。"; exit 1; }
[[ -d "${LFS}/tools" ]]   || { echo "[ERROR] ${LFS}/tools が存在しません。Step1 を確認してください。"; exit 1; }

pkg_build() {
    local name="$1" tarball="$2" fn="$3"
    echo "[TC] $(date '+%H:%M:%S') ${name}"
    cd "${LFS}/sources"
    local dir; dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1 || true)
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
    chown lfs:lfs /home/lfs/build-toolchain.sh
    chmod +x /home/lfs/build-toolchain.sh

    # ログをファイルに書きつつ docker logs でも見えるようにする
    # 注意: su - は新しいシェルを起動するため PIPESTATUS を正しく取るには
    #       サブシェル内の終了コードを明示的に取り出す必要がある
    su - lfs -c "bash ~/build-toolchain.sh" 2>&1 | tee "/${WS}/toolchain.log"
    TC_EXIT=${PIPESTATUS[0]}
    [[ ${TC_EXIT} -eq 0 ]] || { echo "[ERROR] Step3 クロスツールチェーン失敗 (exit=${TC_EXIT})。/${WS}/toolchain.log を確認してください。"; exit 1; }
    done_flag step3_toolchain
    log_info "Step3 完了"
else
    log_skip "Step3"
fi


# =============================================================================
# Step 3.5: Chapter 6 ― クロスコンパイルによる一時ツール群
# (chroot に入る前に /usr/bin/env 等を LFS ツリーに配置する)
# LFS Book 12.2 Chapter 6 に相当
# =============================================================================
if ! flagged step3_5_temptools; then
    log_step "Step3.5: 一時ツール群ビルド (Chapter 6)"

    # lfs ユーザーが書き込めるよう再度 chown
    chown -R lfs:lfs "${LFS}/tools" "${LFS}/usr" "${LFS}/lib" "${LFS}/lib64" \
        "${LFS}/bin" "${LFS}/sbin" "${LFS}/etc" "${LFS}/var" 2>/dev/null || true

    cat > /home/lfs/build-temptools.sh << 'TTEOF'
#!/bin/bash
set -eo pipefail
source ~/.bashrc

SRC="${LFS}/sources"

tt_build() {
    local name="$1" tarball="$2" fn="$3"
    echo "[TT] $(date '+%H:%M:%S') ${name}"
    cd "${SRC}"
    local dir; dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    [[ -z "${dir}" ]] && { echo "[ERROR] tarball 展開失敗: ${tarball}"; exit 1; }
    tar -xf "${tarball}"
    cd "${dir}"
    ${fn}
    cd "${SRC}"
    rm -rf "${dir}"
}

# ── M4 ──────────────────────────────────────────────────────
do_m4() {
    ./configure --prefix=/usr --host="${LFS_TGT}" --build="$(build-aux/config.guess 2>/dev/null || config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "M4" "$(ls ${SRC}/m4-*.tar.*)" do_m4

# ── Ncurses ─────────────────────────────────────────────────
do_ncurses() {
    sed -i s/mawk// configure
    mkdir build && cd build
    ../configure
    make -C include && make -C progs tic
    cd ..
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./config.guess)" --mandir=/usr/share/man \
        --with-manpage-format=normal --with-shared --without-normal \
        --with-cxx-shared --without-debug --without-ada \
        --disable-stripping
    make && make DESTDIR="${LFS}" TIC_PATH="${LFS}/sources/ncurses-*/build/progs/tic" install
    ln -sv libncursesw.so "${LFS}/usr/lib/libncurses.so"
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "${LFS}/usr/include/curses.h" 2>/dev/null || true
}
tt_build "Ncurses" "$(ls ${SRC}/ncurses-*.tar.*)" do_ncurses

# ── Bash ────────────────────────────────────────────────────
do_bash() {
    ./configure --prefix=/usr --build="$(sh support/config.guess)" \
        --host="${LFS_TGT}" --without-bash-malloc \
        bash_cv_strtold_broken=no
    make && make DESTDIR="${LFS}" install
    ln -sv bash "${LFS}/bin/sh" 2>/dev/null || true
}
tt_build "Bash" "$(ls ${SRC}/bash-*.tar.*)" do_bash

# ── Coreutils ───────────────────────────────────────────────
do_coreutils() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)" \
        --enable-install-program=hostname \
        --enable-no-install-program=kill,uptime
    make && make DESTDIR="${LFS}" install
    mv -v "${LFS}/usr/bin/chroot" "${LFS}/usr/sbin/" 2>/dev/null || true
    mkdir -pv "${LFS}/usr/share/man/man8"
    mv -v "${LFS}/usr/share/man/man1/chroot.1" \
          "${LFS}/usr/share/man/man8/chroot.8" 2>/dev/null || true
    sed -i 's/"1"/"8"/' "${LFS}/usr/share/man/man8/chroot.8" 2>/dev/null || true
}
tt_build "Coreutils" "$(ls ${SRC}/coreutils-*.tar.*)" do_coreutils

# ── Diffutils ───────────────────────────────────────────────
do_diffutils() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Diffutils" "$(ls ${SRC}/diffutils-*.tar.*)" do_diffutils

# ── File ────────────────────────────────────────────────────
do_file() {
    mkdir build && cd build
    ../configure --disable-bzlib --disable-libseccomp \
        --disable-xzlib --disable-zlib
    make
    cd ..
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./config.guess)"
    make FILE_COMPILE="${LFS}/sources/file-*/build/src/file"
    make DESTDIR="${LFS}" install
    rm -v "${LFS}/usr/lib/libmagic.la" 2>/dev/null || true
}
tt_build "File" "$(ls ${SRC}/file-*.tar.*)" do_file

# ── Findutils ───────────────────────────────────────────────
do_findutils() {
    ./configure --prefix=/usr --localstatedir=/var/lib/locate \
        --host="${LFS_TGT}" --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Findutils" "$(ls ${SRC}/findutils-*.tar.*)" do_findutils

# ── Gawk ────────────────────────────────────────────────────
do_gawk() {
    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Gawk" "$(ls ${SRC}/gawk-*.tar.*)" do_gawk

# ── Grep ────────────────────────────────────────────────────
do_grep() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Grep" "$(ls ${SRC}/grep-*.tar.*)" do_grep

# ── Gzip ────────────────────────────────────────────────────
do_gzip() {
    ./configure --prefix=/usr --host="${LFS_TGT}"
    make && make DESTDIR="${LFS}" install
}
tt_build "Gzip" "$(ls ${SRC}/gzip-*.tar.*)" do_gzip

# ── Make ────────────────────────────────────────────────────
do_make() {
    ./configure --prefix=/usr --without-guile \
        --host="${LFS_TGT}" --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Make" "$(ls ${SRC}/make-*.tar.*)" do_make

# ── Patch ───────────────────────────────────────────────────
do_patch() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Patch" "$(ls ${SRC}/patch-*.tar.*)" do_patch

# ── Sed ─────────────────────────────────────────────────────
do_sed() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Sed" "$(ls ${SRC}/sed-*.tar.*)" do_sed

# ── Tar ─────────────────────────────────────────────────────
do_tar() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Tar" "$(ls ${SRC}/tar-*.tar.*)" do_tar

# ── Xz ──────────────────────────────────────────────────────
do_xz() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)" \
        --disable-static --docdir=/usr/share/doc/xz
    make && make DESTDIR="${LFS}" install
    rm -v "${LFS}/usr/lib/liblzma.la" 2>/dev/null || true
}
tt_build "Xz" "$(ls ${SRC}/xz-*.tar.*)" do_xz

# ── Binutils Pass2 ──────────────────────────────────────────
do_binutils_p2() {
    sed '6009s/$add_dir//' -i ltmain.sh
    mkdir build && cd build
    ../configure --prefix=/usr --build="$(../config.guess)" \
        --host="${LFS_TGT}" --disable-nls --enable-shared \
        --enable-gprofng=no --disable-werror \
        --enable-64-bit-bfd --enable-new-dtags \
        --enable-default-hash-style=gnu
    make && make DESTDIR="${LFS}" install
    rm -v "${LFS}"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la} 2>/dev/null || true
}
tt_build "Binutils Pass2" "$(ls ${SRC}/binutils-*.tar.*)" do_binutils_p2

# ── GCC Pass2 ───────────────────────────────────────────────
do_gcc_p2() {
    tar -xf ../mpfr-*.tar.* && mv mpfr-* mpfr
    tar -xf ../gmp-*.tar.*  && mv gmp-*  gmp
    tar -xf ../mpc-*.tar.*  && mv mpc-*  mpc
    case $(uname -m) in x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;; esac
    sed '/thread_header =/s/@.*@/gthr-posix.h/' \
        -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
    mkdir build && cd build
    ../configure --build="$(../config.guess)" \
        --host="${LFS_TGT}" --target="${LFS_TGT}" \
        LDFLAGS_FOR_TARGET="-L${PWD}/${LFS_TGT}/libgcc" \
        --prefix=/usr --with-build-sysroot="${LFS}" \
        --enable-default-pie --enable-default-ssp \
        --disable-nls --disable-multilib --disable-libatomic \
        --disable-libgomp --disable-libquadmath --disable-libsanitizer \
        --disable-libssp --disable-libvtv --enable-languages=c,c++
    make && make DESTDIR="${LFS}" install
    ln -sv gcc "${LFS}/usr/bin/cc" 2>/dev/null || true
}
tt_build "GCC Pass2" "$(ls ${SRC}/gcc-*.tar.*)" do_gcc_p2

echo "[TT] 一時ツール群ビルド完了"
TTEOF
    chown lfs:lfs /home/lfs/build-temptools.sh
    chmod +x /home/lfs/build-temptools.sh

    su - lfs -c "bash ~/build-temptools.sh" 2>&1 | tee "/${WS}/temptools.log"
    TT_EXIT=${PIPESTATUS[0]}
    [[ ${TT_EXIT} -eq 0 ]] || { echo "[ERROR] Step3.5 一時ツール群ビルド失敗 (exit=${TT_EXIT})。/${WS}/temptools.log を確認してください。"; exit 1; }
    done_flag step3_5_temptools
    log_info "Step3.5 完了"
else
    log_skip "Step3.5"
fi

# Step3.5 完了後: chroot に備えて LFS ツリーの所有権を root に戻す
log_info "chroot に備えて LFS ツリーの所有権を root に戻します..."
chown -R root:root "${LFS}"
log_info "chown root 完了"

# =============================================================================
# Step 4: LFS base システム (chroot)
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
    local dir; dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1 || true)
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
    mkdir -p /usr/lib/locale
    localedef -i ja_JP -f UTF-8 ja_JP.UTF-8 2>/dev/null || true
    localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true
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
        --docdir=/usr/share/doc/xz-5.6
    make && make install
}
build "Xz" "$(ls ${SRC}/xz-*.tar.*)" do_xz

# ── Lz4 ─────────────────────────────────────────────────────
do_lz4() { make BUILD_STATIC=no PREFIX=/usr && make BUILD_STATIC=no PREFIX=/usr install; }
build "Lz4" "$(ls ${SRC}/lz4-*.tar.*)" do_lz4

# ── Zstd ────────────────────────────────────────────────────
do_zstd() {
    make prefix=/usr && make prefix=/usr install
    rm -v /usr/lib/libzstd.a
}
build "Zstd" "$(ls ${SRC}/zstd-*.tar.*)" do_zstd

# ── File ────────────────────────────────────────────────────
do_file() { ./configure --prefix=/usr && make && make install; }
build "File" "$(ls ${SRC}/file-*.tar.*)" do_file

# ── Readline ────────────────────────────────────────────────
do_readline() {
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install
    ./configure --prefix=/usr --disable-static \
        --with-curses --docdir=/usr/share/doc/readline-8.2
    make SHLIB_LIBS="-lncursesw"
    make SHLIB_LIBS="-lncursesw" install
}
build "Readline" "$(ls ${SRC}/readline-*.tar.*)" do_readline

# ── M4 / Bc / Flex ──────────────────────────────────────────
for pkg in m4 bc flex; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    if [[ "$pkg" == "bc" ]]; then
        CC=gcc ./configure --prefix=/usr -G -O3 -r
    elif [[ "$pkg" == "flex" ]]; then
        ./configure --prefix=/usr --disable-static
    else
        ./configure --prefix=/usr
    fi
    make && make install
    [[ "$pkg" == "flex" ]] && { ln -sv flex /usr/bin/lex; ln -sv flex.1 /usr/share/man/man1/lex.1; } || true
    cd ${SRC} && rm -rf "$dir"
done

# ── Tcl / Expect / DejaGNU / Pkgconf ────────────────────────
do_tcl() {
    SRCDIR=$(pwd)
    cd unix
    ./configure --prefix=/usr --mandir=/usr/share/man
    make
    sed -e "s|$SRCDIR/unix|/usr/lib|" -e "s|$SRCDIR|/usr/include|" -i tclConfig.sh
    make install
    chmod -v u+w /usr/lib/libtcl8.6.so 2>/dev/null || true
    make install-private-headers
    ln -sfv tclsh8.6 /usr/bin/tclsh
}
build "Tcl" "$(ls ${SRC}/tcl*-src.tar.*)" do_tcl

do_expect() {
    ./configure --prefix=/usr --with-tcl=/usr/lib \
        --enable-shared --disable-rpath \
        --mandir=/usr/share/man --with-tclinclude=/usr/include
    make && make install
}
build "Expect" "$(ls ${SRC}/expect*.tar.*)" do_expect

do_dejagnu() {
    mkdir build && cd build
    ../configure --prefix=/usr
    make install
}
build "DejaGNU" "$(ls ${SRC}/dejagnu-*.tar.*)" do_dejagnu

do_pkgconf() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/pkgconf-2.3.0
    make && make install
    ln -sv pkgconf /usr/bin/pkg-config
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

# ── GMP / MPFR / MPC ────────────────────────────────────────
do_gmp() {
    ./configure --prefix=/usr --enable-cxx --disable-static \
        --docdir=/usr/share/doc/gmp-6.3.0
    make && make install
}
build "GMP" "$(ls ${SRC}/gmp-*.tar.*)" do_gmp

do_mpfr() {
    ./configure --prefix=/usr --disable-static \
        --enable-thread-safe --docdir=/usr/share/doc/mpfr-4.2.1
    make && make install
}
build "MPFR" "$(ls ${SRC}/mpfr-*.tar.*)" do_mpfr

do_mpc() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/mpc-1.3.1
    make && make install
}
build "MPC" "$(ls ${SRC}/mpc-*.tar.*)" do_mpc

# ── Attr / Acl / Libcap / Libxcrypt ────────────────────────
do_attr() {
    ./configure --prefix=/usr --disable-static --sysconfdir=/etc \
        --docdir=/usr/share/doc/attr-2.5.2
    make && make install
}
build "Attr" "$(ls ${SRC}/attr-*.tar.*)" do_attr

do_acl() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/acl-2.3.2
    make && make install
}
build "Acl" "$(ls ${SRC}/acl-*.tar.*)" do_acl

do_libcap() {
    sed -i '/install -m.*STA/d' libcap/Makefile
    make prefix=/usr lib=lib && make prefix=/usr lib=lib install
}
build "Libcap" "$(ls ${SRC}/libcap-*.tar.*)" do_libcap

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

# ── Sed / Psmisc / Gettext / Bison / Grep ───────────────────
for pkg in sed psmisc gettext bison grep; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    ./configure --prefix=/usr ${pkg:+--disable-static} 2>/dev/null || \
        ./configure --prefix=/usr
    make && make install
    cd ${SRC} && rm -rf "$dir"
done

# ── Bash ────────────────────────────────────────────────────
do_bash() {
    ./configure --prefix=/usr --without-bash-malloc \
        --with-installed-readline \
        --docdir=/usr/share/doc/bash-5.2.37
    make && make install
    ln -sfv bash /usr/bin/sh
}
build "Bash" "$(ls ${SRC}/bash-*.tar.*)" do_bash

# ── Libtool / GDBM / Gperf / Expat / Inetutils / Less ──────
for pkg in libtool gdbm gperf expat inetutils less; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    case "$pkg" in
        gdbm)      ./configure --prefix=/usr --disable-static --enable-libgdbm-compat ;;
        inetutils) ./configure --prefix=/usr --bindir=/usr/bin --localstatedir=/var \
                       --disable-logger --disable-whois --disable-rcp \
                       --disable-rexec --disable-rlogin --disable-rsh --disable-servers ;;
        *)         ./configure --prefix=/usr ;;
    esac
    make && make install
    cd ${SRC} && rm -rf "$dir"
done

# ── Perl / XML::Parser / Intltool / Autoconf / Automake ─────
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

do_xmlparser() { perl Makefile.PL && make && make install; }
build "XML::Parser" "$(ls ${SRC}/XML-Parser-*.tar.*)" do_xmlparser

do_intltool() {
    sed -i 's:\\\${:\\\$\\{:' intltool-update.in
    ./configure --prefix=/usr && make && make install
}
build "Intltool" "$(ls ${SRC}/intltool-*.tar.*)" do_intltool

for pkg in autoconf automake; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    ./configure --prefix=/usr && make && make install
    cd ${SRC} && rm -rf "$dir"
done

# ── OpenSSL ─────────────────────────────────────────────────
do_openssl() {
    ./config --prefix=/usr --openssldir=/etc/ssl \
        --libdir=lib shared zlib-dynamic
    make && sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile
    make MANSUFFIX=ssl install
}
build "OpenSSL" "$(ls ${SRC}/openssl-*.tar.*)" do_openssl

# ── Kmod / Libelf / Libffi / Python ─────────────────────────
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

do_libelf() {
    ./configure --prefix=/usr --disable-debuginfod --enable-libdebuginfod=dummy
    make && make -C libelf install
    install -vm644 config/libelf.pc /usr/lib/pkgconfig
    rm /usr/lib/libelf.a
}
build "Libelf" "$(ls ${SRC}/elfutils-*.tar.*)" do_libelf

do_libffi() {
    ./configure --prefix=/usr --disable-static --with-gcc-arch=native
    make && make install
}
build "Libffi" "$(ls ${SRC}/libffi-*.tar.*)" do_libffi

do_python() {
    ./configure --prefix=/usr --enable-shared \
        --with-system-expat --enable-optimizations
    make && make install
    ln -sfv python3 /usr/bin/python
}
build "Python" "$(ls ${SRC}/Python-*.tar.*)" do_python

# ── Ninja / Meson ────────────────────────────────────────────
do_ninja() {
    python3 configure.py --bootstrap
    install -vm755 ninja /usr/bin/
}
build "Ninja" "$(ls ${SRC}/ninja-*.tar.*)" do_ninja

do_meson() { pip3 install --no-build-isolation --no-index . 2>/dev/null || python3 setup.py install --optimize=1; }
build "Meson" "$(ls ${SRC}/meson-*.tar.*)" do_meson

# ── Coreutils ───────────────────────────────────────────────
do_coreutils() {
    patch -Np1 -i ../coreutils-*.patch 2>/dev/null || true
    autoreconf -fiv 2>/dev/null || true
    FORCE_UNSAFE_CONFIGURE=1 ./configure \
        --prefix=/usr --enable-no-install-program=kill,uptime
    make && make install
    mv -v /usr/bin/chroot /usr/sbin
}
build "Coreutils" "$(ls ${SRC}/coreutils-*.tar.*)" do_coreutils

# ── Diffutils / Findutils / Gawk / Tar / Grep / Gzip / Patch / Make / Texinfo / Which / Vim
for pkg in diffutils findutils gawk tar grep gzip patch make texinfo which vim; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1)
    [[ -f "$f" ]] || continue
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && tar -xf "$f" && cd "$dir"
    if [[ "$pkg" == "vim" ]]; then
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
    else
        ./configure --prefix=/usr 2>/dev/null || true
        make && make install
    fi
    cd ${SRC} && rm -rf "$dir"
done

# ── Udev (systemd) ──────────────────────────────────────────
do_udev() {
    sed -i -e 's/GROUP="render"/GROUP="video"/' \
           -e 's/GROUP="sgx", //' rules.d/50-udev-default.rules.in
    sed -i -e '/systemd-sysctl/s/^/#/' rules.d/99-systemd.rules.in
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
    ninja udevadm systemd-hwdb
    DESTDIR=/ ninja install
}
build "Udev(systemd)" "$(ls ${SRC}/systemd-*.tar.*)" do_udev

# ── Man-DB / Procps-ng / Util-linux / E2fsprogs / SysVinit ─
do_mandb() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --disable-setuid --enable-cache-owner=bin \
        --with-systemdtmpfilesdir= --with-systemdsystemunitdir=
    make && make install
}
build "Man-DB" "$(ls ${SRC}/man-db-*.tar.*)" do_mandb

do_procps() {
    ./configure --prefix=/usr --disable-static --disable-kill
    make && make install
}
build "Procps-ng" "$(ls ${SRC}/procps-ng-*.tar.*)" do_procps

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

do_e2fsprogs() {
    mkdir build && cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
        --enable-elf-shlibs --disable-libblkid \
        --disable-libuuid --disable-uuidd --disable-fsck
    make && make install
    rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
}
build "E2fsprogs" "$(ls ${SRC}/e2fsprogs-*.tar.*)" do_e2fsprogs

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
        2>&1 | tee "/${WS}/lfs-base.log" ; true
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "[ERROR] Step4 LFS base ビルド失敗。lfs-base.log を確認してください。"; exit 1; }

    umount "${LFS}/sources" 2>/dev/null || true
    done_flag step4_lfs_base
    log_info "Step4 完了"
else
    log_skip "Step4"
fi

# =============================================================================
# Step 5: CLI ツール追加ダウンロード（KDE不要・軽量構成）
# =============================================================================
if ! flagged step5_cli_sources; then
    log_step "Step5: CLI ツール追加ダウンロード"
    mkdir -p "${LFS}/sources"
    cd "${LFS}/sources"

    CLI_PKGS=(
        # ── sudo ──────────────────────────────────────────────
        "https://www.sudo.ws/dist/sudo-1.9.15p5.tar.gz"
        # ── nano ──────────────────────────────────────────────
        "https://www.nano-editor.org/dist/v8/nano-8.3.tar.xz"
        # ── git 依存: curl, expat (LFSに含まれる), pcre2 ─────
        "https://curl.se/download/curl-8.11.1.tar.xz"
        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2"
        # ── git ───────────────────────────────────────────────
        "https://www.kernel.org/pub/software/scm/git/git-2.47.2.tar.xz"
        # ── htop ──────────────────────────────────────────────
        "https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz"
        # ── tmux 依存: libevent ───────────────────────────────
        "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz"
        # ── tmux ──────────────────────────────────────────────
        "https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz"
        # ── tree ──────────────────────────────────────────────
        "https://mama.indstate.edu/users/ice/tree/src/tree-2.1.3.tgz"
        # ── bash-completion ───────────────────────────────────
        "https://github.com/scop/bash-completion/releases/download/2.14.0/bash-completion-2.14.0.tar.xz"
        # ── D-Bus (sudo/polkit に必要) ─────────────────────────
        "https://dbus.freedesktop.org/releases/dbus/dbus-1.15.8.tar.xz"
        # ── iproute2 (ip コマンド) ─────────────────────────────
        "https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz"
        # ── dhcpcd (ネットワーク設定) ──────────────────────────
        "https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.0.10/dhcpcd-10.0.10.tar.xz"
        # ── openssh ───────────────────────────────────────────
        "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p1.tar.gz"
        # ── libgpg-error / libgcrypt (openssh 依存) ───────────
        "https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.50.tar.bz2"
        "https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2"
        # ── GRUB (ブートローダー) ──────────────────────────────
        "https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz"
        # ── Linux kernel ──────────────────────────────────────
        # ※ LFS Step2 で linux-*.tar.xz はすでに取得済みなので不要
    )

    log_info "CLI パッケージのダウンロード中..."
    for url in "${CLI_PKGS[@]}"; do
        [[ "$url" =~ ^# ]] && continue
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

    done_flag step5_cli_sources
    log_info "Step5 完了"
else
    log_skip "Step5"
fi

# =============================================================================
# Step 6: CLI ツール chroot ビルド
# =============================================================================
if ! flagged step6_cli; then
    log_step "Step6: CLI ツール ビルド"
    mount_chroot
    cp /etc/resolv.conf "${LFS}/etc/resolv.conf"
    mountpoint -q "${LFS}/sources" || mount --bind "${LFS}/sources" "${LFS}/sources"

    cat > "${LFS}/tmp/build-cli.sh" << 'CLIEOF'
#!/bin/bash
set -eo pipefail
export MAKEFLAGS="-j__CPU_CORE__"
export TERM=xterm-256color
SRC=/sources

build() {
    local name="$1" tarball="$2" fn="$3"
    if [[ ! -f "${SRC}/${tarball}" ]]; then
        echo "[SKIP] ${name}: ${tarball} なし"
        return 0
    fi
    echo "[CLI] $(date '+%H:%M:%S') ${name}"
    cd "${SRC}"
    local dir; dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    tar -xf "${tarball}"
    cd "${dir}"
    ${fn} || echo "[WARN] ${name} でエラーが発生しましたが続行します"
    cd "${SRC}"
    rm -rf "${dir}"
}

# ── D-Bus ────────────────────────────────────────────────────
do_dbus() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --localstatedir=/var --runstatedir=/run \
        --disable-static --disable-doxygen-docs \
        --disable-xml-docs \
        --with-system-socket=/run/dbus/system_bus_socket
    make && make install
    dbus-uuidgen --ensure
}
build "D-Bus" "dbus-1.15.8.tar.xz" do_dbus

# ── libgpg-error ─────────────────────────────────────────────
do_libgpgerror() { ./configure --prefix=/usr && make && make install; }
build "libgpg-error" "libgpg-error-1.50.tar.bz2" do_libgpgerror

# ── libgcrypt ────────────────────────────────────────────────
do_libgcrypt() { ./configure --prefix=/usr && make && make install; }
build "libgcrypt" "libgcrypt-1.11.0.tar.bz2" do_libgcrypt

# ── sudo ─────────────────────────────────────────────────────
do_sudo() {
    ./configure --prefix=/usr --libexecdir=/usr/lib \
        --with-secure-path --with-all-insults \
        --with-env-editor \
        --with-passprompt="[sudo] %u のパスワード: "
    make && make install
    # wheel グループに sudo 権限付与
    mkdir -p /etc/sudoers.d
    cat > /etc/sudoers.d/wheel << 'SUDOEOF'
%wheel ALL=(ALL:ALL) ALL
SUDOEOF
    chmod 440 /etc/sudoers.d/wheel
}
build "sudo" "sudo-1.9.15p5.tar.gz" do_sudo

# ── nano ─────────────────────────────────────────────────────
do_nano() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --enable-utf8 --docdir=/usr/share/doc/nano-8.3
    make && make install
    install -v -m644 doc/sample.nanorc /etc/nanorc
    # シンタックスハイライト有効化
    cat >> /etc/nanorc << 'NANOEOF'
set autoindent
set constantshow
set historylog
set mouse
set positionlog
set tabsize 4
include "/usr/share/nano/*.nanorc"
NANOEOF
}
build "nano" "nano-8.3.tar.xz" do_nano

# ── PCRE2 (git 依存) ─────────────────────────────────────────
do_pcre2() {
    ./configure --prefix=/usr --enable-unicode \
        --enable-jit --enable-pcre2-8 --enable-pcre2-16 \
        --enable-pcre2-32 --enable-pcre2grep-libz \
        --enable-pcre2test-libreadline --disable-static
    make && make install
}
build "PCRE2" "pcre2-10.44.tar.bz2" do_pcre2

# ── curl ─────────────────────────────────────────────────────
do_curl() {
    ./configure --prefix=/usr --disable-static \
        --enable-threaded-resolver \
        --with-ssl=/etc/ssl \
        --with-ca-path=/etc/ssl/certs
    make && make install
}
build "curl" "curl-8.11.1.tar.xz" do_curl

# ── git ──────────────────────────────────────────────────────
do_git() {
    ./configure --prefix=/usr \
        --with-gitconfig=/etc/gitconfig \
        --with-python=python3
    make && make install
    # git 基本設定
    cat > /etc/gitconfig << 'GITEOF'
[core]
    autocrlf = input
    safecrlf = warn
[color]
    ui = auto
[pull]
    rebase = false
GITEOF
}
build "git" "git-2.47.2.tar.xz" do_git

# ── libevent (tmux 依存) ─────────────────────────────────────
do_libevent() {
    ./configure --prefix=/usr --disable-static
    make && make install
}
build "libevent" "libevent-2.1.12-stable.tar.gz" do_libevent

# ── tmux ─────────────────────────────────────────────────────
do_tmux() {
    ./configure --prefix=/usr --sysconfdir=/etc
    make && make install
    # tmux 基本設定
    cat > /etc/tmux.conf << 'TMUXEOF'
set -g default-terminal "screen-256color"
set -g history-limit 10000
set -g mouse on
set -g status-style bg=colour234,fg=colour255
bind r source-file /etc/tmux.conf \; display "Reloaded"
TMUXEOF
}
build "tmux" "tmux-3.5a.tar.gz" do_tmux

# ── htop ─────────────────────────────────────────────────────
do_htop() {
    ./configure --prefix=/usr --disable-unicode
    make && make install
}
build "htop" "htop-3.3.0.tar.xz" do_htop

# ── tree ─────────────────────────────────────────────────────
do_tree() {
    make PREFIX=/usr && make PREFIX=/usr install
}
build "tree" "tree-2.1.3.tgz" do_tree

# ── bash-completion ──────────────────────────────────────────
do_bash_completion() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --with-bash=/usr/bin/bash
    make && make install
}
build "bash-completion" "bash-completion-2.14.0.tar.xz" do_bash_completion

# ── iproute2 ─────────────────────────────────────────────────
do_iproute2() {
    sed -i /ARPD/d     Makefile
    sed -i 's/arpd.8//' man/man8/Makefile
    make NETNS_RUN_DIR=/run/netns
    make NETNS_RUN_DIR=/run/netns install
}
build "iproute2" "iproute2-6.12.0.tar.xz" do_iproute2

# ── dhcpcd ───────────────────────────────────────────────────
do_dhcpcd() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --runstatedir=/run --dbdir=/var/lib/dhcpcd \
        --libexecdir=/usr/lib/dhcpcd
    make && make install
    # 起動スクリプト
    cat > /etc/rc.d/init.d/dhcpcd << 'DHCPEOF'
#!/bin/bash
case $1 in
  start)  dhcpcd -q -b ;;
  stop)   dhcpcd -x ;;
  status) pgrep dhcpcd > /dev/null && echo "running" || echo "stopped" ;;
esac
DHCPEOF
    chmod +x /etc/rc.d/init.d/dhcpcd 2>/dev/null || true
}
build "dhcpcd" "dhcpcd-10.0.10.tar.xz" do_dhcpcd

# ── OpenSSH ──────────────────────────────────────────────────
do_openssh() {
    install -v -g sys -m700 -d /var/lib/sshd
    groupadd -g 50 sshd 2>/dev/null || true
    useradd -c 'sshd PrivSep' -d /var/lib/sshd \
            -g sshd -s /usr/bin/false -u 50 sshd 2>/dev/null || true
    ./configure --prefix=/usr --sysconfdir=/etc/ssh \
        --with-privsep-path=/var/lib/sshd \
        --with-default-path=/usr/bin \
        --with-superuser-path=/usr/sbin:/usr/bin \
        --with-pid-dir=/run
    make && make install
    ssh-keygen -A 2>/dev/null || true
}
build "OpenSSH" "openssh-9.9p1.tar.gz" do_openssh

# ── GRUB ─────────────────────────────────────────────────────
do_grub() {
    unset {C,CPP,CXX,LD}FLAGS
    echo depends bli part_gpt >> grub-core/extra_deps.lst
    ./configure --prefix=/usr          \
        --sysconfdir=/etc              \
        --disable-efiemu               \
        --enable-grub-mkfont           \
        --with-platform=efi            \
        --target=x86_64               \
        --disable-werror
    make && make install
    mv -v /etc/grub.d/50_osprober /etc/grub.d/50_osprober.bak 2>/dev/null || true
}
build "GRUB" "grub-2.12.tar.xz" do_grub

# ── Linux カーネル ────────────────────────────────────────────
do_kernel() {
    make mrproper
    # defconfig ベース（最低限の構成）
    make defconfig
    # 必要な追加設定
    scripts/config --enable CONFIG_EFI_STUB
    scripts/config --enable CONFIG_EFI
    scripts/config --enable CONFIG_FB_EFI
    scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    scripts/config --enable CONFIG_USB_SUPPORT
    scripts/config --enable CONFIG_USB_XHCI_HCD
    scripts/config --enable CONFIG_USB_EHCI_HCD
    scripts/config --enable CONFIG_ATA
    scripts/config --enable CONFIG_AHCI
    scripts/config --enable CONFIG_EXT4_FS
    scripts/config --enable CONFIG_VFAT_FS
    scripts/config --enable CONFIG_NLS_UTF8
    make -j__CPU_CORE__
    make modules_install
    cp -v arch/x86/boot/bzImage /boot/vmlinuz-lfs
    cp -v System.map /boot/System.map-lfs
    cp -v .config    /boot/config-lfs
}
KERNEL_TAR=$(ls ${SRC}/linux-*.tar.* 2>/dev/null | head -1)
if [[ -f "$KERNEL_TAR" ]]; then
    build "Linux Kernel" "$(basename $KERNEL_TAR)" do_kernel
else
    echo "[WARN] Linux カーネルソースが見つかりません（Step2 で取得済みのはずです）"
fi

# ── /etc/profile (環境変数) ───────────────────────────────────
cat > /etc/profile << 'PROFEOF'
# /etc/profile: system-wide shell configuration

export PATH=/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin
export LANG=__LOCALE_NAME__
export LC_ALL=__LOCALE_NAME__
export EDITOR=nano
export PAGER=less
export LESS="-R"
export HISTSIZE=1000
export HISTFILESIZE=2000

# bash-completion
if [[ -f /usr/share/bash-completion/bash_completion ]]; then
    source /usr/share/bash-completion/bash_completion
fi

# カラー表示
alias ls='ls --color=auto'
alias ll='ls -lhA --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
PROFEOF

# ── /root/.bashrc ─────────────────────────────────────────────
cat > /root/.bashrc << 'RCEOF'
# Source global profile
[[ -f /etc/profile ]] && source /etc/profile

PS1='\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

alias la='ls -lhA --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
RCEOF

# ── ロケール / タイムゾーン / ホスト名 ───────────────────────
localedef -i ja_JP -f UTF-8 ja_JP.UTF-8 2>/dev/null || true
localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true

cat > /etc/locale.conf << LOCEOF
LANG=__LOCALE_NAME__
LC_ALL=__LOCALE_NAME__
LOCEOF

echo "lfs" > /etc/hostname

# ── root パスワード ───────────────────────────────────────────
echo "root:__ROOT_PASSWORD__" | chpasswd

# ── /etc/fstab (UUID は morning.sh が設定) ───────────────────
cat > /etc/fstab << 'FSTABEOF'
# UUID をデプロイ時に morning.sh が自動設定します
# UUID=XXXX  /         ext4   defaults,noatime 0 1
# UUID=XXXX  /boot/efi vfat   defaults         0 2
FSTABEOF

echo ""
echo "[CLI] ===== CLI ビルド完了！ ====="
echo "  インストール済みツール:"
echo "    sudo nano git curl wget htop tmux tree"
echo "    bash-completion iproute2 dhcpcd openssh GRUB Linux kernel"
CLIEOF

    sed -i \
        -e "s|__CPU_CORE__|${CPU_CORE}|g"       \
        -e "s|__LOCALE_NAME__|${LOCALE_NAME}|g" \
        -e "s|__ROOT_PASSWORD__|${ROOT_PASSWORD}|g" \
        "${LFS}/tmp/build-cli.sh"
    chmod +x "${LFS}/tmp/build-cli.sh"

    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root TERM="${TERM}" \
        PS1='(cli) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j${CPU_CORE}" \
        /bin/bash /tmp/build-cli.sh \
        2>&1 | tee "/${WS}/cli-build.log" ; true
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "[ERROR] Step6 CLI ビルド失敗。cli-build.log を確認してください。"; exit 1; }

    umount "${LFS}/sources" 2>/dev/null || true
    done_flag step6_cli
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
echo "[DONE] $(date '+%Y-%m-%d %H:%M:%S') CLI LFS ビルド完了！"
echo "  出力: ${OUTPUT_TAR}"
echo "  サイズ: $(du -sh ${OUTPUT_TAR} | cut -f1)"
echo ""
echo "朝起きたら:"
echo "  sudo bash morning.sh"
echo "============================================"
