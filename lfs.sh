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

# ── ミラーリスト（.env のスペース区切り文字列 → bash 配列に変換）────────────
# .env で未設定の場合のデフォルト値も兼ねる
read -ra LFS_MIRRORS     <<< "${LFS_MIRRORS:-https://ftp.osuosl.org/pub/lfs/lfs-packages/${LFS_VERSION} https://www.linuxfromscratch.org/lfs/downloads https://ftp.lfs-matrix.net/pub/lfs/lfs-packages/${LFS_VERSION}}"
read -ra GNU_MIRRORS     <<< "${GNU_MIRRORS:-https://ftpmirror.gnu.org https://ftp.jaist.ac.jp/pub/GNU https://ftp.iij.ad.jp/pub/gnu https://mirrors.kernel.org/gnu https://ftp.gnu.org/gnu}"
read -ra GCC_INFRA_MIRRORS <<< "${GCC_INFRA_MIRRORS:-https://gcc.gnu.org/pub/gcc/infrastructure}"

# ── wget-list の各URLに対して CLI_URL_<ファイル名> で上書き可能にする辞書 ──
# キー: ファイル名（basename）, 値: スペース区切りのURLリスト
# .env の CLI_URL_EXPAT 等が設定されていればそちらを使う
declare -A PKG_URL_OVERRIDE
_load_pkg_override() {
    local fname="$1" envvar="$2"
    local val="${!envvar:-}"
    if [[ -n "${val}" ]]; then
        PKG_URL_OVERRIDE["${fname}"]="${val}"
    fi
}
# wget-list に含まれうるパッケージと対応する CLI_URL_* を登録
_load_pkg_override "expat-2.6.2.tar.xz"             "CLI_URL_EXPAT"
_load_pkg_override "libpipeline-1.5.0.tar.gz"        "CLI_URL_LIBPIPELINE"
_load_pkg_override "groff-1.23.0.tar.gz"             "CLI_URL_GROFF"
_load_pkg_override "sudo-1.9.15p5.tar.gz"            "CLI_URL_SUDO"
_load_pkg_override "nano-8.3.tar.xz"                 "CLI_URL_NANO"
_load_pkg_override "curl-8.11.1.tar.xz"              "CLI_URL_CURL"
_load_pkg_override "pcre2-10.44.tar.bz2"             "CLI_URL_PCRE2"
_load_pkg_override "git-2.47.2.tar.xz"               "CLI_URL_GIT"
_load_pkg_override "htop-3.3.0.tar.xz"               "CLI_URL_HTOP"
_load_pkg_override "libevent-2.1.12-stable.tar.gz"   "CLI_URL_LIBEVENT"
_load_pkg_override "tmux-3.5a.tar.gz"                "CLI_URL_TMUX"
_load_pkg_override "tree-2.1.3.tgz"                  "CLI_URL_TREE"
_load_pkg_override "bash-completion-2.14.0.tar.xz"   "CLI_URL_BASH_COMPLETION"
_load_pkg_override "dbus-1.15.8.tar.xz"              "CLI_URL_DBUS"
_load_pkg_override "iproute2-6.12.0.tar.xz"          "CLI_URL_IPROUTE2"
_load_pkg_override "dhcpcd-10.0.10.tar.xz"           "CLI_URL_DHCPCD"
_load_pkg_override "openssh-9.9p1.tar.gz"            "CLI_URL_OPENSSH"
_load_pkg_override "libgpg-error-1.50.tar.bz2"       "CLI_URL_LIBGPG_ERROR"
_load_pkg_override "libgcrypt-1.11.0.tar.bz2"        "CLI_URL_LIBGCRYPT"
_load_pkg_override "grub-2.12.tar.xz"                "CLI_URL_GRUB"
_load_pkg_override "libpng-1.6.44.tar.xz"            "CLI_URL_LIBPNG"
_load_pkg_override "freetype-2.13.3.tar.xz"          "CLI_URL_FREETYPE"
_load_pkg_override "unifont-15.1.04.bdf.gz"       "CLI_URL_UNIFONT"
_load_pkg_override "kbd-2.6.4.tar.xz"             "CLI_URL_KBD"
_load_pkg_override "which-2.21.tar.gz"             "CLI_URL_WHICH"
_load_pkg_override "wget-1.25.0.tar.gz"            "CLI_URL_WGET"

DL_RETRIES="${DL_RETRIES:-3}"
DL_TIMEOUT="${DL_TIMEOUT:-90}"
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
# =============================================================================
# smart_wget: ミラーフォールバック + リトライ + 失敗フラグ生成
#
# smart_wget <出力ファイル名> <URL> [<URL> ...]
#   → 指定URLを順番に試す（各URL DL_RETRIES 回リトライ）
#   → 全失敗時: FLAGS/dl_failed_<名前> を生成して return 1
#
# smart_wget_lfs <出力ファイル名> <相対パス>
#   → LFS_MIRRORS の各ミラー + 相対パスを試す
#
# smart_wget_gnu <出力ファイル名> <GNUサブディレクトリ>
#   → GNU_MIRRORS + GCC_INFRA_MIRRORS を試す
# =============================================================================
smart_wget() {
    local dest="$1"; shift
    local urls=("$@")
    local flag_fail="${FLAG_DIR}/dl_failed_${dest//\//_}"

    if [[ -s "${dest}" ]]; then
        log_info "  [SKIP] ${dest} 取得済み"
        rm -f "${flag_fail}"
        return 0
    fi

    for url in "${urls[@]}"; do
        local attempt=0
        while (( attempt < DL_RETRIES )); do
            (( attempt++ ))
            echo "  [TRY ${attempt}/${DL_RETRIES}] ${url}"
            if wget -q --timeout="${DL_TIMEOUT}" --tries=1 \
                   -O "${dest}.tmp" "${url}" 2>/dev/null \
               && [[ -s "${dest}.tmp" ]]; then
                mv "${dest}.tmp" "${dest}"
                log_info "  [OK] ${dest} ← ${url}"
                rm -f "${flag_fail}"
                return 0
            fi
            rm -f "${dest}.tmp"
            [[ ${attempt} -lt ${DL_RETRIES} ]] && sleep 2
        done
        echo "  [FAIL] ${url}"
    done

    echo "[WARN] ${dest} の取得に全ミラーで失敗しました"
    touch "${flag_fail}"
    return 1
}

smart_wget_lfs() {
    local dest="$1" rel="$2"
    local urls=()
    for m in "${LFS_MIRRORS[@]}"; do urls+=("${m}/${rel}"); done
    smart_wget "${dest}" "${urls[@]}"
}

# GNU_MIRRORS + GCC_INFRA_MIRRORS を試す
# 使い方: smart_wget_gnu <ファイル名> <gnuサブディレクトリ>
# 例: smart_wget_gnu mpfr-4.2.1.tar.xz mpfr
smart_wget_gnu() {
    local dest="$1" subdir="$2"
    local urls=()
    for m in "${GNU_MIRRORS[@]}";       do urls+=("${m}/${subdir}/${dest}"); done
    for m in "${GCC_INFRA_MIRRORS[@]}"; do urls+=("${m}/${dest}"); done
    smart_wget "${dest}" "${urls[@]}"
}

