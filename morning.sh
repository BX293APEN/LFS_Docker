#!/usr/bin/env bash
# =============================================================================
# morning.sh  ―  朝起きたら実行（ホスト Ubuntu 上で sudo bash morning.sh）
# 役割: lfs-rootfs.tar.gz を USB に展開して起動可能にする
#
# 実行前にやること:
#   1. USB を挿す
#   2. lsblk でデバイス名を確認する
#   3. sudo bash morning.sh を実行し、デバイス名を入力
#
# 警告: 指定したデバイスは完全消去されます！
# =============================================================================

set -euo pipefail

echo "デバイスを選んでください："
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | head -n1 && \
lsblk -po NAME,SIZE,LABEL,MOUNTPOINT | grep -E '^(/dev/sd|/dev/nvme)|^├─|^└─'

echo -n "USBデバイス (例: sdb or /dev/sdb) : "
read INPUT

# /dev/付きでも無しでもOKにする
USB_DEV="/dev/${INPUT#/dev/}"

CURRENT_MP=$(lsblk -no MOUNTPOINT "$USB_DEV")

# ──────────────────────────────

ROOTFS_TAR="./build/lfs-rootfs.tar.gz"
DONE_FLAG="./build/FLAGS/.build_done"
MOUNT_ROOT="/mnt/lfs"
LOGFILE="./build/morning.log"

exec > >(tee -a "$LOGFILE") 2>&1
echo "============================================"
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') morning.sh 開始"
echo "============================================"

# ─────────────────────────────────────────────
# 0. 事前確認
# ─────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] root権限が必要です: sudo bash morning.sh"
    exit 1
fi

# すでにマウントされていたらアンマウント
if [ -n "$CURRENT_MP" ]; then
    echo "[INFO] アンマウントします"
    while IFS= read -r mp; do
        if [ -n "$mp" ]; then
            umount "$mp"
        fi
    done <<< "$CURRENT_MP"
fi

if [[ "$USB_DEV" == "/dev/sdX" ]]; then
    echo "[ERROR] USB_DEV が未設定です。"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL
    exit 1
fi

if [[ ! -b "$USB_DEV" ]]; then
    echo "[ERROR] ${USB_DEV} が見つかりません。"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL
    exit 1
fi

if [[ ! -f "$ROOTFS_TAR" ]]; then
    echo "[ERROR] ${ROOTFS_TAR} が存在しません。"
    if [[ ! -f "$DONE_FLAG" ]]; then
        echo "  ビルドがまだ完了していない可能性があります。"
        echo "  docker logs -f Docker_LFS で進捗を確認してください。"
    fi
    exit 1
fi

if [[ ! -f "$DONE_FLAG" ]]; then
    echo "[WARN] ビルド完了フラグ (${DONE_FLAG}) がありません。"
    echo "  ビルドが中途半端かもしれません。続行しますか？"
fi

echo ""
echo "========================================================"
echo "  警告: ${USB_DEV} を完全に消去してフォーマットします"
echo "  現在の状態:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL "$USB_DEV" || true
echo "========================================================"
read -rp "本当に続けますか？ (yes と入力して Enter): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "中止しました。"; exit 0; }

