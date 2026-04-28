# Linux From Scratch ビルド on Docker

> ⚠️ **動作環境: x86_64 系 Linux PC に Docker をインストールして実行してください**
> ARM (ラズパイ等) や Windows 上では正常に動作しません。

寝ている間に Docker 上で LFS 12.2 をビルドし、朝起きたら USB に焼いてすぐ起動できるプロジェクトです。

- **ベース**: Ubuntu 24.04 / LFS 12.2 (x86_64)
- **ターゲット**: CLI 構成（sudo / nano / git / curl / htop / tmux / tree / bash-completion / openssh / iproute2 / dhcpcd 他）
- **ブートローダー**: GRUB 2.12 (EFI, x86_64)

---

## 📁 ファイル構成

```
.
├── compose.yml             # Docker Compose 設定
├── Dockerfile              # Ubuntu 24.04 ベースのビルド環境
├── .env                    # 環境変数（バージョン・ミラー・CPUコア数等）
├── lfs.sh                  # コンテナ内ビルドスクリプト（エントリーポイント）
├── morning.sh              # 朝起きたら実行：USB に展開して起動可能にする
└── build/                  # ビルド成果物（gitignore 済み）
    ├── lfs-rootfs/         # rootfs 作業ディレクトリ
    ├── lfs-rootfs.tar.gz   # 完成 rootfs（morning.sh が使用）
    ├── lfs-rootfs.tar.gz.sha256
    ├── toolchain.log       # Step3: クロスツールチェーンログ
    ├── temptools.log       # Step3.5: 一時ツール群ログ
    ├── lfs-base.log        # Step4: LFS base ビルドログ
    ├── cli-build.log       # Step6: CLI ツールビルドログ
    ├── morning.log         # morning.sh の実行ログ
    └── FLAGS/              # 再開ポイント管理（ステップ完了フラグ）
```

---

## ⚙️ カスタマイズ（`.env`）

### 基本設定

| 変数名 | デフォルト値 | 説明 |
|---|---|---|
| `LFS_VERSION` | `12.2` | LFS バージョン |
| `CPU_CORE` | `4` | ビルド並列数（PCのコア数に合わせて調整） |
| `ROOT_PASSWORD` | `password` | rootfs 内 root パスワード |
| `TIME_ZONE` | `Asia/Tokyo` | タイムゾーン |
| `LOCALE` / `LANG` | `ja_JP.UTF-8` | ロケール |

### ミラー設定

スペース区切りで複数指定でき、左から順に試してフォールバックします。

| 変数名 | 対象 | デフォルト |
|---|---|---|
| `LFS_MIRRORS` | LFS ソースパッケージ一式 | OSUOSL → 公式 → lfs-matrix |
| `GNU_MIRRORS` | GNU パッケージ（GCC 等） | ftpmirror.gnu.org → JAIST → IIJ → kernel.org → 公式 |
| `GCC_INFRA_MIRRORS` | GCC インフラ（mpfr/gmp/mpc） | gcc.gnu.org |

### パッケージ個別 URL 上書き（`CLI_URL_*`）

ネットワーク制限のある環境や特定ミラーに固定したい場合にコメントを外して使用します。

```bash
# 例: GRUB を JAIST から取得する場合
CLI_URL_GRUB=https://ftp.jaist.ac.jp/pub/GNU/grub/grub-2.12.tar.xz
```

対応している変数一覧（未設定時は `lfs.sh` 内のデフォルト URL を使用）:

`CLI_URL_SUDO` / `CLI_URL_NANO` / `CLI_URL_CURL` / `CLI_URL_PCRE2` /
`CLI_URL_GIT` / `CLI_URL_HTOP` / `CLI_URL_LIBEVENT` / `CLI_URL_TMUX` /
`CLI_URL_TREE` / `CLI_URL_BASH_COMPLETION` / `CLI_URL_DBUS` /
`CLI_URL_IPROUTE2` / `CLI_URL_DHCPCD` / `CLI_URL_OPENSSH` /
`CLI_URL_LIBGPG_ERROR` / `CLI_URL_LIBGCRYPT` / `CLI_URL_GROFF` /
`CLI_URL_GRUB` / `CLI_URL_LIBPNG` / `CLI_URL_FREETYPE` /
`CLI_URL_UNIFONT` / `CLI_URL_EXPAT` / `CLI_URL_IPUTILS` /
`CLI_URL_KBD` / `CLI_URL_WHICH` / `CLI_URL_WGET` /
`CLI_URL_CMAKE` / `CLI_URL_NEOFETCH` / `CLI_URL_LIBPIPELINE`