# 後方互換 (mirror_wget を使っている箇所向け)
mirror_wget() { smart_wget_lfs "$2" "$1"; }

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

    # ── wget-list 取得 ────────────────────────────────────────────────────────
    log_info "wget-list 取得中..."
    smart_wget_lfs "wget-list" "${LFS_VERSION}/wget-list-systemd" || \
    smart_wget_lfs "wget-list" "${LFS_VERSION}/wget-list" || \
        { echo "[ERROR] wget-list が取得できませんでした。.env の LFS_MIRRORS を確認してください。"; exit 1; }

    smart_wget_lfs "md5sums" "${LFS_VERSION}/md5sums" || true

    # ── wget-list に記載されたパッケージを smart_wget で1件ずつ取得 ────────────
    # wget --input-file は失敗してもエラーが埋もれるため、1件ずつ管理する
    log_info "ソースパッケージ ダウンロード中（${DL_RETRIES}回リトライ付き）..."
    dl_fail_count=0
    while IFS= read -r pkg_url || [[ -n "${pkg_url}" ]]; do
        [[ -z "${pkg_url}" || "${pkg_url}" =~ ^# ]] && continue
        pkg_file=$(basename "${pkg_url}")

        # ① .env の CLI_URL_* で上書き指定があればそちらを優先
        if [[ -n "${PKG_URL_OVERRIDE[${pkg_file}]+x}" ]]; then
            read -ra override_urls <<< "${PKG_URL_OVERRIDE[${pkg_file}]}"
            smart_wget "${pkg_file}" "${override_urls[@]}" || (( dl_fail_count++ )) || true

        # ② ftp.gnu.org は到達不可の場合があるため GNU_MIRRORS でフォールバック
        elif [[ "${pkg_url}" == *"ftp.gnu.org/gnu/"* ]]; then
            gnu_subpath="${pkg_url#*ftp.gnu.org/gnu/}"
            fallback_urls=()
            for m in "${GNU_MIRRORS[@]}"; do fallback_urls+=("${m}/${gnu_subpath}"); done
            for m in "${GCC_INFRA_MIRRORS[@]}"; do fallback_urls+=("${m}/${pkg_file}"); done
            smart_wget "${pkg_file}" "${fallback_urls[@]}" || (( dl_fail_count++ )) || true

        # ③ その他は wget-list のURLをそのまま使用
        else
            smart_wget "${pkg_file}" "${pkg_url}" || (( dl_fail_count++ )) || true
        fi
    done < wget-list
    log_info "一括ダウンロード完了（失敗: ${dl_fail_count} 件）"

    # ── GCC 依存ライブラリ（mpfr / gmp / mpc）の確実な取得 ──────────────────
    # wget-list の URL が ftp.gnu.org 直接指定で失敗する場合に GNU_MIRRORS で補完
    log_info "GCC 依存ライブラリ（mpfr/gmp/mpc）確認・補完..."
    # 書式: "ファイル名 gnuサブディレクトリ"
    GCC_DEPS=(
        "mpfr-4.2.1.tar.xz mpfr"
        "gmp-6.3.0.tar.xz  gmp"
        "mpc-1.3.1.tar.gz  mpc"
    )
    for dep_info in "${GCC_DEPS[@]}"; do
        dep_file=$(echo "${dep_info}" | awk '{print $1}')
        dep_sub=$( echo "${dep_info}" | awk '{print $2}')
        smart_wget_gnu "${dep_file}" "${dep_sub}" || true
    done

    # ── expat フォールバック（wget-list に無いバージョンの場合）──────────────
    if [[ ! -s "expat-2.6.2.tar.xz" ]]; then
        log_info "expat-2.6.2.tar.xz を取得中..."
        read -ra _URL_EXPAT_S2 <<< "${CLI_URL_EXPAT:-https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz}"
        smart_wget "expat-2.6.2.tar.xz" "${_URL_EXPAT_S2[@]}" || true
    fi

    # ── libpipeline フォールバック（man-db の必須依存ライブラリ）────────────
    if [[ ! -s "libpipeline-1.5.0.tar.gz" ]]; then
        log_info "libpipeline-1.5.0.tar.gz を取得中..."
        read -ra _URL_LIBPIPELINE_S2 <<< "${CLI_URL_LIBPIPELINE:-https://download.savannah.gnu.org/releases/libpipeline/libpipeline-1.5.0.tar.gz https://www.linuxfromscratch.org/lfs/downloads/12.2/libpipeline-1.5.0.tar.gz}"
        smart_wget "libpipeline-1.5.0.tar.gz" "${_URL_LIBPIPELINE_S2[@]}" || true
    fi

    # ── groff フォールバック（man-db の soelim/tbl 依存）────────────────────
    if [[ ! -s "groff-1.23.0.tar.gz" ]]; then
        log_info "groff-1.23.0.tar.gz を取得中..."
        read -ra _URL_GROFF_S2 <<< "${CLI_URL_GROFF:-https://ftp.gnu.org/gnu/groff/groff-1.23.0.tar.gz https://mirrors.kernel.org/gnu/groff/groff-1.23.0.tar.gz https://ftpmirror.gnu.org/groff/groff-1.23.0.tar.gz}"
        smart_wget "groff-1.23.0.tar.gz" "${_URL_GROFF_S2[@]}" || true
    fi

    # ── expect gcc14 パッチ フォールバック ──────────────────────────────────
    # LFS 12.2 の wget-list に含まれているはずだが、取得できていない場合に補完する
    if [[ ! -s "expect-5.45.4-gcc14-1.patch" ]]; then
        log_info "expect-5.45.4-gcc14-1.patch を取得中..."
        smart_wget "expect-5.45.4-gcc14-1.patch" \
            "https://www.linuxfromscratch.org/patches/lfs/12.2/expect-5.45.4-gcc14-1.patch" \
            "https://ftp.lfs-matrix.net/pub/lfs/lfs-packages/12.2/expect-5.45.4-gcc14-1.patch" || true
    fi

    # ── 失敗フラグの集計・報告 ──────────────────────────────────────────────
    mapfile -t failed_flags < <(ls "${FLAG_DIR}"/dl_failed_* 2>/dev/null || true)
    if [[ ${#failed_flags[@]} -gt 0 ]]; then
        echo ""
        echo "[WARN] ========================================================"
        echo "[WARN] 以下のパッケージのダウンロードに失敗しました:"
        for f in "${failed_flags[@]}"; do
            echo "[WARN]   $(basename "${f}" | sed 's/^dl_failed_//')"
        done
        echo "[WARN] ========================================================"
        echo "[WARN] 対処方法:"
        echo "[WARN]   1. .env の LFS_MIRRORS / GNU_MIRRORS を変更して再試行"
        echo "[WARN]   2. 手動で ./build/lfs-rootfs/sources/ にファイルを置く"
        echo "[WARN]   3. rm build/flags/step2_sources && docker compose up"
        echo ""
        echo "[WARN] ビルドを続行しますが、該当パッケージのビルドで失敗する可能性があります。"
    fi

    # ── md5 チェック ────────────────────────────────────────────────────────
    if [[ -f md5sums ]]; then
        log_info "MD5 チェック中..."
        BAD=$(md5sum -c md5sums 2>/dev/null | grep "FAILED" | sed 's/: FAILED//' || true)
        if [[ -z "${BAD}" ]]; then
            log_info "MD5 OK: 全ファイル正常"
        else
            echo "[WARN] MD5 不一致（破損の可能性あり）:"
            echo "${BAD}"
        fi
    fi

    done_flag step2_sources
    log_info "Step2 完了"
else
    log_skip "Step2"
fi

# =============================================================================
# lfs ユーザーの ~/.bashrc: フラグに関わらず毎回再生成する
# (コンテナ再起動で /home/lfs がリセットされる可能性があるため)
# =============================================================================
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

log_info "lfs .bashrc 生成済: LFS=${LFS} LFS_TGT=${LFS_TGT}"

# =============================================================================
# Step 3: クロスツールチェーン (lfs ユーザー)
# =============================================================================
if ! flagged step3_toolchain; then
    log_step "Step3: クロスツールチェーン ビルド"

    # .bashrc の展開結果をログに出力して確認
    log_info "[DEBUG] /home/lfs/.bashrc の内容:"
    cat /home/lfs/.bashrc

    # build-toolchain.sh を lfs がアクセスできる場所に配置
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
    if [[ -z "${tarball}" || ! -f "${tarball}" ]]; then
        echo "[ERROR] pkg_build ${name}: tarball が見つかりません: '${tarball:-<空>}'"
        ls "${LFS}/sources/" 2>/dev/null | head -20 || true
        exit 1
    fi
    echo "[TC] $(date '+%H:%M:%S') ${name}"
    cd "${LFS}/sources"
    local dir; dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    # 前回の失敗で残ったディレクトリを削除してからクリーンに展開する
    [[ -n "${dir}" ]] && rm -rf "${dir}"
    tar -xf "${tarball}"
    cd "${dir}"
    ${fn}
    cd "${LFS}/sources"
    rm -rf "${dir}"
}

do_binutils_p1() {
    mkdir -p build && cd build
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
    mkdir -p build && cd build
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
    # lib64 はディレクトリとして存在している必要がある（Step1 で作成済み）
    # その中に ld-linux の symlink を作成する（ディレクトリ自体をリンクにしない）
    mkdir -p "${LFS}/lib64"
    ln -sfnv ../usr/lib/ld-linux-x86-64.so.2 "${LFS}/lib64/ld-linux-x86-64.so.2"
    ln -sfnv ../usr/lib/ld-linux-x86-64.so.2 "${LFS}/lib64/ld-lsb-x86-64.so.3"
    patch -Np1 -i "../$(ls ../glibc-*.patch 2>/dev/null | head -1)" 2>/dev/null || true
    rm -rf build && mkdir -p build && cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(../scripts/config.guess)" --enable-kernel=4.19 \
        --with-headers="${LFS}/usr/include" --disable-nscd \
        libc_cv_slibdir=/usr/lib
    make && make DESTDIR="${LFS}" install
    sed '/RTLDLIST=/s@/usr@@g' -i "${LFS}/usr/bin/ldd"
}

do_libstdcpp() {
    mkdir -p build && cd build
    ../libstdc++-v3/configure --host="${LFS_TGT}" \
        --build="$(../config.guess)" --prefix=/usr \
        --disable-multilib --disable-nls --disable-libstdcxx-pch \
        --with-gxx-include-dir="/tools/${LFS_TGT}/include/c++/$(cat ../gcc/BASE-VER)"
    make && make DESTDIR="${LFS}" install
    rm -v "${LFS}/usr/lib/lib"{stdc++{,exp},supc++}.la 2>/dev/null || true
}

pkg_build "Binutils Pass1"    "$(ls ${LFS}/sources/binutils-*.tar.* 2>/dev/null | head -1)"  do_binutils_p1
pkg_build "GCC Pass1"         "$(ls ${LFS}/sources/gcc-*.tar.* 2>/dev/null | head -1)"       do_gcc_p1
pkg_build "Linux API Headers" "$(ls ${LFS}/sources/linux-*.tar.* 2>/dev/null | head -1)"     do_linux_headers
pkg_build "Glibc"             "$(ls ${LFS}/sources/glibc-*.tar.* 2>/dev/null | head -1)"     do_glibc
pkg_build "Libstdc++"         "$(ls ${LFS}/sources/gcc-*.tar.* 2>/dev/null | head -1)"       do_libstdcpp

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
    if [[ -z "${tarball}" || ! -f "${tarball}" ]]; then
        echo "[ERROR] tt_build ${name}: tarball が見つかりません: '${tarball:-<空>}'"
        ls "${SRC}/" 2>/dev/null | head -20 || true
        exit 1
    fi
    echo "[TT] $(date '+%H:%M:%S') ${name}"
    cd "${SRC}"
    local dir; dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    [[ -z "${dir}" ]] && { echo "[ERROR] tarball 展開失敗: ${tarball}"; exit 1; }
    # 前回の失敗で残ったディレクトリを削除してからクリーンに展開する
    rm -rf "${dir}"
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
tt_build "M4" "$(ls ${SRC}/m4-*.tar.* 2>/dev/null | head -1)" do_m4

# ── Ncurses ─────────────────────────────────────────────────
do_ncurses() {
    sed -i s/mawk// configure
    mkdir -p build && cd build
    ../configure
    make -C include && make -C progs tic
    cd ..
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./config.guess)" --mandir=/usr/share/man \
        --with-manpage-format=normal --with-shared --without-normal \
        --with-cxx-shared --without-debug --without-ada \
        --disable-stripping
    make && make DESTDIR="${LFS}" TIC_PATH="${LFS}/sources/ncurses-*/build/progs/tic" install
    ln -sfv libncursesw.so "${LFS}/usr/lib/libncurses.so"
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "${LFS}/usr/include/curses.h" 2>/dev/null || true
}
tt_build "Ncurses" "$(ls ${SRC}/ncurses-*.tar.* 2>/dev/null | head -1)" do_ncurses

# ── Bash ────────────────────────────────────────────────────
do_bash() {
    ./configure --prefix=/usr --build="$(sh support/config.guess)" \
        --host="${LFS_TGT}" --without-bash-malloc \
        bash_cv_strtold_broken=no
    make && make DESTDIR="${LFS}" install
    ln -sfv bash "${LFS}/bin/sh" 2>/dev/null || true
}
tt_build "Bash" "$(ls ${SRC}/bash-*.tar.* 2>/dev/null | head -1)" do_bash

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
tt_build "Coreutils" "$(ls ${SRC}/coreutils-*.tar.* 2>/dev/null | head -1)" do_coreutils

# ── Diffutils ───────────────────────────────────────────────
do_diffutils() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Diffutils" "$(ls ${SRC}/diffutils-*.tar.* 2>/dev/null | head -1)" do_diffutils

# ── File ────────────────────────────────────────────────────
do_file() {
    mkdir -p build && cd build
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
tt_build "File" "$(ls ${SRC}/file-*.tar.* 2>/dev/null | head -1)" do_file

# ── Findutils ───────────────────────────────────────────────
do_findutils() {
    ./configure --prefix=/usr --localstatedir=/var/lib/locate \
        --host="${LFS_TGT}" --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Findutils" "$(ls ${SRC}/findutils-*.tar.* 2>/dev/null | head -1)" do_findutils

# ── Gawk ────────────────────────────────────────────────────
do_gawk() {
    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Gawk" "$(ls ${SRC}/gawk-*.tar.* 2>/dev/null | head -1)" do_gawk

# ── Grep ────────────────────────────────────────────────────
do_grep() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Grep" "$(ls ${SRC}/grep-*.tar.* 2>/dev/null | head -1)" do_grep

# ── Gzip ────────────────────────────────────────────────────
do_gzip() {
    ./configure --prefix=/usr --host="${LFS_TGT}"
    make && make DESTDIR="${LFS}" install
}
tt_build "Gzip" "$(ls ${SRC}/gzip-*.tar.* 2>/dev/null | head -1)" do_gzip

# ── Make ────────────────────────────────────────────────────
do_make() {
    ./configure --prefix=/usr --without-guile \
        --host="${LFS_TGT}" --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Make" "$(ls ${SRC}/make-*.tar.* 2>/dev/null | head -1)" do_make

# ── Patch ───────────────────────────────────────────────────
do_patch() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Patch" "$(ls ${SRC}/patch-*.tar.* 2>/dev/null | head -1)" do_patch

# ── Sed ─────────────────────────────────────────────────────
do_sed() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(./build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Sed" "$(ls ${SRC}/sed-*.tar.* 2>/dev/null | head -1)" do_sed

# ── Tar ─────────────────────────────────────────────────────
do_tar() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)"
    make && make DESTDIR="${LFS}" install
}
tt_build "Tar" "$(ls ${SRC}/tar-*.tar.* 2>/dev/null | head -1)" do_tar

# ── Xz ──────────────────────────────────────────────────────
do_xz() {
    ./configure --prefix=/usr --host="${LFS_TGT}" \
        --build="$(build-aux/config.guess)" \
        --disable-static --docdir=/usr/share/doc/xz
    make && make DESTDIR="${LFS}" install
    rm -v "${LFS}/usr/lib/liblzma.la" 2>/dev/null || true
}
tt_build "Xz" "$(ls ${SRC}/xz-*.tar.* 2>/dev/null | head -1)" do_xz

# ── Binutils Pass2 ──────────────────────────────────────────
do_binutils_p2() {
    sed '6009s/$add_dir//' -i ltmain.sh
    mkdir -p build && cd build
    ../configure --prefix=/usr --build="$(../config.guess)" \
        --host="${LFS_TGT}" --disable-nls --enable-shared \
        --enable-gprofng=no --disable-werror \
        --enable-64-bit-bfd --enable-new-dtags \
        --enable-default-hash-style=gnu
    make && make DESTDIR="${LFS}" install
    rm -v "${LFS}"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la} 2>/dev/null || true
}
tt_build "Binutils Pass2" "$(ls ${SRC}/binutils-*.tar.* 2>/dev/null | head -1)" do_binutils_p2

# ── GCC Pass2 ───────────────────────────────────────────────
do_gcc_p2() {
    tar -xf ../mpfr-*.tar.* && mv mpfr-* mpfr
    tar -xf ../gmp-*.tar.*  && mv gmp-*  gmp
    tar -xf ../mpc-*.tar.*  && mv mpc-*  mpc
    case $(uname -m) in x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;; esac
    sed '/thread_header =/s/@.*@/gthr-posix.h/' \
        -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
    mkdir -p build && cd build
    ../configure --build="$(../config.guess)" \
        --host="${LFS_TGT}" --target="${LFS_TGT}" \
        LDFLAGS_FOR_TARGET="-L${PWD}/${LFS_TGT}/libgcc" \
        --prefix=/usr --with-build-sysroot="${LFS}" \
        --enable-default-pie --enable-default-ssp \
        --disable-nls --disable-multilib --disable-libatomic \
        --disable-libgomp --disable-libquadmath --disable-libsanitizer \
        --disable-libssp --disable-libvtv --enable-languages=c,c++
    make && make DESTDIR="${LFS}" install
    ln -sfv gcc "${LFS}/usr/bin/cc" 2>/dev/null || true
}
tt_build "GCC Pass2" "$(ls ${SRC}/gcc-*.tar.* 2>/dev/null | head -1)" do_gcc_p2

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
    if [[ -z "${tarball}" || ! -f "${SRC}/${tarball}" && ! -f "${tarball}" ]]; then
        echo "[ERROR] build ${name}: tarball が見つかりません: '${tarball:-<空>}'"
        ls "${SRC}/" 2>/dev/null | head -20 || true
        exit 1
    fi
    echo "[BASE] $(date '+%H:%M:%S') ${name}"
    cd "${SRC}"
    local dir; dir=$(tar -tf "${tarball}" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    # 前回の失敗で残ったディレクトリを削除してからクリーンに展開する
    [[ -n "${dir}" ]] && rm -rf "${dir}"
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
build "Man-pages" "$(ls ${SRC}/man-pages-*.tar.* 2>/dev/null | head -1)" do_manpages

# ── Iana-etc ────────────────────────────────────────────────
do_iana() { cp services protocols /etc/; }
build "Iana-etc" "$(ls ${SRC}/iana-etc-*.tar.* 2>/dev/null | head -1)" do_iana

# ── Bison (Glibc-final の configure が必須ツールとして要求) ──
# glibc 2.40+ の configure は bison を "critical" として扱うため
# Glibc-final より先にビルドする必要がある
do_bison_early() {
    ./configure --prefix=/usr --docdir=/usr/share/doc/bison-$(basename $(pwd) | sed 's/bison-//')
    make && make install
}
build "Bison-early" "$(ls ${SRC}/bison-*.tar.* 2>/dev/null | head -1)" do_bison_early

# ── Python-early (Glibc-final の configure が必須ツールとして要求) ──
# glibc 2.40+ の configure は python3 を "critical" として扱うため
# Glibc-final より先にビルドする必要がある
do_python_early() {
    # chroot 初期環境では expat / libffi / openssl 等がまだないため
    # 最低限のフラグで interpreter のみビルドする
    ./configure --prefix=/usr           \
        --enable-shared                 \
        --without-ensurepip             \
        --with-system-expat=no          \
        --with-system-ffi=no            \
        --disable-optimizations
    make && make install
    # python コマンドへの symlink (glibc configure が python3 と python の両方を探す)
    ln -sfv python3 /usr/bin/python 2>/dev/null || true
}
build "Python-early" "$(ls ${SRC}/Python-*.tar.* 2>/dev/null | head -1)" do_python_early

# ── Glibc (final) ───────────────────────────────────────────
do_glibc_final() {
    patch -Np1 -i "../$(ls ../glibc-*.patch 2>/dev/null | head -1)" 2>/dev/null || true
    rm -rf build && mkdir -p build && cd build
    echo "rootsbindir=/usr/sbin" > configparms
    ../configure --prefix=/usr --disable-werror \
        --enable-kernel=4.19 --enable-stack-protector=strong \
        --disable-nscd libc_cv_slibdir=/usr/lib
    # test-installation.pl は chroot内に libnss_files 等が存在しないためリンクエラーになる。
    # LFS Book 12.2公式手順: ソースルートの ../Makefile のtest-installation行をコメントアウト。
    # (現在地は build/ サブディレクトリなので対象は ../Makefile)
    sed '/test-installation/s/^/: #/' -i ../Makefile
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
build "Glibc-final" "$(ls ${SRC}/glibc-*.tar.* 2>/dev/null | head -1)" do_glibc_final

# ── Zlib ────────────────────────────────────────────────────
do_zlib() {
    ./configure --prefix=/usr
    make && make install
    rm -fv /usr/lib/libz.a
}
build "Zlib" "$(ls ${SRC}/zlib-*.tar.* 2>/dev/null | head -1)" do_zlib

# ── Bzip2 ───────────────────────────────────────────────────
do_bzip2() {
    patch -Np1 -i ../bzip2-*.patch 2>/dev/null || true
    sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
    sed -i "s|man, doc|share/man, share/doc|g" Makefile
    make -f Makefile-libbz2_so && make clean
    make && make PREFIX=/usr install
    cp -av libbz2.so.* /usr/lib
    ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so
    cp -v bzip2-shared /usr/bin/bzip2
    for i in /usr/bin/{bzcat,bunzip2}; do ln -sfv bzip2 ${i}; done
    rm -fv /usr/lib/libbz2.a
}
build "Bzip2" "$(ls ${SRC}/bzip2-*.tar.* 2>/dev/null | head -1)" do_bzip2

# ── Xz ──────────────────────────────────────────────────────
do_xz() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/xz-5.6
    make && make install
}
build "Xz" "$(ls ${SRC}/xz-*.tar.* 2>/dev/null | head -1)" do_xz

# ── Lz4 ─────────────────────────────────────────────────────
do_lz4() { make BUILD_STATIC=no PREFIX=/usr && make BUILD_STATIC=no PREFIX=/usr install; }
build "Lz4" "$(ls ${SRC}/lz4-*.tar.* 2>/dev/null | head -1)" do_lz4

# ── Zstd ────────────────────────────────────────────────────
do_zstd() {
    make prefix=/usr && make prefix=/usr install
    rm -v /usr/lib/libzstd.a
}
build "Zstd" "$(ls ${SRC}/zstd-*.tar.* 2>/dev/null | head -1)" do_zstd

# ── File ────────────────────────────────────────────────────
do_file() { ./configure --prefix=/usr && make && make install; }
build "File" "$(ls ${SRC}/file-*.tar.* 2>/dev/null | head -1)" do_file

# ── M4 / Bc / Flex ──────────────────────────────────────────
for pkg in m4 bc flex; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1 || true)
    [[ -f "$f" ]] || { echo "[SKIP] ${pkg}: tarball なし"; continue; }
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 開始"
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && rm -rf "$dir" && tar -xf "$f" && cd "$dir"
    if [[ "$pkg" == "bc" ]]; then
        CC=gcc ./configure --prefix=/usr -G -O3 -r
    elif [[ "$pkg" == "flex" ]]; then
        ./configure --prefix=/usr --disable-static
    else
        ./configure --prefix=/usr
    fi
    make && make install
    [[ "$pkg" == "flex" ]] && { ln -sfv flex /usr/bin/lex; ln -sfv flex.1 /usr/share/man/man1/lex.1; } || true
    cd ${SRC} && rm -rf "$dir"
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 完了"
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
build "Tcl" "$(ls ${SRC}/tcl*-src.tar.* 2>/dev/null | head -1)" do_tcl

do_expect() {
    # ── GCC 14 対応パッチ ────────────────────────────────────────────────────
    # expect-5.45.4-gcc14-1.patch が無いと GCC14 の C89 デフォルト変更により
    # configure 内のコンパイルテストが全て失敗し、struct termios が検出されず
    # pty_.c (空ファイル) が選ばれてエラー終了する。
    local patch_file
    patch_file=$(ls ../expect*gcc14*.patch 2>/dev/null | head -1)
    if [[ -n "${patch_file}" ]]; then
        patch -Np1 -i "${patch_file}"
    else
        echo "[WARN] expect gcc14 パッチが見つかりません。CFLAGS で C99 を強制します。"
        # パッチなしの場合は CFLAGS に -std=gnu99 を追加して GCC14 互換を確保
        export CFLAGS="${CFLAGS} -std=gnu99"
    fi

    # ── configure キャッシュを事前注入 ──────────────────────────────────────
    # chroot 環境では /dev/pts が制限される場合があり、termios 系の
    # autoconf テストが誤検出されることがある。
    # ac_cv_* 変数は「引数」ではなく「--cache-file」で注入するのが正しい方法。
    cat > config.cache << 'CACHE'
ac_cv_struct_termios=yes
ac_cv_struct_termio=no
ac_cv_have_decl_TIOCGWINSZ=yes
CACHE

    ./configure --prefix=/usr --with-tcl=/usr/lib \
        --enable-shared --disable-rpath \
        --mandir=/usr/share/man --with-tclinclude=/usr/include \
        --cache-file=config.cache
    make && make install
}
build "Expect" "$(ls ${SRC}/expect*.tar.* 2>/dev/null | head -1)" do_expect

do_dejagnu() {
    mkdir -p build && cd build
    ../configure --prefix=/usr
    make install
}
build "DejaGNU" "$(ls ${SRC}/dejagnu-*.tar.* 2>/dev/null | head -1)" do_dejagnu

do_pkgconf() {
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/pkgconf-2.3.0
    make && make install
    ln -sfv pkgconf /usr/bin/pkg-config
}
build "Pkgconf" "$(ls ${SRC}/pkgconf-*.tar.* 2>/dev/null | head -1)" do_pkgconf

# ── Binutils (final) ────────────────────────────────────────
do_binutils_final() {
    mkdir -p build && cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
        --enable-gold --enable-ld=default --enable-plugins \
        --enable-shared --disable-werror --enable-64-bit-bfd \
        --enable-new-dtags --enable-default-hash-style=gnu \
        --with-system-zlib --enable-install-libiberty
    make tooldir=/usr && make tooldir=/usr install
    rm -fv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a
}
build "Binutils-final" "$(ls ${SRC}/binutils-*.tar.* 2>/dev/null | head -1)" do_binutils_final

# ── GMP / MPFR / MPC ────────────────────────────────────────
do_gmp() {
    ./configure --prefix=/usr --enable-cxx --disable-static \
        --docdir=/usr/share/doc/gmp-6.3.0
    make && make install
}
build "GMP" "$(ls ${SRC}/gmp-*.tar.* 2>/dev/null | head -1)" do_gmp

do_mpfr() {
    ./configure --prefix=/usr --disable-static \
        --enable-thread-safe --docdir=/usr/share/doc/mpfr-4.2.1
    make && make install
}
build "MPFR" "$(ls ${SRC}/mpfr-*.tar.* 2>/dev/null | head -1)" do_mpfr

do_mpc() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/mpc-1.3.1
    make && make install
}
build "MPC" "$(ls ${SRC}/mpc-*.tar.* 2>/dev/null | head -1)" do_mpc

# ── Attr / Acl / Libcap / Libxcrypt ────────────────────────
do_attr() {
    ./configure --prefix=/usr --disable-static --sysconfdir=/etc \
        --docdir=/usr/share/doc/attr-2.5.2
    make && make install
}
build "Attr" "$(ls ${SRC}/attr-*.tar.* 2>/dev/null | head -1)" do_attr

do_acl() {
    ./configure --prefix=/usr --disable-static \
        --docdir=/usr/share/doc/acl-2.3.2
    make && make install
}
build "Acl" "$(ls ${SRC}/acl-*.tar.* 2>/dev/null | head -1)" do_acl

do_libcap() {
    sed -i '/install -m.*STA/d' libcap/Makefile
    make prefix=/usr lib=lib && make prefix=/usr lib=lib install
}
build "Libcap" "$(ls ${SRC}/libcap-*.tar.* 2>/dev/null | head -1)" do_libcap

# ── Perl (Libxcrypt の configure が perl を必須とするため先にビルド) ──────
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
build "Perl" "$(ls ${SRC}/perl-*.tar.* 2>/dev/null | head -1)" do_perl

do_libxcrypt() {
    ./configure --prefix=/usr --enable-hashes=strong,glibc \
        --enable-obsolete-api=no --disable-static \
        --disable-failure-tokens
    make && make install
}
build "Libxcrypt" "$(ls ${SRC}/libxcrypt-*.tar.* 2>/dev/null | head -1)" do_libxcrypt

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
build "Shadow" "$(ls ${SRC}/shadow-*.tar.* 2>/dev/null | head -1)" do_shadow

# ── GCC (final) ─────────────────────────────────────────────
do_gcc_final() {
    case $(uname -m) in x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;; esac
    mkdir -p build && cd build
    ../configure --prefix=/usr --enable-languages=c,c++ \
        --enable-default-pie --enable-default-ssp \
        --enable-host-pie --disable-multilib \
        --disable-bootstrap --disable-fixincludes \
        --with-system-zlib
    make && make install
    chown -v -R root:root /usr/lib/gcc/$(gcc -dumpmachine)/*/include{,-fixed}
    ln -sfvr /usr/bin/cpp /usr/lib
    ln -sfv gcc.1 /usr/share/man/man1/cc.1
    ln -sfv ../../libexec/gcc/$(gcc -dumpmachine)/*/liblto_plugin.so \
        /usr/lib/bfd-plugins/
    mkdir -pv /usr/share/gdb/auto-load/usr/lib
    mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib 2>/dev/null || true
}
build "GCC-final" "$(ls ${SRC}/gcc-*.tar.* 2>/dev/null | head -1)" do_gcc_final

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
build "Ncurses" "$(ls ${SRC}/ncurses-*.tar.* 2>/dev/null | head -1)" do_ncurses

# ── Readline (Ncurses-final の後にビルド: libncursesw.so が必須) ─────────
do_readline() {
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install
    ./configure --prefix=/usr --disable-static \
        --with-curses --docdir=/usr/share/doc/readline-8.2
    make SHLIB_LIBS="-lncursesw"
    make SHLIB_LIBS="-lncursesw" install
}
build "Readline" "$(ls ${SRC}/readline-*.tar.* 2>/dev/null | head -1)" do_readline

# ── Sed / Psmisc / Gettext / Grep ──────────────────────────
# ※ bison は Glibc-final の前に Bison-early としてビルド済みのため除外
for pkg in sed psmisc gettext grep; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1 || true)
    [[ -f "$f" ]] || { echo "[SKIP] ${pkg}: tarball なし"; continue; }
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 開始"
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && rm -rf "$dir" && tar -xf "$f" && cd "$dir"
    ./configure --prefix=/usr 2>/dev/null || \
        { echo "[WARN] ${pkg} configure 失敗、スキップします"; cd ${SRC} && rm -rf "$dir"; continue; }
    make && make install
    cd ${SRC} && rm -rf "$dir"
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 完了"
done

# ── Bash ────────────────────────────────────────────────────
do_bash() {
    ./configure --prefix=/usr --without-bash-malloc \
        --with-installed-readline \
        --docdir=/usr/share/doc/bash-5.2.37
    make && make install
    ln -sfv bash /usr/bin/sh
}
build "Bash" "$(ls ${SRC}/bash-*.tar.* 2>/dev/null | head -1)" do_bash

# ── Libtool / GDBM / Gperf / Expat / Inetutils / Less ──────
for pkg in libtool gdbm gperf expat inetutils less; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1 || true)
    [[ -f "$f" ]] || { echo "[SKIP] ${pkg}: tarball なし"; continue; }
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 開始"
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && rm -rf "$dir" && tar -xf "$f" && cd "$dir"
    case "$pkg" in
        gdbm)      ./configure --prefix=/usr --disable-static --enable-libgdbm-compat ;;
        inetutils) ./configure --prefix=/usr --bindir=/usr/bin --localstatedir=/var \
                       --disable-logger --disable-whois --disable-rcp \
                       --disable-rexec --disable-rlogin --disable-rsh --disable-servers \
                       --enable-ping --enable-ping6 ;;

        *)         ./configure --prefix=/usr ;;
    esac
    make && make install
    # ping は setuid root が必要（SOCK_RAW 権限）
    if [[ "$pkg" == "inetutils" ]]; then
        chmod -v 4755 /usr/bin/ping  2>/dev/null || true
        chmod -v 4755 /usr/bin/ping6 2>/dev/null || true
        echo "[BASE] ping setuid 設定完了"
    fi
    cd ${SRC} && rm -rf "$dir"
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 完了"
done