# ─────────────────────────────────────────────
# cleanup トラップ（異常終了時も安全にアンマウント）
# ─────────────────────────────────────────────
cleanup() {
    echo "[INFO] クリーンアップ中..."
    umount -R "${MOUNT_ROOT}/dev"      2>/dev/null || true
    umount -R "${MOUNT_ROOT}/sys"      2>/dev/null || true
    umount    "${MOUNT_ROOT}/proc"     2>/dev/null || true
    umount    "${MOUNT_ROOT}/boot/efi" 2>/dev/null || true
    umount    "${MOUNT_ROOT}"          2>/dev/null || true
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 1. 既存マウントをアンマウント
# ─────────────────────────────────────────────
echo "[INFO] 既存マウントの確認・解除..."
for part in "${USB_DEV}"?*; do
    [[ -b "$part" ]] || continue
    if mountpoint -q "$part" 2>/dev/null; then
        umount "$part" && echo "  アンマウント: $part"
    fi
done

# ─────────────────────────────────────────────
# 2. パーティション作成（GPT: EFI 512MiB + root 残り全部）
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') パーティション作成中..."

sfdisk "$USB_DEV" << 'SFDISK_EOF'
label: gpt
,512M,U,*
,,L,
SFDISK_EOF

sleep 2
partprobe "$USB_DEV" 2>/dev/null || true
sleep 1

# デバイス名判定（/dev/sdb1 or /dev/nvme0n1p1 など）
if [[ "$USB_DEV" =~ [0-9]$ ]]; then
    EFI_PART="${USB_DEV}p1"
    ROOT_PART="${USB_DEV}p2"
else
    EFI_PART="${USB_DEV}1"
    ROOT_PART="${USB_DEV}2"
fi

if [[ ! -b "$EFI_PART" ]] || [[ ! -b "$ROOT_PART" ]]; then
    echo "[ERROR] パーティションが見つかりません: $EFI_PART / $ROOT_PART"
    lsblk "$USB_DEV"
    exit 1
fi

# ─────────────────────────────────────────────
# 3. フォーマット
# ─────────────────────────────────────────────
echo "[INFO] フォーマット中..."
# UUIDを事前に生成して mkfs に渡す
# こうすることでマウント/アンマウント時のUUID変更を防ぐ
ROOT_UUID="$(cat /proc/sys/kernel/random/uuid)"
EFI_UUID="$(cat /proc/sys/kernel/random/uuid)"
wipefs -a "$EFI_PART"
wipefs -a "$ROOT_PART"
mkfs.vfat -F32 -n "EFI"  "$EFI_PART"
mkfs.ext4 -F   -L "lfs" -U "$ROOT_UUID" "$ROOT_PART"
udevadm settle
echo "[INFO] 固定UUID ROOT=${ROOT_UUID}"

# ─────────────────────────────────────────────
# 4. マウント
# ─────────────────────────────────────────────
echo "[INFO] マウント中..."
mkdir -p "$MOUNT_ROOT"
mount "$ROOT_PART" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT/boot/efi"
mount "$EFI_PART"  "$MOUNT_ROOT/boot/efi"

# ─────────────────────────────────────────────
# 5. rootfs 展開
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') rootfs 展開中（数分かかります）..."
tar xpf "$ROOTFS_TAR"       \
    --numeric-owner          \
    --preserve-permissions   \
    -C "$MOUNT_ROOT"         \
    --strip-components=1

# ─────────────────────────────────────────────
# 6. fstab を UUID で書き換え
# ─────────────────────────────────────────────
echo "[INFO] fstab 生成中..."
# UUID はフォーマット時に固定済みなのでそのまま使用
EFI_UUID=$(blkid -c /dev/null -s UUID -o value "$EFI_PART")
echo "[INFO] UUID ROOT=${ROOT_UUID} EFI=${EFI_UUID}"

cat > "$MOUNT_ROOT/etc/fstab" << FSTAB_EOF
# <fs>                                  <mountpoint>  <type>  <opts>            <dump> <pass>
UUID=${ROOT_UUID}  /          ext4    defaults,noatime  0      1
UUID=${EFI_UUID}   /boot/efi  vfat    defaults          0      2
FSTAB_EOF

echo "  ROOT UUID: $ROOT_UUID"
echo "  EFI  UUID: $EFI_UUID"

# ─────────────────────────────────────────────
# 7. bind マウント（chroot内GRUB用）
# ─────────────────────────────────────────────
echo "[INFO] bind マウント中..."
mount --types proc /proc     "$MOUNT_ROOT/proc"
mount --rbind      /sys      "$MOUNT_ROOT/sys"
mount --make-rslave          "$MOUNT_ROOT/sys"
mount --rbind      /dev      "$MOUNT_ROOT/dev"
mount --make-rslave          "$MOUNT_ROOT/dev"
cp /etc/resolv.conf "$MOUNT_ROOT/etc/resolv.conf"

# ─────────────────────────────────────────────
# 8. grub.cfg 生成（ホスト側でプレースホルダ+sed方式）
#    ヒアドキュメントの入れ子クォート問題を完全回避
# ─────────────────────────────────────────────
echo "[INFO] grub.cfg 生成中..."

# カーネルファイル名・initrdをホスト側から取得
KERNEL=$(ls "${MOUNT_ROOT}/boot/vmlinuz-"* 2>/dev/null | head -1 | xargs basename)
if [[ -z "${KERNEL}" ]]; then
    echo "[ERROR] /boot/vmlinuz-* が見つかりません"
    exit 1
fi
echo "[INFO] カーネル: ${KERNEL}  UUID: ${ROOT_UUID}"

INITRD_LINE=""
INITRD_FILE=$(ls "${MOUNT_ROOT}/boot/initrd-"* "${MOUNT_ROOT}/boot/initramfs-"* 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
if [[ -n "${INITRD_FILE}" ]]; then
    INITRD_LINE="    initrd /boot/${INITRD_FILE}"
    echo "[INFO] initrd: ${INITRD_FILE}"
fi

# プレースホルダ(__ROOT_UUID__ 等)で grub.cfg を生成し、あとで sed で置換
mkdir -p "${MOUNT_ROOT}/boot/grub"
cat > "${MOUNT_ROOT}/boot/grub/grub.cfg" << 'CFGEOF'
# /boot/grub/grub.cfg - generated by morning.sh
set default=0
set timeout=10

insmod part_gpt
insmod ext2
insmod fat

terminal_output console
terminal_input  console

search --no-floppy --fs-uuid --set=root __ROOT_UUID__

# USBブート用: rootwait + rootdelay でデバイス認識を待つ
menuentry "Linux From Scratch" {
    set gfxpayload=text
    linux /boot/__KERNEL__ root=UUID=__ROOT_UUID__ rw rootfstype=ext4 rootwait rootdelay=10 nomodeset console=tty0
__INITRD_LINE__
}

menuentry "Linux From Scratch (verbose boot)" {
    set gfxpayload=text
    linux /boot/__KERNEL__ root=UUID=__ROOT_UUID__ rw rootfstype=ext4 rootwait rootdelay=10 nomodeset console=tty0 loglevel=7 ignore_loglevel
__INITRD_LINE__
}

menuentry "Linux From Scratch (EFI framebuffer)" {
    set gfxpayload=keep
    linux /boot/__KERNEL__ root=UUID=__ROOT_UUID__ rw rootfstype=ext4 rootwait rootdelay=10 console=tty0 video=efifb:on
__INITRD_LINE__
}
CFGEOF

# sed でプレースホルダを実際の値に置換
sed -i \
    -e "s|__ROOT_UUID__|${ROOT_UUID}|g" \
    -e "s|__KERNEL__|${KERNEL}|g" \
    -e "s|__INITRD_LINE__|${INITRD_LINE}|g" \
    "${MOUNT_ROOT}/boot/grub/grub.cfg"

echo "[INFO] grub.cfg 生成完了 --- linux行確認:"
grep "linux " "${MOUNT_ROOT}/boot/grub/grub.cfg" | head -1

# ─────────────────────────────────────────────
# 9. chroot 内で GRUB インストール
# ─────────────────────────────────────────────
echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') GRUB インストール中..."

if [[ ! -f "${MOUNT_ROOT}/usr/bin/grub-install" ]] && \
   [[ ! -f "${MOUNT_ROOT}/usr/sbin/grub-install" ]]; then
    echo "[WARN] GRUB が rootfs に含まれていません。スキップ..."
else
    chroot "$MOUNT_ROOT" /usr/bin/env -i \
        HOME=/root \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash << 'GRUB_EOF'
set -e

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=lfs \
    --removable \
    --modules="part_gpt part_msdos ext2 fat normal boot linux configfile \
               search search_fs_uuid search_fs_file search_label \
               minicmd ls echo test true"

# EFI パーティションにモジュールをコピー
GRUB_MOD_SRC="/usr/lib/grub/x86_64-efi"
GRUB_MOD_DST="/boot/efi/EFI/BOOT/grub"
mkdir -p "${GRUB_MOD_DST}"
cp -r "${GRUB_MOD_SRC}/"*.mod "${GRUB_MOD_DST}/" 2>/dev/null || true
cp -r "${GRUB_MOD_SRC}/"*.lst "${GRUB_MOD_DST}/" 2>/dev/null || true
echo "[CHROOT] EFI モジュール数: $(find /boot/efi -name '*.mod' | wc -l)"

# 日本語キーボード設定
cat > /etc/vconsole.conf << 'VCEOF'
KEYMAP=jp106
FONT=Lat2-Terminus16
VCEOF

echo "[CHROOT] GRUB 完了"
GRUB_EOF

    # UUID はフォーマット時に固定済みなので再取得不要
    # EFI パーティションに最終版 grub.cfg をコピー
    cp "${MOUNT_ROOT}/boot/grub/grub.cfg" "${MOUNT_ROOT}/boot/efi/EFI/BOOT/grub.cfg"
    echo "[INFO] grub.cfg → EFI パーティションにコピー完了"
    echo "[INFO] 最終 linux 行:"
    grep "linux " "${MOUNT_ROOT}/boot/grub/grub.cfg" | head -1
fi

# ─────────────────────────────────────────────
# 10. アンマウント（トラップより先に明示的に実施）
# ─────────────────────────────────────────────
trap - EXIT
echo "[INFO] アンマウント中..."
umount -R "${MOUNT_ROOT}/dev"      || true
umount -R "${MOUNT_ROOT}/sys"      || true
umount    "${MOUNT_ROOT}/proc"     || true
umount    "${MOUNT_ROOT}/boot/efi"
umount    "${MOUNT_ROOT}"
sync

echo ""
echo "============================================"
echo "[DONE] $(date '+%Y-%m-%d %H:%M:%S')"
echo "USB ${USB_DEV} に LFS Linux を書き込みました！"
echo ""
echo "次のステップ:"
echo "  1. USB を抜いてターゲットPCに差す"
echo "  2. BIOS/UEFI の Boot Order を USB 優先に設定"
echo "  3. 起動！"
echo "  ログイン: root / password（.env の ROOT_PASSWORD で変更可）"
echo "============================================"