---

## 🌙 寝る前：ビルド開始

```bash
# 初回またはイメージ変更時
docker compose up --build -d

# 2回目以降（コンテナ再起動・再開）
docker compose up -d
```

> **注意**: `docker compose logs -f` を Ctrl+C で止めてもコンテナは止まりません。
> コンテナの起動は必ず `-d`（デタッチモード）で実行してください。

進捗確認（別ターミナルで随時）:
```bash
docker logs -f Docker_LFS
```

ビルドには **6〜14時間** かかります（CPU・回線速度による）。

---

## ☀️ 朝起きたら：USB に書き込む

### 1. ビルド完了確認
```bash
docker logs Docker_LFS | tail -10
# [DONE] ... CLI LFS ビルド完了！ と出ていればOK
```

### 2. USB デバイスを確認
```bash
lsblk
# /dev/sdX を確認（例: /dev/sdb）
```

### 3. 書き込み実行
```bash
sudo bash morning.sh
```

⚠️ 指定した USB デバイスは **完全に消去** されます。

---

## 🖥️ 起動

1. USB をターゲット PC に差す
2. BIOS/UEFI の Boot Order を USB 優先に設定（Secure Boot は無効化）
3. 起動
   - ログイン: `root`
   - パスワード: `.env` の `ROOT_PASSWORD`（デフォルト: `password`）

### ⚠️ 起動しない場合（カーネルパニック）

ターゲット PC の内蔵ディスクの有無によって USB のデバイス名が変わります。
`morning.sh` の先頭にある `BOOT_DEVICE` 変数を書き換えて再実行してください。

| 状況 | USB のデバイス名 |
|------|----------------|
| 内蔵ディスクなし | `sda`（`sda2` がルート） |
| 内蔵ディスクあり | `sdb`（`sdb2` がルート） |

`morning.sh` の先頭にある `BOOT_DEVICE` 変数を書き換えて再実行するだけで対応できます：

```bash
# morning.sh の先頭
BOOT_DEVICE=sda   # ← 起動しない場合は sdb に変更
```

```bash
# 書き換えたら再実行
sudo bash morning.sh
```

---

## 🌐 イーサネットドライバの設定

LFS はカーネルを自前でビルドするため、ターゲット PC の NIC に対応したドライバを明示的に有効化しないとネット接続できません。`lfs.sh` 内のカーネル設定セクションに各ドライバがコメントアウトで用意されています。

### ステップ1: 自分の NIC を調べる

```bash
# PCI 接続の NIC を確認（最も確実）
lspci | grep -i ethernet

# ロード中のドライバ名を確認
ethtool -i eth0 | grep driver   # eth0 は実際の IF 名に置換
```

### ステップ2: カーネルオプション名を特定する

| `lspci` / `ethtool` の出力キーワード | 有効化するオプション | 対象 NIC の例 |
|---|---|---|
| `virtio` | `CONFIG_VIRTIO_NET` | QEMU/KVM virtio-net |
| `vmxnet3` / `VMware` | `CONFIG_VMXNET3` | VMware VMXNET3 |
| `82540` `82545` / `e1000` | `CONFIG_E1000` | Intel PRO/1000（旧世代） |
| `82566` `82574` `82579` / `e1000e` | `CONFIG_E1000E` | Intel PRO/1000 PCIe |
| `I210` `I350` `I354` / `igb` | `CONFIG_IGB` | Intel I210/I350 GbE |
| `82598` `82599` / `ixgbe` | `CONFIG_IXGBE` | Intel 10GbE |
| `XL710` `X710` / `i40e` | `CONFIG_I40E` | Intel 40GbE |
| `RTL-8139C+` / `8139cp` | `CONFIG_8139CP` | Realtek RTL-8139C+ |
| `RTL-8139` / `8139too` | `CONFIG_8139TOO` | Realtek RTL-8139（旧型番） |
| `RTL8111` `RTL8168` `RTL8411` / `r8169` | `CONFIG_R8169` | **Realtek GbE（現行品で最多）** |
| `NetXtreme II` / `bnx2` | `CONFIG_BNX2` | Broadcom NetXtreme II GbE |
| `BCM570x` / `tg3` | `CONFIG_TIGON3` | Broadcom NetXtreme GbE |
| `AR8131` `AR8151` / `atl1` `atl2` | `CONFIG_ATL1` / `CONFIG_ATL2` | Qualcomm Atheros |