# ── XML::Parser / Intltool / Autoconf / Automake ─────────────
# ※ Perl は Libxcrypt より前に移動済み
do_xmlparser() { perl Makefile.PL && make && make install; }
build "XML::Parser" "$(ls ${SRC}/XML-Parser-*.tar.* 2>/dev/null | head -1)" do_xmlparser

do_intltool() {
    sed -i 's:\\\${:\\\$\\{:' intltool-update.in
    ./configure --prefix=/usr && make && make install
}
build "Intltool" "$(ls ${SRC}/intltool-*.tar.* 2>/dev/null | head -1)" do_intltool

for pkg in autoconf automake; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1 || true)
    [[ -f "$f" ]] || { echo "[SKIP] ${pkg}: tarball なし"; continue; }
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 開始"
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && rm -rf "$dir" && tar -xf "$f" && cd "$dir"
    ./configure --prefix=/usr && make && make install
    cd ${SRC} && rm -rf "$dir"
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 完了"
done

# ── OpenSSL ─────────────────────────────────────────────────
do_openssl() {
    ./config --prefix=/usr --openssldir=/etc/ssl \
        --libdir=lib shared zlib-dynamic
    make && sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile
    make MANSUFFIX=ssl install
}
build "OpenSSL" "$(ls ${SRC}/openssl-*.tar.* 2>/dev/null | head -1)" do_openssl

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
build "Kmod" "$(ls ${SRC}/kmod-*.tar.* 2>/dev/null | head -1)" do_kmod

