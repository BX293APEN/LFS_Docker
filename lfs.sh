#!/usr/bin/env bash
# =============================================================================
# lfs.sh  ―  Docker コンテナ内エントリーポイント
# 役割: LFS ソース取得 → クロスツールチェーン → chroot ビルド → tar.gz 出力
#
# 設定は .env を編集してください。スクリプト本体は変更不要です。
#
# 進捗確認 (別ターミナルで)：
#   docker logs -f Docker_LFS
# =============================================================================

set -eo pipefail

# ─────────────────────────────────────────────
# .env → compose.yml environment → ここで受け取る
# 未設定時のデフォルト値
# ─────────────────────────────────────────────
LFS_VERSION="${LFS_VERSION:-12.2}"
LFS_ARCH="${LFS_ARCH:-x86_64}"
LFS_TGT="${LFS_TGT:-x86_64-lfs-linux-gnu}"
LFS_MIRROR="${LFS_MIRROR:-https://www.linuxfromscratch.org/lfs/downloads}"
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

# LFS ソース URL
WGETLIST_URL="${LFS_MIRROR}/${LFS_VERSION}/wget-list-sysv"
MD5SUMS_URL="${LFS_MIRROR}/${LFS_VERSION}/md5sums"

echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') LFS ビルド開始"
echo "  バージョン  : ${LFS_VERSION}"
echo "  アーキ      : ${LFS_ARCH}"
echo "  ターゲット  : ${LFS_TGT}"
echo "  ロケール    : ${LOCALE_NAME}"
echo "  タイムゾーン: ${TZ}"
echo "  並列数      : ${CPU_CORE}"
echo "  出力先      : ${OUTPUT_TAR}"
echo "============================================"

# ビルド済みフラグ確認
if [[ -f "$DONE_FLAG" ]]; then
    echo "[INFO] ビルド済みフラグを検出。スキップします。"
    echo "  削除して再ビルドする場合: rm ${DONE_FLAG}"
    exit 0
fi

mkdir -p "${LFS}" "${FLAG_DIR}"
chmod 777 -R "${FLAG_DIR}"