> 💡 **迷ったら `CONFIG_R8169`**
> 現行の市販 PC・マザーボードに搭載されているオンボード NIC は Realtek RTL8111 系が最も多く、`r8169` ドライバで動作します。

### ステップ3: `lfs.sh` のコメントを外す

`lfs.sh` 内のカーネル設定セクション（`# ── イーサネットドライバ`）で、該当する行の先頭の `#` を削除します。

```bash
# 変更前
#scripts/config --enable CONFIG_R8169

# 変更後
scripts/config --enable CONFIG_R8169
```

変更後はカーネルを再ビルドしてください（Step6 フラグを削除して `docker compose up -d`）。

---

## 📦 起動後のパッケージ管理

LFS 起動後、`/root/.bashrc` に `build` / `update` コマンドが定義されています。

### `build` — パッケージのビルド・インストール

```bash
build <パッケージ名> [./configure フラグ...] [ミラー URL]
```

| 例 | 説明 |
|---|---|
| `build nano` | `/sources/nano*.tar.*` をそのままビルド |
| `build nano --enable-utf8 --disable-nls` | configure フラグを追加 |
| `build nano https://example.com/nano-8.3.tar.xz` | ミラーから取得してビルド |
| `build nano --enable-utf8 https://example.com/nano-8.3.tar.xz` | フラグとミラーを同時指定 |

- URL（`http://` / `https://` / `ftp://` で始まるもの）は自動的にミラーと判定されます。
- ビルドシステムは **autoconf (`./configure`) / CMake / Meson** を自動判定します。

### `update` — パッケージのアップデート

```bash
update <パッケージ名> [ミラー URL]
```

| 例 | 説明 |
|---|---|
| `update nano` | 既存の tarball で再ビルド・再インストール |
| `update nano https://example.com/nano-8.4.tar.xz` | 新バージョンを取得して更新（旧 tarball を自動削除） |

---

## 📋 ビルドステップ詳細

| ステップ | 内容 | LFS Book 章 | 目安時間 |
|---|---|---|---|
| Step1 | FHS ディレクトリ構造作成 | Chapter 4 | 数秒 |
| Step2 | LFS ソースパッケージ取得 | Chapter 3 | 回線速度次第 |
| Step3 | クロスツールチェーン | Chapter 5 | 30〜60分 |
| Step3.5 | 一時ツール群（chroot 準備） | Chapter 6 | 60〜120分 |
| Step4 | LFS base システム（chroot） | Chapter 7〜8 | 120〜240分 |
| Step5 | CLI ツール追加ダウンロード | BLFS | 回線速度次第 |
| Step6 | CLI ツールビルド（chroot） | BLFS | 60〜120分 |
| Step7 | rootfs を tar.gz に圧縮 | — | 数分 |

各ステップは `build/FLAGS/` にフラグファイルを作成して管理されます。
コンテナを再起動しても完了済みのステップはスキップされ、途中から再開します。

### Step6 でインストールされるパッケージ

LFS base に含まれる標準パッケージに加えて、以下を chroot 内でビルド・インストールします:

| パッケージ | 役割 |
|---|---|
| libcap | ケーパビリティライブラリ（再ビルド） |
| D-Bus | プロセス間通信 |
| libgpg-error / libgcrypt | 暗号ライブラリ |
| sudo | 権限昇格 |
| nano | テキストエディタ |
| PCRE2 | 正規表現ライブラリ（git 依存） |
| curl | HTTP クライアント |
| git | バージョン管理 |
| libevent | イベントライブラリ（tmux 依存） |
| tmux | ターミナルマルチプレクサ |
| htop | プロセスモニタ |
| tree | ディレクトリツリー表示 |
| bash-completion | Bash 補完 |
| iproute2 | ネットワーク設定（ip コマンド） |
| dhcpcd | DHCP クライアント |
| OpenSSH | SSH サーバー／クライアント |
| kbd | キーボードレイアウト・コンソールフォント |
| which | コマンド検索 |
| wget | ファイルダウンロード |
| CMake | ビルドシステム（iputils 依存） |
| iputils | ping / ping6 / arping |
| neofetch | ログイン時システム情報表示 |
| libpng | PNG ライブラリ（FreeType 依存） |
| FreeType | フォントレンダリング（grub-mkfont 必須依存） |
| GRUB 2.12 | EFI ブートローダー |
| Linux カーネル | LFS ソースに含まれる版 |

#### GRUB の依存関係