do_libelf() {
    ./configure --prefix=/usr --disable-debuginfod --enable-libdebuginfod=dummy
    make && make -C libelf install
    install -vm644 config/libelf.pc /usr/lib/pkgconfig
    rm /usr/lib/libelf.a
}
build "Libelf" "$(ls ${SRC}/elfutils-*.tar.* 2>/dev/null | head -1)" do_libelf

do_libffi() {
    ./configure --prefix=/usr --disable-static --with-gcc-arch=native
    make && make install
}
build "Libffi" "$(ls ${SRC}/libffi-*.tar.* 2>/dev/null | head -1)" do_libffi

do_python() {
    ./configure --prefix=/usr --enable-shared \
        --with-system-expat --enable-optimizations \
        --with-ensurepip=install
    make && make install
    ln -sfv python3 /usr/bin/python
    # pip を最新化して setuptools を確実に導入
    pip3 install --upgrade pip setuptools 2>/dev/null || true
}
build "Python" "$(ls ${SRC}/Python-*.tar.* 2>/dev/null | head -1)" do_python

# ── Ninja / Meson ────────────────────────────────────────────
do_ninja() {
    python3 configure.py --bootstrap
    install -vm755 ninja /usr/bin/
}
build "Ninja" "$(ls ${SRC}/ninja-*.tar.* 2>/dev/null | head -1)" do_ninja

do_meson() {
    # meson 1.4+ は pyproject.toml ベース。setup.py のフォールバックは
    # Python 3.12+ で setuptools が標準外になったため使用不可。
    # pip3 (--with-ensurepip=install で導入済み) で直接インストールする。
    pip3 install --no-build-isolation --no-index .
}
build "Meson" "$(ls ${SRC}/meson-*.tar.* 2>/dev/null | head -1)" do_meson

# ── Coreutils ───────────────────────────────────────────────
do_coreutils() {
    patch -Np1 -i ../coreutils-*.patch 2>/dev/null || true
    autoreconf -fiv 2>/dev/null || true
    FORCE_UNSAFE_CONFIGURE=1 ./configure \
        --prefix=/usr --enable-no-install-program=kill,uptime
    make && make install
    mv -v /usr/bin/chroot /usr/sbin
}
build "Coreutils" "$(ls ${SRC}/coreutils-*.tar.* 2>/dev/null | head -1)" do_coreutils