# =============================================================================
# Step 1: FHS ディレクトリ構造の作成
# =============================================================================
STEP1_FLAG="${FLAG_DIR}/.step1_dirs_done"
if [[ ! -f "${STEP1_FLAG}" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Step1: FHS ディレクトリ作成"
    mkdir -p "${LFS}"/{boot,dev,etc/{opt,sysconfig},home,lib/firmware,lib64,mnt,opt}
    mkdir -p "${LFS}"/{proc,root,run,srv,sys,tmp}
    mkdir -p "${LFS}/usr"/{,local/}{bin,include,lib,lib64,sbin,share,src}
    mkdir -p "${LFS}/usr/share"/{color,dict,doc,info,locale,man}
    mkdir -p "${LFS}/usr/share"/{misc,terminfo,zoneinfo}
    mkdir -p "${LFS}/var"/{cache,lib/{color,locate,misc},local,log,mail,mnt,opt,spool,tmp}

    # FHS 互換シンボリックリンク (usr-merge)
    ln -sfn usr/bin  "${LFS}/bin"
    ln -sfn usr/lib  "${LFS}/lib"
    ln -sfn usr/sbin "${LFS}/sbin"
    ln -sfn ../run   "${LFS}/var/run"
    ln -sfn ../run/lock "${LFS}/var/lock"

    chmod 1777 "${LFS}/tmp" "${LFS}/var/tmp"
    chmod 0750 "${LFS}/root"

    # lfs ユーザー (クロスコンパイル段階で使う)
    groupadd lfs 2>/dev/null || true
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true
    chown lfs:lfs "${LFS}/"{usr,lib,lib64,var,etc,bin,sbin,tools} 2>/dev/null || true
    mkdir -p "${LFS}/tools" && chown lfs:lfs "${LFS}/tools"

    touch "${STEP1_FLAG}"
    echo "[INFO] Step1 完了"
else
    echo "[INFO] Step1 スキップ (済)"
fi

# =============================================================================
# Step 2: ソースパッケージのダウンロード
# =============================================================================
STEP2_FLAG="${FLAG_DIR}/.step2_sources_done"
if [[ ! -f "${STEP2_FLAG}" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Step2: ソースダウンロード"

    mkdir -p "${LFS}/sources"
    chmod a+wt "${LFS}/sources"

    cd "${LFS}/sources"

    echo "[INFO] wget-list を取得: ${WGETLIST_URL}"
    wget -qO wget-list "${WGETLIST_URL}" || {
        echo "[ERROR] wget-list の取得に失敗しました。ミラーURLを確認してください。"
        echo "  URL: ${WGETLIST_URL}"
        exit 1
    }

    echo "[INFO] md5sums を取得"
    wget -qO md5sums "${MD5SUMS_URL}" || true

    echo "[INFO] ソースを並列ダウンロード中... (数十分かかります)"
    wget \
        --continue \
        --input-file=wget-list \
        --directory-prefix="${LFS}/sources" \
        --no-clobber \
        --timeout=60 \
        --tries=3 \
        2>&1 | tee "/${WS}/download.log" || true

    # MD5 チェック
    if [[ -f md5sums ]]; then
        echo "[INFO] MD5 チェックサム検証..."
        md5sum --quiet -c md5sums 2>/dev/null \
            && echo "[INFO] チェックサム OK" \
            || echo "[WARN] 一部ファイルのチェックサムが不一致（ダウンロード失敗の可能性）"
    fi

    touch "${STEP2_FLAG}"
    echo "[INFO] Step2 完了"
else
    echo "[INFO] Step2 スキップ (済)"
fi

# =============================================================================
# Step 3: クロスツールチェーン ビルド (lfs ユーザーで実行)
# =============================================================================
STEP3_FLAG="${FLAG_DIR}/.step3_toolchain_done"
if [[ ! -f "${STEP3_FLAG}" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Step3: クロスツールチェーン ビルド"

    # lfs ユーザー用の bashrc を設定
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

    # クロスツールチェーンビルドスクリプトを生成して lfs ユーザーで実行
    cat > /tmp/build-toolchain.sh << 'TCEOF'
#!/bin/bash
set -eo pipefail
source ~/.bashrc

build_pkg() {
    local name="$1" tarball="$2"
    echo "[TC] $(date '+%H:%M:%S') ビルド開始: ${name}"
    cd "${LFS}/sources"

    # 展開
    local dir
    dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1)
    tar -xf "${tarball}"
    cd "${dir}"
    "$3"   # ビルド関数呼び出し
    cd "${LFS}/sources"
    rm -rf "${dir}"
    echo "[TC] $(date '+%H:%M:%S') 完了: ${name}"
}

# ── Binutils Pass 1 ─────────────────────────────────────────
build_binutils_pass1() {
    mkdir -v build && cd build
    ../configure \
        --prefix="${LFS}/tools" \
        --with-sysroot="${LFS}" \
        --target="${LFS_TGT}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-new-dtags \
        --enable-default-hash-style=gnu
    make
    make install
}
build_pkg "Binutils Pass1" "$(ls ${LFS}/sources/binutils-*.tar.*)" build_binutils_pass1

# ── GCC Pass 1 ──────────────────────────────────────────────
build_gcc_pass1() {
    tar -xf ../mpfr-*.tar.*
    mv -v mpfr-*   mpfr
    tar -xf ../gmp-*.tar.*
    mv -v gmp-*    gmp
    tar -xf ../mpc-*.tar.*
    mv -v mpc-*    mpc

    # x86_64 は lib64 を lib にリダイレクト
    case $(uname -m) in
        x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
    esac

    mkdir -v build && cd build
    ../configure \
        --target="${LFS_TGT}" \
        --prefix="${LFS}/tools" \
        --with-glibc-version=2.40 \
        --with-sysroot="${LFS}" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++
    make
    make install

    # limits.h を生成 (LFS Book 5.3 手順)
    cd ..
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
        "$(dirname "$("${LFS_TGT}-gcc" -print-libgcc-file-name)")/include/limits.h"
}
build_pkg "GCC Pass1" "$(ls ${LFS}/sources/gcc-*.tar.*)" build_gcc_pass1

# ── Linux API Headers ────────────────────────────────────────
build_linux_headers() {
    make mrproper
    make headers
    find usr/include -type f ! -name '*.h' -delete
    cp -rv usr/include "${LFS}/usr"
}
build_pkg "Linux API Headers" "$(ls ${LFS}/sources/linux-*.tar.*)" build_linux_headers

# ── Glibc ───────────────────────────────────────────────────
build_glibc() {
    ln -sfnv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64"
    ln -sfnv ../lib/ld-linux-x86-64.so.2 "${LFS}/lib64/ld-lsb-x86-64.so.3"

    patch -Np1 -i "../$(ls ../glibc-*.patch 2>/dev/null | head -1)" 2>/dev/null || true

    mkdir -v build && cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(../scripts/config.guess)" \
        --enable-kernel=4.19 \
        --with-headers="${LFS}/usr/include" \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib
    make
    make DESTDIR="${LFS}" install

    # ld.so のリンク修正
    sed '/RTLDLIST=/s@/usr@@g' -i "${LFS}/usr/bin/ldd"
}
build_pkg "Glibc" "$(ls ${LFS}/sources/glibc-*.tar.*)" build_glibc

# ── Libstdc++ (GCC の一部) ──────────────────────────────────
build_libstdcpp() {
    mkdir -v build && cd build
    ../libstdc++-v3/configure \
        --host="${LFS_TGT}" \
        --build="$(../config.guess)" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch \
        --with-gxx-include-dir="/tools/${LFS_TGT}/include/c++/$(ls ../gcc/BASE-VER 2>/dev/null || gcc -dumpversion)"
    make
    make DESTDIR="${LFS}" install
    rm -v "${LFS}/usr/lib/lib"{stdc++{,exp},supc++}.la
}
build_pkg "Libstdc++" "$(ls ${LFS}/sources/gcc-*.tar.*)" build_libstdcpp

echo "[TC] クロスツールチェーン ビルド完了"
TCEOF

    chmod +x /tmp/build-toolchain.sh
    su - lfs -c "bash /tmp/build-toolchain.sh" 2>&1 | tee "/${WS}/toolchain.log"

    touch "${STEP3_FLAG}"
    echo "[INFO] Step3 完了"
else
    echo "[INFO] Step3 スキップ (済)"
fi

# =============================================================================
# Step 4: 仮想FS マウント
# =============================================================================
mount_chroot() {
    mountpoint -q "${LFS}/proc" || mount --types proc  /proc "${LFS}/proc"
    mountpoint -q "${LFS}/sys"  || { mount --rbind /sys "${LFS}/sys";  mount --make-rslave "${LFS}/sys"; }
    mountpoint -q "${LFS}/dev"  || { mount --rbind /dev "${LFS}/dev";  mount --make-rslave "${LFS}/dev"; }
    mountpoint -q "${LFS}/run"  || mount --bind   /run "${LFS}/run"
}

cleanup() {
    echo "[INFO] クリーンアップ中..."
    umount -R "${LFS}/dev"  2>/dev/null || true
    umount -R "${LFS}/sys"  2>/dev/null || true
    umount    "${LFS}/run"  2>/dev/null || true
    umount    "${LFS}/proc" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# Step 5: chroot 内でのシステムビルド
# =============================================================================
STEP5_FLAG="${FLAG_DIR}/.step5_chroot_done"
if [[ ! -f "${STEP5_FLAG}" ]]; then
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Step5: chroot 内システムビルド (数時間かかります)"

    mount_chroot
    cp /etc/resolv.conf "${LFS}/etc/resolv.conf"

    # chroot 内で実行するスクリプトを生成 (Gentooと同じ __PLACEHOLDER__ sed 方式)
    cat > "${LFS}/tmp/inside-chroot.sh" << 'INNEREOF'
#!/bin/bash
set -eo pipefail
export MAKEFLAGS="-j__CPU_CORE__"
export TERM=xterm

echo "[CHROOT] 基本的な /etc ファイルを作成"

# /etc/hosts
cat > /etc/hosts << 'EOF'
127.0.0.1  localhost
::1        localhost
EOF

# /etc/passwd
cat > /etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

# /etc/group
cat > /etc/group << 'EOF'
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
usb:x:14:
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
chgrp -v utmp /var/log/lastlog
chmod -v 664  /usr/bin/sudo /var/log/lastlog  2>/dev/null || true
chmod -v 600  /var/log/btmp

echo "[CHROOT] Gettext インストール"
cd /sources
tar -xf gettext-*.tar.*
cd gettext-*/
./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
cd /sources && rm -rf gettext-*/

echo "[CHROOT] Bison インストール"
tar -xf bison-*.tar.*
cd bison-*/
./configure --prefix=/usr --docdir=/usr/share/doc/bison-$(cat doc/version.texi | head -1 | awk '{print $2}')
make
make install
cd /sources && rm -rf bison-*/

echo "[CHROOT] Perl インストール"
tar -xf perl-*.tar.*
cd perl-*/
sh Configure -des                                         \
    -D prefix=/usr                                        \
    -D vendorprefix=/usr                                  \
    -D privlib=/usr/lib/perl5/5.40/core_perl             \
    -D archlib=/usr/lib/perl5/5.40/core_perl             \
    -D sitelib=/usr/lib/perl5/5.40/site_perl             \
    -D sitearch=/usr/lib/perl5/5.40/site_perl            \
    -D vendorlib=/usr/lib/perl5/5.40/vendor_perl         \
    -D vendorarch=/usr/lib/perl5/5.40/vendor_perl        \
    -D man1dir=/usr/share/man/man1                        \
    -D man3dir=/usr/share/man/man3                        \
    -D pager="/usr/bin/less -isR"                         \
    -D useshrplib                                         \
    -D usethreads
make
make install
cd /sources && rm -rf perl-*/

echo "[CHROOT] Python インストール"
tar -xf Python-*.tar.*
cd Python-*/
./configure --prefix=/usr   \
    --enable-shared         \
    --without-ensurepip
make
make install
cd /sources && rm -rf Python-*/

echo "[CHROOT] Texinfo インストール"
tar -xf texinfo-*.tar.*
cd texinfo-*/
./configure --prefix=/usr
make
make install
cd /sources && rm -rf texinfo-*/

echo "[CHROOT] Util-linux インストール"
mkdir -pv /var/lib/hwclock
tar -xf util-linux-*.tar.*
cd util-linux-*/
./configure --libdir=/usr/lib         \
    --runstatedir=/run                \
    --disable-chfn-chsh               \
    --disable-login                   \
    --disable-nologin                 \
    --disable-su                      \
    --disable-setpriv                 \
    --disable-runuser                 \
    --disable-pylibmount              \
    --disable-static                  \
    --disable-liblastlog2             \
    --without-python                  \
    ADJTIME_PATH=/var/lib/hwclock/adjtime
make
make install
cd /sources && rm -rf util-linux-*/

echo "[CHROOT] ソースのクリーンアップ"
rm -rf /sources/{*.tar.*,*.patch} 2>/dev/null || true

echo "[CHROOT] タイムゾーン設定"
ln -sfv "/usr/share/zoneinfo/__TZ__" /etc/localtime

echo "[CHROOT] ロケール設定"
cat > /etc/locale.conf << 'LOCEOF'
LANG=__LOCALE_NAME__
LOCEOF

echo "[CHROOT] hostname 設定"
echo "lfs" > /etc/hostname

echo "[CHROOT] /etc/fstab (最小構成)"
cat > /etc/fstab << 'FSTABEOF'
# <fs>         <mountpoint>  <type>    <opts>           <dump> <pass>
# デプロイ時に UUID を書き換えてください (morning.sh が自動設定します)
# UUID=XXXX    /             ext4      defaults,noatime  0      1
FSTABEOF

echo "[CHROOT] root パスワード設定"
echo "root:__ROOT_PASSWORD__" | chpasswd

echo "[CHROOT] 完了"
INNEREOF

    # プレースホルダーを実際の値に置換 (Gentooと同じ sed 方式)
    sed -i \
        -e "s|__CPU_CORE__|${CPU_CORE}|g"           \
        -e "s|__TZ__|${TZ}|g"                       \
        -e "s|__LOCALE_NAME__|${LOCALE_NAME}|g"     \
        -e "s|__ROOT_PASSWORD__|${ROOT_PASSWORD}|g" \
        "${LFS}/tmp/inside-chroot.sh"

    # sources を chroot 内から見えるようシンボリックリンク
    ln -sfn "${LFS}/sources" "${LFS}/sources" 2>/dev/null || true
    # chroot 用に sources をバインドマウント
    mkdir -p "${LFS}/sources"
    mountpoint -q "${LFS}/sources" || \
        mount --bind "${LFS}/sources" "${LFS}/sources"

    chmod +x "${LFS}/tmp/inside-chroot.sh"
    echo "[INFO] chroot ビルド実行中..."
    chroot "${LFS}" /usr/bin/env -i \
        HOME=/root                  \
        TERM="${TERM}"              \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin     \
        MAKEFLAGS="-j${CPU_CORE}"   \
        /bin/bash /tmp/inside-chroot.sh \
        2>&1 | tee "/${WS}/chroot-build.log"

    umount "${LFS}/sources" 2>/dev/null || true
    touch "${STEP5_FLAG}"
    echo "[INFO] Step5 完了"
else
    echo "[INFO] Step5 スキップ (済)"
fi

# =============================================================================
# Step 6: tar.gz に固める
# =============================================================================
cleanup
trap - EXIT

echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') tar.gz 作成中..."
tar czpf "${OUTPUT_TAR}"         \
    --one-file-system            \
    --numeric-owner              \
    --preserve-permissions       \
    --sparse                     \
    --exclude="${LFS}/sources"   \
    --exclude="${LFS}/tools"     \
    -C "/${WS}"                  \
    lfs-rootfs

# SHA256 チェックサム
sha256sum "${OUTPUT_TAR}" > "${OUTPUT_TAR}.sha256"

date '+%Y-%m-%d %H:%M:%S' > "${DONE_FLAG}"

echo ""
echo "============================================"
echo "[DONE] $(date '+%Y-%m-%d %H:%M:%S') ビルド完了！"
echo "  出力: ${OUTPUT_TAR}"
echo "  サイズ: $(du -sh ${OUTPUT_TAR} | cut -f1)"
echo "  SHA256: $(cat ${OUTPUT_TAR}.sha256)"
echo ""
echo "朝起きたら:"
echo "  sudo bash morning.sh"
echo "============================================"