```
GRUB 2.12 (--enable-grub-mkfont --with-platform=efi)
├── freetype2-2.13.3     ← grub-mkfont 必須
│     ├── zlib           ← LFS base 済み
│     ├── bzip2          ← LFS base 済み
│     └── libpng-1.6.44
├── objcopy (binutils)   ← LFS base 済み
└── efibootmgr           ← 不要（--removable フラグにより EFI エントリ書き込みをスキップ）
```

---

## 🔁 再開・やり直し

### 途中から再開（コンテナ再起動後）
```bash
docker compose up -d
```

### 特定ステップからやり直す
```bash
# 例: Step6（CLI ビルド）だけやり直す場合
rm ./build/FLAGS/.step6_cli_done
rm -f ./build/FLAGS/.build_done
docker compose up -d
```

```bash
# 例: Step5（CLI ダウンロード）以降をやり直す場合
rm ./build/FLAGS/.step5_cli_sources_done
rm ./build/FLAGS/.step6_cli_done
rm -f ./build/FLAGS/.build_done
docker compose up -d
```

### 全部やり直す
```bash
docker compose down
rm -rf ./build/FLAGS ./build/lfs-rootfs
docker compose up --build -d
```

---

## 🐛 トラブルシューティング

### コンテナがすぐ終了する

`docker compose logs -f` を Ctrl+C で止めると、コンテナも道連れに終了します。
ログ確認には `docker logs -f Docker_LFS` を使い、コンテナ起動は必ず `-d` で行ってください。

```bash
docker compose up -d
docker logs -f Docker_LFS   # Ctrl+C してもコンテナは止まらない
```

### ビルドエラーの確認

```bash
# Step3 クロスツールチェーン
tail -50 ./build/toolchain.log

# Step3.5 一時ツール群
tail -50 ./build/temptools.log

# Step4 LFS base
tail -50 ./build/lfs-base.log

# Step6 CLI ツール（GRUB / FreeType 等）
tail -50 ./build/cli-build.log
grep -i "error\|warn\|fail" ./build/cli-build.log | grep -i "grub\|freetype\|libpng"
```

### ソースのダウンロードが失敗した

```bash
# ダウンロード失敗フラグを確認
ls ./build/FLAGS/dl_failed_*

# .env のミラーを変更して Step2 から再試行
rm ./build/FLAGS/.step2_sources_done
rm -f ./build/FLAGS/.build_done
docker compose up -d
```

利用可能なミラー例（`.env` の `LFS_MIRRORS` に指定）:
```
https://ftp.osuosl.org/pub/lfs/lfs-packages/12.2    # OSUOSL（高速）
https://www.linuxfromscratch.org/lfs/downloads        # LFS 公式
https://ftp.lfs-matrix.net/pub/lfs/lfs-packages/12.2 # lfs-matrix
```

### USB から起動できない（カーネルパニック: root= is invalid）

ターゲット PC の内蔵ディスクの有無によって USB のデバイス名が変わります。
`morning.sh` の先頭にある `BOOT_DEVICE` 変数を書き換えて再実行するだけで対応できます。

```bash
# 内蔵ディスクがある PC の場合
BOOT_DEVICE=sdb
```

```bash
sudo bash morning.sh
```

### ネットワークに繋がらない（起動後）

イーサネットドライバが有効化されていない可能性があります。[イーサネットドライバの設定](#-イーサネットドライバの設定) を参照して、該当するドライバを `lfs.sh` で有効化し、カーネルを再ビルドしてください。

```bash
# 現在認識されている NIC を確認
ip link show

# NIC はあるが IP が取れない場合は dhcpcd を手動実行
dhcpcd eth0
```

### GRUB インストールに失敗する（morning.sh）

```bash
cat ./build/morning.log
```

よくある原因:
- `grub-install` が rootfs 内に存在しない → `cli-build.log` で GRUB ビルドの成否を確認
- Secure Boot が有効 → BIOS/UEFI で Secure Boot を無効化する

### `build` / `update` コマンドが使えない

`.bashrc` が読み込まれていない場合があります。

```bash
source /root/.bashrc

# それでも動かない場合は関数定義を確認
type build
type update
```

---

## 参照

- [Linux From Scratch 12.2](https://www.linuxfromscratch.org/lfs/view/12.2/)
- [Beyond Linux From Scratch (BLFS)](https://www.linuxfromscratch.org/blfs/view/stable/)
- [GRUB EFI インストール (BLFS)](https://www.linuxfromscratch.org/blfs/view/stable/postlfs/grub-efi.html)