# ── Diffutils / Findutils / Gawk / Tar / Grep / Gzip / Patch / Make / Texinfo
for pkg in diffutils findutils gawk tar grep gzip patch make texinfo; do
    f=$(ls ${SRC}/${pkg}-*.tar.* 2>/dev/null | head -1 || true)
    [[ -f "$f" ]] || { echo "[SKIP] ${pkg}: tarball なし"; continue; }
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 開始"
    dir=$(tar -tf "$f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    # 前回の失敗で残ったディレクトリを削除してからクリーンに展開する
    cd ${SRC} && rm -rf "$dir" && tar -xf "$f" && cd "$dir"
    # tar は root チェックを持つため FORCE_UNSAFE_CONFIGURE=1 が必要
    if [[ "$pkg" == "tar" ]]; then
        # timeout の後に環境変数を直接書くとコマンド名として解釈されるため
        # env コマンド経由で渡す
        timeout 120 env FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr || {
            echo "[WARN] ${pkg} configure 失敗、スキップします"
            cd ${SRC} && rm -rf "$dir"
            continue
        }
    else
        timeout 120 ./configure --prefix=/usr || {
            echo "[WARN] ${pkg} configure 失敗、スキップします"
            cd ${SRC} && rm -rf "$dir"
            continue
        }
    fi
    make && make install
    cd ${SRC} && rm -rf "$dir"
    echo "[BASE] $(date '+%H:%M:%S') ${pkg} 完了"
done

# ── Which (個別) ────────────────────────────────────────────
_f=$(ls ${SRC}/which-*.tar.* 2>/dev/null | head -1 || true)
if [[ -f "$_f" ]]; then
    echo "[BASE] $(date '+%H:%M:%S') which 開始"
    _dir=$(tar -tf "$_f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && rm -rf "$_dir" && tar -xf "$_f" && cd "$_dir"
    ./configure --prefix=/usr && make && make install
    cd ${SRC} && rm -rf "$_dir"
    echo "[BASE] $(date '+%H:%M:%S') which 完了"
else
    echo "[SKIP] which: tarball なし"
fi

# ── Vim (個別) ──────────────────────────────────────────────
# --disable-gui --without-x を明示して chroot 環境でのGUI検出を防ぐ
_f=$(ls ${SRC}/vim-*.tar.* 2>/dev/null | head -1 || true)
if [[ -f "$_f" ]]; then
    echo "[BASE] $(date '+%H:%M:%S') vim 開始"
    _dir=$(tar -tf "$_f" 2>/dev/null | head -1 | cut -d/ -f1 || true)
    cd ${SRC} && rm -rf "$_dir" && tar -xf "$_f" && cd "$_dir"
    echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
    _vim_ok=1
    ./configure --prefix=/usr --disable-gui --without-x || {
        echo "[WARN] vim configure 失敗、スキップします"
        cd ${SRC} && rm -rf "$_dir"
        _vim_ok=0
    }
    if [[ $_vim_ok -eq 1 ]]; then
        make && make install
        ln -sfv vim /usr/bin/vi 2>/dev/null || true
        cd ${SRC} && rm -rf "$_dir"
        echo "[BASE] $(date '+%H:%M:%S') vim 完了"
    fi
else
    echo "[SKIP] vim: tarball なし"
fi

# ── Util-linux (libmount を Udev より先にビルド) ─────────────
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
build "Util-linux" "$(ls ${SRC}/util-linux-*.tar.* 2>/dev/null | head -1)" do_utillinux

# ── Udev (systemd) ──────────────────────────────────────────
do_udev() {
    # systemd-256以降のビルドにはjinja2が必須
    # まずchroot内のpip3で試み、失敗してもDockerfileのpython3-jinja2で補完される
    pip3 install jinja2 --quiet --break-system-packages 2>/dev/null || \
    pip3 install jinja2 --quiet 2>/dev/null || true
    sed -i -e 's/GROUP="render"/GROUP="video"/' \
           -e 's/GROUP="sgx", //' rules.d/50-udev-default.rules.in
    sed -i -e '/systemd-sysctl/s/^/#/' rules.d/99-systemd.rules.in
    mkdir -p build && cd build
    meson setup .. --prefix=/usr --buildtype=release \
        -D mode=release -D dev-kvm-mode=0660 \
        -D link-udev-shared=false -D logind=false \
        -D vconsole=false -D firstboot=false \
        -D randomseed=false -D backlight=false \
        -D rfkill=false \
        -D tmpfiles=false -D sysusers=false \
        -D hibernate=false -D ldconfig=false \
        -D resolve=false -D coredump=false \
        -D install-tests=false
    ninja udevadm systemd-hwdb
    DESTDIR=/ ninja install
}
build "Udev(systemd)" "$(ls ${SRC}/systemd-*.tar.* 2>/dev/null | head -1)" do_udev

# ── Libpipeline (Man-DB の依存ライブラリ) ───────────────────
do_libpipeline() {
    ./configure --prefix=/usr
    make && make install
}
build "Libpipeline" "$(ls ${SRC}/libpipeline-*.tar.* 2>/dev/null | head -1)" do_libpipeline

# ── Groff（man-db の soelim / tbl 依存）─────────────────────────────────────
do_groff() {
    PAGE=A4 ./configure --prefix=/usr
    make && make install
}
build "Groff" "$(ls ${SRC}/groff-*.tar.* 2>/dev/null | head -1)" do_groff

# ── Man-DB / Procps-ng / E2fsprogs / SysVinit ─
do_mandb() {
    ./configure --prefix=/usr --sysconfdir=/etc \
        --disable-setuid --enable-cache-owner=bin \
        --with-systemdtmpfilesdir= --with-systemdsystemunitdir=
    make && make install
}
build "Man-DB" "$(ls ${SRC}/man-db-*.tar.* 2>/dev/null | head -1)" do_mandb

do_procps() {
    ./configure --prefix=/usr --disable-static --disable-kill
    make && make install
}
build "Procps-ng" "$(ls ${SRC}/procps-ng-*.tar.* 2>/dev/null | head -1)" do_procps

do_e2fsprogs() {
    mkdir -p build && cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
        --enable-elf-shlibs --disable-libblkid \
        --disable-libuuid --disable-uuidd --disable-fsck
    make && make install
    rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
}
build "E2fsprogs" "$(ls ${SRC}/e2fsprogs-*.tar.* 2>/dev/null | head -1)" do_e2fsprogs

do_sysvinit() {
    patch -Np1 -i ../sysvinit-*.patch 2>/dev/null || true
    make && make install
}
build "SysVinit" "$(ls ${SRC}/sysvinit-*.tar.* 2>/dev/null | head -1)" do_sysvinit

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

    # ── CLI パッケージURL定義（.env の CLI_URL_* で上書き可能）──────────────
    # 各変数はスペース区切りで複数URL指定可。左から順に試してフォールバックします。
    read -ra _URL_SUDO          <<< "${CLI_URL_SUDO:-https://www.sudo.ws/dist/sudo-1.9.15p5.tar.gz}"
    read -ra _URL_NANO          <<< "${CLI_URL_NANO:-https://www.nano-editor.org/dist/v8/nano-8.3.tar.xz}"
    read -ra _URL_CURL          <<< "${CLI_URL_CURL:-https://curl.se/download/curl-8.11.1.tar.xz https://github.com/curl/curl/releases/download/curl-8_11_1/curl-8.11.1.tar.xz}"
    read -ra _URL_PCRE2         <<< "${CLI_URL_PCRE2:-https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2 https://sourceforge.net/projects/pcre/files/pcre2/10.44/pcre2-10.44.tar.bz2}"
    read -ra _URL_GIT           <<< "${CLI_URL_GIT:-https://www.kernel.org/pub/software/scm/git/git-2.47.2.tar.xz https://mirrors.edge.kernel.org/pub/software/scm/git/git-2.47.2.tar.xz}"
    read -ra _URL_HTOP          <<< "${CLI_URL_HTOP:-https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz}"
    read -ra _URL_LIBEVENT      <<< "${CLI_URL_LIBEVENT:-https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz}"
    read -ra _URL_TMUX          <<< "${CLI_URL_TMUX:-https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz}"
    read -ra _URL_TREE          <<< "${CLI_URL_TREE:-https://mama.indstate.edu/users/ice/tree/src/tree-2.1.3.tgz https://gitlab.com/OldManProgrammer/unix-tree/-/archive/2.1.3/unix-tree-2.1.3.tar.gz}"
    read -ra _URL_BASH_COMPLETION <<< "${CLI_URL_BASH_COMPLETION:-https://github.com/scop/bash-completion/releases/download/2.14.0/bash-completion-2.14.0.tar.xz}"
    read -ra _URL_DBUS          <<< "${CLI_URL_DBUS:-https://dbus.freedesktop.org/releases/dbus/dbus-1.15.8.tar.xz}"
    read -ra _URL_IPROUTE2      <<< "${CLI_URL_IPROUTE2:-https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.12.0.tar.xz}"
    read -ra _URL_DHCPCD        <<< "${CLI_URL_DHCPCD:-https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.0.10/dhcpcd-10.0.10.tar.xz}"
    read -ra _URL_OPENSSH       <<< "${CLI_URL_OPENSSH:-https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p1.tar.gz https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p1.tar.gz}"
    read -ra _URL_LIBGPG_ERROR  <<< "${CLI_URL_LIBGPG_ERROR:-https://www.gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.50.tar.bz2 https://mirrors.dotsrc.org/gcrypt/libgpg-error/libgpg-error-1.50.tar.bz2}"
    read -ra _URL_LIBGCRYPT     <<< "${CLI_URL_LIBGCRYPT:-https://www.gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2 https://mirrors.dotsrc.org/gcrypt/libgcrypt/libgcrypt-1.11.0.tar.bz2}"
    read -ra _URL_GRUB          <<< "${CLI_URL_GRUB:-https://ftpmirror.gnu.org/grub/grub-2.12.tar.xz https://ftp.jaist.ac.jp/pub/GNU/grub/grub-2.12.tar.xz https://mirrors.kernel.org/gnu/grub/grub-2.12.tar.xz https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz}"
    read -ra _URL_LIBPNG        <<< "${CLI_URL_LIBPNG:-https://downloads.sourceforge.net/libpng/libpng-1.6.44.tar.xz https://github.com/pnggroup/libpng/releases/download/v1.6.44/libpng-1.6.44.tar.xz}"
    read -ra _URL_FREETYPE      <<< "${CLI_URL_FREETYPE:-https://downloads.sourceforge.net/freetype/freetype-2.13.3.tar.xz https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz}"
    # unifont_all-*.bdf.gz は unifoundry.com 専用ファイルで GNU ミラーには存在しない
    # GNU ミラーに確実にある unifont-15.1.04.bdf.gz (BMP のみ、約1.2MB) を使用する
    read -ra _URL_UNIFONT       <<< "${CLI_URL_UNIFONT:-https://ftpmirror.gnu.org/unifont/unifont-15.1.04/unifont-15.1.04.bdf.gz https://mirrors.kernel.org/gnu/unifont/unifont-15.1.04/unifont-15.1.04.bdf.gz https://ftp.jaist.ac.jp/pub/GNU/unifont/unifont-15.1.04/unifont-15.1.04.bdf.gz https://ftp.gnu.org/gnu/unifont/unifont-15.1.04/unifont-15.1.04.bdf.gz}"
    read -ra _URL_EXPAT         <<< "${CLI_URL_EXPAT:-https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz}"

    log_info "CLI パッケージのダウンロード中..."
    # 書式: "ファイル名 URL変数名のスペース区切りリスト"
    # smart_wget がフォールバック込みで処理するため URL を配列ごと渡す
    _cli_pkg() {
        local fname="$1"; shift
        local urls=("$@")
        if [[ -s "${fname}" ]]; then
            echo "  [CACHED] ${fname}"
        else
            smart_wget "${fname}" "${urls[@]}" \
                || echo "  [WARN] ダウンロード失敗: ${fname}"
        fi
    }

    _cli_pkg "sudo-1.9.15p5.tar.gz"                    "${_URL_SUDO[@]}"
    _cli_pkg "nano-8.3.tar.xz"                         "${_URL_NANO[@]}"
    _cli_pkg "curl-8.11.1.tar.xz"                      "${_URL_CURL[@]}"
    _cli_pkg "pcre2-10.44.tar.bz2"                     "${_URL_PCRE2[@]}"
    _cli_pkg "git-2.47.2.tar.xz"                       "${_URL_GIT[@]}"
    _cli_pkg "htop-3.3.0.tar.xz"                       "${_URL_HTOP[@]}"
    _cli_pkg "libevent-2.1.12-stable.tar.gz"            "${_URL_LIBEVENT[@]}"
    _cli_pkg "tmux-3.5a.tar.gz"                        "${_URL_TMUX[@]}"
    _cli_pkg "tree-2.1.3.tgz"                          "${_URL_TREE[@]}"
    _cli_pkg "bash-completion-2.14.0.tar.xz"           "${_URL_BASH_COMPLETION[@]}"
    _cli_pkg "dbus-1.15.8.tar.xz"                      "${_URL_DBUS[@]}"
    _cli_pkg "iproute2-6.12.0.tar.xz"                  "${_URL_IPROUTE2[@]}"
    _cli_pkg "dhcpcd-10.0.10.tar.xz"                   "${_URL_DHCPCD[@]}"
    _cli_pkg "openssh-9.9p1.tar.gz"                    "${_URL_OPENSSH[@]}"
    _cli_pkg "libgpg-error-1.50.tar.bz2"               "${_URL_LIBGPG_ERROR[@]}"
    _cli_pkg "libgcrypt-1.11.0.tar.bz2"                "${_URL_LIBGCRYPT[@]}"
    _cli_pkg "grub-2.12.tar.xz"                        "${_URL_GRUB[@]}"
    _cli_pkg "libpng-1.6.44.tar.xz"                    "${_URL_LIBPNG[@]}"
    _cli_pkg "freetype-2.13.3.tar.xz"                  "${_URL_FREETYPE[@]}"
    _cli_pkg "unifont-15.1.04.bdf.gz"                  "${_URL_UNIFONT[@]}"
    # kbd: 日本語キーボード配列（loadkeys jp106）に必要
    # ミラーは .env の CLI_URL_KBD で上書き可能（スペース区切りで複数指定）
    read -ra _URL_KBD <<< "${CLI_URL_KBD:-https://www.kernel.org/pub/linux/utils/kbd/kbd-2.6.4.tar.xz https://mirrors.edge.kernel.org/pub/linux/utils/kbd/kbd-2.6.4.tar.xz}"
    _cli_pkg "kbd-2.6.4.tar.xz" "${_URL_KBD[@]}"
    # which: Step4のwget-listに含まれない場合の補完
    # ミラーは .env の CLI_URL_WHICH で上書き可能（スペース区切りで複数指定）
    if [[ ! -s "which-2.21.tar.gz" ]]; then
        read -ra _URL_WHICH <<< "${CLI_URL_WHICH:-https://ftp.gnu.org/gnu/which/which-2.21.tar.gz https://ftpmirror.gnu.org/which/which-2.21.tar.gz}"
        _cli_pkg "which-2.21.tar.gz" "${_URL_WHICH[@]}"
    fi
    # expat: Step2 で取得済みのはずだがなければ補完
    if [[ ! -s "expat-2.6.2.tar.xz" ]]; then
        _cli_pkg "expat-2.6.2.tar.xz"                  "${_URL_EXPAT[@]}"
    fi
    # wget: README に記載されているが Step4 の wget-list 非収録のため明示取得
    read -ra _URL_WGET <<< "${CLI_URL_WGET:-https://ftpmirror.gnu.org/wget/wget-1.25.0.tar.gz https://ftp.gnu.org/gnu/wget/wget-1.25.0.tar.gz}"
    _cli_pkg "wget-1.25.0.tar.gz" "${_URL_WGET[@]}"

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
    # LFS公式 (r13.0-systemd) の手順に準拠
    # --wrap-mode=nofallback: テスト用Glibの自動ダウンロードを防ぐ
    # runstatedir等の細かいオプションは不要（デフォルト値が正しい）
    mkdir -p build && cd build
    meson setup --prefix=/usr \
        --buildtype=release \
        --wrap-mode=nofallback \
        ..
    ninja && ninja install
    ln -sfv /etc/machine-id /var/lib/dbus
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
        --with-openssl \
        --with-ca-path=/etc/ssl/certs \
        --without-libpsl
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

    # ── dhcpcd.conf: 全NICを対象にする ──────────────────────
    # デフォルトでは特定インターフェース名にしか応答しないため
    # allowinterfaces で明示的にワイルドカード指定する
    cat > /etc/dhcpcd.conf << 'DHCPCFGEOF'
# /etc/dhcpcd.conf - generated by lfs.sh
# 全てのイーサネットNICを対象にする
allowinterfaces eth* enp* ens* eno* em* *
background
# タイムアウト設定（リンクが遅いNICへの対策）
timeout 30
# ホスト名を送信しない（プライバシー）
hostname
# 必要な場合はコメントアウトを外す
# static domain_name_servers=8.8.8.8 8.8.4.4
DHCPCFGEOF

    # ── 起動スクリプト（rc3.d に登録）──────────────────────
    mkdir -p /etc/rc.d/init.d /etc/rc.d/rc3.d
    cat > /etc/rc.d/init.d/dhcpcd << 'DHCPEOF'
#!/bin/bash
case $1 in
  start)
    echo "dhcpcd 開始中..."
    # 全NICをリンクアップしてから dhcpcd を起動
    for iface in /sys/class/net/*/; do
        name=$(basename "$iface")
        [ "$name" = "lo" ] && continue
        ip link set "$name" up 2>/dev/null && \
            echo "  リンクアップ: $name" || true
    done
    # dhcpcd をバックグラウンドで起動（全NICに対して）
    dhcpcd -q -b 2>/dev/null || dhcpcd -q -b --allowinterfaces '*'
    ;;
  stop)
    dhcpcd -x
    ;;
  status)
    pgrep dhcpcd > /dev/null && echo "running" || echo "stopped"
    ;;
esac
DHCPEOF
    chmod +x /etc/rc.d/init.d/dhcpcd

    # ── rc3.d へシンボリックリンク（これが無いとランレベル3で起動しない）──
    ln -sf ../init.d/dhcpcd /etc/rc.d/rc3.d/S30dhcpcd
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

# ── kbd（日本語キーボード配列・loadkeys に必要）─────────────
do_kbd() {
    ./configure --prefix=/usr --disable-vlock
    make && make install
}
build "kbd" "kbd-2.6.4.tar.xz" do_kbd

# ── which ────────────────────────────────────────────────────
do_which() {
    ./configure --prefix=/usr
    make && make install
}
build "which" "which-2.21.tar.gz" do_which

# ── wget ─────────────────────────────────────────────────────
do_wget() {
    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --with-ssl=openssl
    make && make install
}
build "wget" "wget-1.25.0.tar.gz" do_wget

# ── neofetch（ペンギンAA + システム情報表示）────────────────
# neofetch はシェルスクリプト単体。tarball不要でGitHubから直接取得。
# ミラーは .env の CLI_URL_NEOFETCH で上書き可能。
_NEOFETCH_URL="${CLI_URL_NEOFETCH:-https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch}"
if curl -fsSL --retry 3 --connect-timeout 30 \
        -o /usr/bin/neofetch "${_NEOFETCH_URL}" 2>/dev/null; then
    chmod +x /usr/bin/neofetch
    echo "[CLI] neofetch インストール完了"
else
    # フォールバック: 最小限のneofetch互換スクリプトを内蔵
    cat > /usr/bin/neofetch << 'NEOFETCH_FALLBACK'
#!/bin/bash
# Minimal neofetch fallback (penguin ASCII art)
if [ -f /etc/os-release ]; then
    _OS=$(grep ^PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
else
    _OS="Linux From Scratch"
fi

_KERNEL=$(uname -r)
_UPTIME=$(uptime -p 2>/dev/null || echo "unknown")
_SHELL=$(basename "$SHELL")
_CPU=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ *//' || echo "unknown")
_MEM_TOTAL=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)MiB
_MEM_FREE=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo)MiB

C_BODY='\033[1;30m'
C_EYE='\033[1;37m'
C_BEAK='\033[1;33m'
C_INFO='\033[1;37m'
R='\033[0m'

B=$C_BODY
W=$C_EYE
Y=$C_BEAK

# 見た目の幅でパディングする関数
# 使い方: pad "カラー付き文字列" 目標表示幅
pad() {
  local str="$1"
  local width="$2"
  # ANSIエスケープを除去して表示幅を測る
  local plain
  plain=$(printf '%b' "$str" | sed 's/\x1b\[[0-9;]*m//g')
  local pad_n=$(( width - ${#plain} ))
  printf '%b%*s' "$str" "$pad_n" ""
}

ART_W=50  # アスキーアート列の表示幅（実際の最長行に合わせて調整）

pad "${B}              .:@:.${R}"                                                       $ART_W; printf "                         \n"
pad "${B}            :@@@@@@@:${R}"                                                     $ART_W; printf "                       \n"
pad "${B}            @@@@@@@@@-${R}"                                                    $ART_W; printf "  ${C_INFO}OS:${R}     ${_OS}\n"
pad "${B}    .:%     @@@@@@@@@+.       @%${R}"                                          $ART_W; printf "  ${C_INFO}Kernel:${R} ${_KERNEL}\n"
pad "${B}   *@@@%+:  :@@@@@@@%=: .=%@@@@@@=${R}"                                       $ART_W; printf "  ${C_INFO}Uptime:${R} ${_UPTIME}\n"
pad "${B}  :@@@@@@##@@@@@@@@@%*+%@%+@@@@@@@+${R}"                                      $ART_W; printf "  ${C_INFO}Shell:${R}  ${_SHELL}\n"
pad "${B}  @@#${W}####${B}+@@@@@@@%:${W}######${B}=@@@@@@@@@-${R}"                     $ART_W; printf "  ${C_INFO}CPU:${R}    ${_CPU}\n"
pad "${B} *@%${W}######${B}.@@@@@#${W}#########${B}-@@@@@@@@#.${R}"                    $ART_W; printf "  ${C_INFO}Memory:${R} ${_MEM_FREE} / ${_MEM_TOTAL}\n"
pad "${B} %@-${W}#${B}.@${B}=${B}:${W}##${B}+@@@@-${W}###${B}%@${B}:${B}=${W}###${B}*@#*+=-+#:${R}" $ART_W; printf "     \n"
pad "${B} @@.${W}#${B}@@*${B}=${B}:${W}#${B}-%%%%**-${W}##${B}%@@%${B}*${B}*${W}###${B}#=-${R}"     $ART_W; printf "         \n"
pad "${B} @@-${W}#${B}@@@@+.-${Y}...${B}:=.${W}#${B}%@@@@%${W}###${B}#-${R}"          $ART_W; printf "            \n"
pad "${B} %@%${W}##${B}*#:${Y}.o.....o...${B}-%@+${W}###${B}#@+    -:${R}"            $ART_W; printf "     \n"
pad "${B} +@@*${W}#${Y}....................${B}+@@@@@@@@+${R}"                          $ART_W; printf "        \n"
pad "${B}  @%:${Y}....................._:${B}@@@@@@@=.${R}"                             $ART_W; printf "      \n"
pad "${B}  .=:${Y}...............__*-=\`\\.${B}=@@@@@@#=.${R}"                         $ART_W; printf "     \n"
pad "${B}   :+:${Y}....:==*__*-=\`\\:..==-:${B}#@@@@@%+:${R}"                          $ART_W; printf "     \n"
pad "${B}     .--=-:  ${Y}+..::.....-:    ${B}=%@*=:${R}"                              $ART_W; printf "        \n"
pad "${B}              :........-${R}"                                                  $ART_W; printf "                    \n"
pad "${B}                .:...--.${R}"                                                  $ART_W; printf "                    \n"
printf "\n"

NEOFETCH_FALLBACK
    chmod +x /usr/bin/neofetch
    echo "[CLI] neofetch フォールバック版をインストール"
fi

# ── libpng (freetype の推奨依存) ─────────────────────────────
do_libpng() {
    ./configure --prefix=/usr --disable-static
    make && make install
}
build "libpng" "libpng-1.6.44.tar.xz" do_libpng

# ── FreeType (grub-mkfont の必須依存) ────────────────────────
do_freetype() {
    sed -ri "s:.*(AUX_MODULES.*valid):\1:" modules.cfg
    sed -r "s:.*(#.*SUBPIXEL_RENDERING) .*:\1:" \
        -i include/freetype/config/ftoption.h
    ./configure --prefix=/usr --enable-freetype-config --disable-static
    make && make install
}
build "freetype" "freetype-2.13.3.tar.xz" do_freetype

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

# ── GRUB が必要とするディレクトリを事前作成 ──────────────────
# morning.sh の grub-install / grub-mkconfig がこれらを必要とする
mkdir -p /boot/efi /boot/grub/fonts

# ── udev rules: NIC が追加されたら自動リンクアップ（課題3）───
# udev が NET_ID サブシステムのイベントを拾い ip link set up する
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/10-network-link-up.rules << 'UDEVEOF'
# 全てのイーサネットインターフェースをリンクアップする
# SUBSYSTEM=="net": NIC イベント
# ACTION=="add":   NIC が追加（起動時 or ホットプラグ）
# KERNEL!="lo":    ループバックは除外
SUBSYSTEM=="net", ACTION=="add", KERNEL!="lo", RUN+="/sbin/ip link set %k up"
UDEVEOF

# ── /etc/sysctl.conf: ping の権限設定（課題1）──────────────
# net.ipv4.ping_group_range でルート以外のユーザーも ping を使えるようにする
# 値: "0 2147483647" = 全グループを許可
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/10-network.conf << 'SYSCTLEOF'
# ping を全ユーザーに許可（ICMP ソケット）
net.ipv4.ping_group_range = 0 2147483647
# IPv4 フォワーディング（不要なら 0 のまま）
net.ipv4.ip_forward = 0
# TCP/IP チューニング
net.core.rmem_default = 262144
net.core.wmem_default = 262144
SYSCTLEOF

# rcS から sysctl を適用するよう後で追記（rcS は後のブロックで生成）

# ── unicode.pf2 生成はスキップ ───────────────────────────────
# gfxterm/unifont は文字化けの原因となるため使用しない。
# GRUBメニューは ASCII コンソールモード (terminal_output console) で表示する。
echo "[CLI] GRUBフォント生成をスキップ（コンソールモードを使用）"

# ── Linux カーネル ────────────────────────────────────────────
do_kernel() {
    make mrproper
    make defconfig

    # ── EFI ブート ──────────────────────────────────
    scripts/config --enable CONFIG_EFI
    scripts/config --enable CONFIG_EFI_STUB
    scripts/config --enable CONFIG_EFI_PARTITION

    # ── /dev 自動生成（必須）──────────────────────
    scripts/config --enable CONFIG_DEVTMPFS
    scripts/config --enable CONFIG_DEVTMPFS_MOUNT

    # ── コンソール / フレームバッファ ─────────────
    scripts/config --enable CONFIG_VT
    scripts/config --enable CONFIG_VT_CONSOLE
    scripts/config --enable CONFIG_DUMMY_CONSOLE
    scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
    scripts/config --enable CONFIG_FB
    scripts/config --enable CONFIG_FB_EFI
    scripts/config --enable CONFIG_FB_VESA
    scripts/config --enable CONFIG_DRM
    scripts/config --enable CONFIG_DRM_SIMPLEDRM
    scripts/config --enable CONFIG_FONT_8x16

    # ── SCSI サブシステム（USB Storage の依存元）─
    # USB Storage → SCSI → BLK_DEV_SD の順で依存しているため
    # 全て =y（組み込み）にしないとinitramfsなしでは起動できない
    scripts/config --enable CONFIG_SCSI
    scripts/config --enable CONFIG_SCSI_MOD
    scripts/config --enable CONFIG_BLK_DEV_SD

    # ── USB コントローラ（全世代カバー）────────────
    scripts/config --enable CONFIG_USB_SUPPORT
    scripts/config --enable CONFIG_USB_XHCI_HCD   # USB 3.x
    scripts/config --enable CONFIG_USB_EHCI_HCD   # USB 2.0
    scripts/config --enable CONFIG_USB_OHCI_HCD   # USB 1.1（古いPC・一部UEFI）

    # ── USB Mass Storage ────────────────────────────
    scripts/config --enable CONFIG_USB_STORAGE

    # ── SATA ────────────────────────────────────────
    scripts/config --enable CONFIG_ATA
    scripts/config --enable CONFIG_ATA_VERBOSE_ERROR
    scripts/config --enable CONFIG_AHCI

    # ── パーティション ──────────────────────────────
    scripts/config --enable CONFIG_PARTITION_ADVANCED
    scripts/config --enable CONFIG_MSDOS_PARTITION
    scripts/config --enable CONFIG_EFI_PARTITION

    # ── ファイルシステム ────────────────────────────
    scripts/config --enable CONFIG_EXT4_FS
    scripts/config --enable CONFIG_VFAT_FS
    scripts/config --enable CONFIG_FAT_FS
    scripts/config --enable CONFIG_MSDOS_FS
    scripts/config --enable CONFIG_NLS_CODEPAGE_437
    scripts/config --enable CONFIG_NLS_ISO8859_1
    scripts/config --enable CONFIG_NLS_UTF8

    # ── ネットワーク基盤（ping・ICMP・TCP/IP スタック）──────
    # CONFIG_INET が無いと ping が "Network unreachable" / "Operation not permitted"
    scripts/config --enable CONFIG_NET
    scripts/config --enable CONFIG_INET            # IPv4 + ICMP スタック（ping に必須）
    scripts/config --enable CONFIG_IP_MULTICAST
    scripts/config --enable CONFIG_IPV6            # IPv6（任意だが一般的）
    scripts/config --enable CONFIG_UNIX            # UNIXドメインソケット（dhcpcd等が使用）
    scripts/config --enable CONFIG_PACKET          # raw socket（ping の SOCK_RAW に必要）
    scripts/config --enable CONFIG_NET_CORE

    # ── イーサネットドライバ ────────────────────────
    # 必要なドライバをコメントアウトで用意。使用するNICに合わせて
    # 該当行のコメントを外して有効化してください。
    # （有効化後は make olddefconfig → make -j... を再実行すること）
    #
    # 汎用・準仮想化
    #scripts/config --enable CONFIG_VIRTIO_NET          # QEMU/KVM virtio-net
    #scripts/config --enable CONFIG_VMXNET3             # VMware VMXNET3
    #
    # Intel 系
    #scripts/config --enable CONFIG_E1000               # Intel PRO/1000 (82540/82545 等)
    #scripts/config --enable CONFIG_E1000E              # Intel PRO/1000 PCIe (82566/82574 等)
    #scripts/config --enable CONFIG_IGB                 # Intel I210/I350/I354 GbE
    #scripts/config --enable CONFIG_IXGBE               # Intel 82598/82599 10GbE
    #scripts/config --enable CONFIG_I40E                # Intel XL710/X710 40GbE
    #
    # Realtek 系
    #scripts/config --enable CONFIG_8139CP              # Realtek RTL-8139C+
    #scripts/config --enable CONFIG_8139TOO             # Realtek RTL-8139 (古い型番)
    scripts/config --enable CONFIG_R8169               # Realtek RTL8111/8168/8411 GbE (最多)
    #
    # Broadcom 系
    #scripts/config --enable CONFIG_BNX2                # Broadcom NetXtreme II GbE
    #scripts/config --enable CONFIG_TIGON3              # Broadcom NetXtreme BCM570x GbE
    #scripts/config --enable CONFIG_BNX2X               # Broadcom NetXtreme II 10GbE
    #
    # その他
    #scripts/config --enable CONFIG_ATL1                # Attansic/Qualcomm Atheros L1
    #scripts/config --enable CONFIG_ATL2                # Attansic/Qualcomm Atheros L2
    #scripts/config --enable CONFIG_ATSE1G              # Qualcomm Atheros AR8131/AR8151 GbE

    # ★ 依存関係を自動解決（これがないと上記の --enable が
    #    依存先未解決のまま無効化される。scripts/config の後は必須）
    make olddefconfig

    # ビルド後に重要ドライバが本当に =y になっているか検証
    echo "[KERNEL] 組み込みドライバ確認:"
    for cfg in CONFIG_SCSI CONFIG_BLK_DEV_SD CONFIG_USB_SUPPORT \
               CONFIG_USB_XHCI_HCD CONFIG_USB_STORAGE \
               CONFIG_EXT4_FS CONFIG_DEVTMPFS \
               CONFIG_NET CONFIG_INET CONFIG_PACKET; do
        val=$(grep "^${cfg}=" .config || echo "${cfg}=MISSING")
        echo "  ${val}"
        # =m（モジュール）のままだとinitramfsなしでは起動不可なので警告
        if [[ "${val}" == *"=m" ]]; then
            echo "  [WARN] ${cfg} がモジュールのままです。依存関係を確認してください。"
        fi
    done

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

PS1='\[\e[01;32m\]\u@\h\[\e[0m\]:\[\e[01;34m\]\w\[\e[0m\]\$ '

alias la='ls -lhA --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias addcmd='nano /root/.bashrc'

# ── パッケージビルド関数 ──────────────────────────────────────
# 使い方:
#   build <パッケージ名> [./configure のフラグ...] [ミラーURL]
#
# 例:
#   build nano
#   build nano --enable-utf8 --disable-nls
#   build nano --enable-utf8 https://example.com/nano-8.3.tar.xz
#
# 動作:
#   1. /sources/<pkg>*.tar.* を探してそのまま展開（既存）
#   2. 見つからない場合、ミラーURL 引数があればそこから wget で取得
#   3. configure フラグを付けて ./configure → make → make install
build() {
    local pkg="$1"; shift
    if [[ -z "$pkg" ]]; then
        echo "使い方: build <パッケージ名> [configureフラグ...] [ミラーURL]" >&2
        return 1
    fi

    local SRC=/sources
    local configure_flags=()
    local mirror_url=""

    # 引数を解析: URL（http/https）はミラー、それ以外は configure フラグ
    for arg in "$@"; do
        if [[ "$arg" == http://* || "$arg" == https://* || "$arg" == ftp://* ]]; then
            mirror_url="$arg"
        else
            configure_flags+=("$arg")
        fi
    done

    # tarball を探す
    local tarball
    tarball=$(ls "${SRC}/${pkg}"*.tar.* 2>/dev/null | head -1)

    if [[ -z "$tarball" ]]; then
        if [[ -n "$mirror_url" ]]; then
            echo "[BUILD] ${pkg}: ソース未発見。ミラーから取得します: ${mirror_url}"
            wget -q --show-progress -P "${SRC}" "${mirror_url}" || {
                echo "[ERROR] ダウンロード失敗: ${mirror_url}" >&2; return 1
            }
            tarball=$(ls "${SRC}/${pkg}"*.tar.* 2>/dev/null | head -1)
        fi
        if [[ -z "$tarball" ]]; then
            echo "[ERROR] /sources に ${pkg}*.tar.* が見つかりません。" >&2
            echo "        tarball を /sources に置くか、ミラーURLを第2引数以降に指定してください。" >&2
            return 1
        fi
    fi

    echo "[BUILD] $(date '+%H:%M:%S') ${pkg} (${tarball##*/})"
    [[ ${#configure_flags[@]} -gt 0 ]] && echo "[BUILD] configureフラグ: ${configure_flags[*]}"

    local tmpdir; tmpdir=$(mktemp -d /tmp/build-XXXXXX)
    trap "rm -rf '${tmpdir}'" RETURN

    tar -xf "${tarball}" -C "${tmpdir}"
    local srcdir; srcdir=$(ls -d "${tmpdir}"/*/  2>/dev/null | head -1)
    if [[ -z "$srcdir" ]]; then
        echo "[ERROR] tarball 展開後にディレクトリが見つかりません" >&2; return 1
    fi
    cd "${srcdir}"

    if [[ -f configure ]]; then
        ./configure --prefix=/usr "${configure_flags[@]}" || {
            echo "[ERROR] configure 失敗" >&2; return 1
        }
    elif [[ -f CMakeLists.txt ]]; then
        echo "[BUILD] CMake を使用します"
        mkdir -p build && cd build
        cmake -DCMAKE_INSTALL_PREFIX=/usr "${configure_flags[@]}" .. || {
            echo "[ERROR] cmake 失敗" >&2; return 1
        }
    elif [[ -f meson.build ]]; then
        echo "[BUILD] Meson を使用します"
        mkdir -p build
        meson setup --prefix=/usr "${configure_flags[@]}" build || {
            echo "[ERROR] meson setup 失敗" >&2; return 1
        }
        cd build
        ninja && ninja install
        echo "[BUILD] ${pkg} インストール完了"
        return 0
    else
        echo "[WARN] configure / CMakeLists.txt / meson.build が見つかりません。make のみ試みます"
    fi

    make -j"$(nproc)" && make install || {
        echo "[ERROR] make / make install 失敗" >&2; return 1
    }
    echo "[BUILD] ${pkg} インストール完了"
}

# ── パッケージアップデート関数 ────────────────────────────────
# 使い方:
#   update <パッケージ名> [ミラーURL]
#
# 例:
#   update nano
#   update nano https://example.com/nano-8.4.tar.xz
#
# 動作:
#   1. ミラーURLがあれば新 tarball を /sources に wget
#   2. 古い tarball（同名パッケージの旧バージョン）を削除
#   3. build 関数で再ビルド・再インストール
update() {
    local pkg="$1"; shift
    if [[ -z "$pkg" ]]; then
        echo "使い方: update <パッケージ名> [ミラーURL]" >&2
        return 1
    fi

    local SRC=/sources
    local mirror_url="${1:-}"

    if [[ -n "$mirror_url" ]]; then
        echo "[UPDATE] ${pkg}: ミラーから新バージョンを取得: ${mirror_url}"
        # 旧 tarball を削除してから新バージョンを取得
        local old_tarballs
        old_tarballs=$(ls "${SRC}/${pkg}"*.tar.* 2>/dev/null)
        wget -q --show-progress -P "${SRC}" "${mirror_url}" || {
            echo "[ERROR] ダウンロード失敗: ${mirror_url}" >&2; return 1
        }
        # 旧 tarball が新取得 tarball と異なる場合のみ削除
        local new_tarball; new_tarball=$(ls -t "${SRC}/${pkg}"*.tar.* 2>/dev/null | head -1)
        for old in ${old_tarballs}; do
            [[ "$old" != "$new_tarball" ]] && rm -f "$old" && echo "[UPDATE] 旧 tarball 削除: ${old##*/}"
        done
    fi

    echo "[UPDATE] ${pkg}: 再ビルド・再インストールします"
    build "$pkg"
}

# ログイン時にneofetchでシステム情報・ペンギンを表示
command -v neofetch &>/dev/null && neofetch
RCEOF

# ── /root/.bash_profile ─────────────────────────────────────────────
cat > /root/.bash_profile << 'PROFILEEOF'
if [ -f /root/.bashrc ]; then
    source /root/.bashrc
fi
PROFILEEOF

# ── ロケール / タイムゾーン / ホスト名 ───────────────────────
localedef -i ja_JP -f UTF-8 ja_JP.UTF-8 2>/dev/null || true
localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true

cat > /etc/locale.conf << LOCEOF
LANG=__LOCALE_NAME__
LC_ALL=__LOCALE_NAME__
LOCEOF

# ── コンソールフォント / キーマップ設定（文字化け対策）────────
# Linuxコンソールは標準でLatin系フォントのため日本語が文字化けする。
# kbd の ter-v4b（Terminus 16px）は ASCII + 拡張Latin に対応し安定。
# 日本語表示はコンソールの限界のため、LANGはUTF-8を維持しつつ
# フォントを正しく設定することで記号・ASCII部分の化けを防ぐ。
cat > /etc/vconsole.conf << 'VCEOF'
KEYMAP=jp106
FONT=ter-v16b
VCEOF

echo "lfs" > /etc/hostname

# ── root パスワード ───────────────────────────────────────────
echo "root:__ROOT_PASSWORD__" | chpasswd

# ── /etc/fstab (UUID は morning.sh が設定) ───────────────────
cat > /etc/fstab << 'FSTABEOF'
# UUID をデプロイ時に morning.sh が自動設定します
# UUID=XXXX  /         ext4   defaults,noatime 0 1
# UUID=XXXX  /boot/efi vfat   defaults         0 2
FSTABEOF

# ── /etc/inittab ─────────────────────────────────────────────
cat > /etc/inittab << 'INITTABEOF'
# デフォルトランレベル
id:3:initdefault:

# システム初期化
si:S:sysinit:/etc/rc.d/init.d/rcS

# ランレベル0: halt
l0:0:wait:/etc/rc.d/rc 0
# ランレベル1: シングルユーザー
l1:1:wait:/etc/rc.d/rc 1
# ランレベル3: マルチユーザー
l3:3:wait:/etc/rc.d/rc 3
# ランレベル6: reboot
l6:6:wait:/etc/rc.d/rc 6

# コンソール getty（tty1はrootで自動ログイン）
c1:2345:respawn:/sbin/agetty --autologin root tty1 38400
c2:2345:respawn:/sbin/agetty tty2 38400
c3:2345:respawn:/sbin/agetty tty3 38400

# Ctrl-Alt-Del
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
INITTABEOF

# ── /etc/rc.d/init.d/rcS (sysinit) ───────────────────────────
mkdir -p /etc/rc.d/init.d /etc/rc.d/rc3.d
cat > /etc/rc.d/init.d/rcS << 'RCSEOF'
#!/bin/bash
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys  || mount -t sysfs sysfs /sys
mountpoint -q /dev  || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm
mountpoint -q /run      || mount -t tmpfs tmpfs /run
hostname $(cat /etc/hostname 2>/dev/null || echo lfs)
mount -o remount,rw / 2>/dev/null || true
mkdir -p /var/log /var/run /var/lock
touch /var/log/wtmp /var/log/btmp /var/run/utmp 2>/dev/null || true
# 日本語キーボード＋コンソールフォント設定（文字化け対策）
[ -f /etc/vconsole.conf ] && source /etc/vconsole.conf
[ -n "${KEYMAP}" ] && loadkeys ${KEYMAP} 2>/dev/null || true
[ -n "${FONT}" ]   && setfont ${FONT}   2>/dev/null || true

# ── 全NICのリンクアップ（課題3: 自動リンクアップ）──────────
# udev が起動した後、全ての物理NICを一斉に up にする
echo "ネットワークインターフェースを初期化中..."
for iface in /sys/class/net/*/; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    # type=1 がイーサネット (ether)
    type=$(cat "${iface}type" 2>/dev/null || echo 0)
    if [ "$type" = "1" ]; then
        ip link set "$name" up 2>/dev/null && \
            echo "  up: $name" || true
    fi
done
# ループバックは必ず up
ip link set lo up 2>/dev/null || true

# sysctl 設定を適用（ping 権限等）
sysctl -p /etc/sysctl.d/10-network.conf 2>/dev/null || true

echo "システム初期化完了"
RCSEOF
chmod +x /etc/rc.d/init.d/rcS

# ── /etc/rc.d/rc ─────────────────────────────────────────────
cat > /etc/rc.d/rc << 'RCEOF'
#!/bin/bash
RUNLEVEL=$1
for script in /etc/rc.d/rc${RUNLEVEL}.d/S*; do
    [ -x "$script" ] && "$script" start
done
RCEOF
chmod +x /etc/rc.d/rc

# ── /etc/rc.d/init.d/reboot / halt ───────────────────────────
mkdir -p /etc/rc.d/rc0.d /etc/rc.d/rc6.d
cat > /etc/rc.d/init.d/halt << 'HALTEOF'
#!/bin/bash
case "$1" in
  start)
    echo "システムを停止しています..."
    sync
    /sbin/halt -d -f -i -p
    ;;
esac
HALTEOF
chmod +x /etc/rc.d/init.d/halt

cat > /etc/rc.d/init.d/reboot << 'REBOOTEOF'
#!/bin/bash
case "$1" in
  start)
    echo "システムを再起動しています..."
    sync
    /sbin/reboot -d -f -i
    ;;
esac
REBOOTEOF
chmod +x /etc/rc.d/init.d/reboot

# ランレベル0(halt)とランレベル6(reboot)にリンク
ln -sf ../init.d/halt   /etc/rc.d/rc0.d/S01halt
ln -sf ../init.d/reboot /etc/rc.d/rc6.d/S01reboot



echo ""
echo "[CLI] ===== CLI ビルド完了！ ====="
echo "  インストール済みツール:"
echo "    sudo nano git curl wget htop tmux tree"
echo "    bash-completion iproute2 dhcpcd openssh GRUB Linux kernel"
echo ""
echo "  ネットワーク修正適用済み:"
echo "    [1] ping有効化: CONFIG_INET/PACKET + sysctl ping_group_range"
echo "    [2] dhcpcd修正: dhcpcd.conf(allowinterfaces) + rc3.d/S30dhcpcd"
echo "    [3] 全NIC自動リンクアップ: udev rules + rcS内 ip link set up"
echo "    [4] NIC名固定: net.ifnames=0 biosdevname=0 は morning.sh のgrub.cfgに追記済み"
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
