# Linux From Scratch ビルド on Docker

寝ている間に Docker 上で LFS 12.2 をビルドし、朝起きたら USB に焼いてすぐ起動できるプロジェクトです。

- **ベース**: Ubuntu 24.04 / LFS 12.2 (x86_64)
- **ターゲット**: CLI 構成（sudo / nano / git / curl / wget / htop / tmux / tree / rsync / vim / bash-completion / openssh / iproute2 / dhcpcd）
- **ブートローダー**: GRUB 2

---

## 📁 ファイル構成

```
.
├── compose.yml             # Docker Compose 設定
├── Dockerfile              # Ubuntu 24.04 ベースのビルド環境
├── .env                    # 環境変数（バージョン・CPUコア数・パス等）
├── lfs.sh                  # コンテナ内ビルドスクリプト（エントリーポイント）
├── morning.sh              # 朝起きたら実行：USB に展開して起動可能にする
└── build/                  # ビルド成果物（gitignore 推奨）
    ├── lfs-rootfs/         # rootfs 作業ディレクトリ
    ├── lfs-rootfs.tar.gz   # 完成 rootfs（morning.sh が使用）
    ├── lfs-rootfs.tar.gz.sha256
    ├── download-lfs.log    # LFS ソースダウンロードログ
    ├── toolchain.log       # Step3: クロスツールチェーンログ
    ├── temptools.log       # Step3.5: 一時ツール群ログ
    ├── lfs-base.log        # Step4: LFS base ビルドログ
    ├── cli-build.log       # Step6: CLI ツールビルドログ
    └── FLAGS/              # 再起動時の再開ポイント管理
        ├── .step1_dirs_done
        ├── .step2_sources_done
        ├── .step3_toolchain_done
        ├── .step3_5_temptools_done
        ├── .step4_lfs_base_done
        ├── .step5_cli_sources_done
        ├── .step6_cli_done
        └── .build_done     # ビルド完了フラグ
```

---

## ⚙️ カスタマイズ（`.env`）

| 項目 | 変数名 | デフォルト値 |
|---|---|---|
| LFS バージョン | `LFS_VERSION` | `12.2` |
| CPU コア数 | `CPU_CORE` | `4` |
| root パスワード | `ROOT_PASSWORD` | `password` |
| タイムゾーン | `TIME_ZONE` | `Asia/Tokyo` |
| ロケール | `LOCALE` / `LANG` | `ja_JP.UTF-8` |
| ソースミラー | `LFS_MIRROR` | 公式サイト |

---

## 🌙 寝る前：ビルド開始

```bash
# 初回またはイメージ変更時
docker compose up --build -d

# 2回目以降（再開）
docker compose up -d
```

> **注意**: `docker compose logs -f` を **Ctrl+C で止めてもコンテナは止まりません**。
> `docker compose up` は必ず `-d`（デタッチモード）で実行してください。

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
2. BIOS/UEFI の Boot Order を USB 優先に設定
3. 起動
   - ログイン: `root`
   - パスワード: `.env` の `ROOT_PASSWORD`（デフォルト: `password`）

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

---

## 🔁 再開・やり直し

### 途中から再開（コンテナ再起動後）
```bash
docker compose up -d
```

### 特定ステップからやり直す
```bash
# 例: Step3.5 からやり直す場合
rm ./build/FLAGS/.step3_5_temptools_done
rm ./build/FLAGS/.step4_lfs_base_done
rm ./build/FLAGS/.step5_cli_sources_done
rm ./build/FLAGS/.step6_cli_done
rm -f ./build/FLAGS/.build_done
docker compose up -d
```

### 全部やり直す
```bash
docker compose down
rm -rf ./build/FLAGS ./build/lfs-rootfs
docker compose up -d
```

---

## 🐛 トラブルシューティング

### コンテナがすぐ終了する（exit code 141）
`docker compose logs -f` を Ctrl+C で止めると、コンテナも道連れに終了します。
ログ確認には `docker logs -f Docker_LFS` を使い、コンテナ起動は必ず `-d` で行ってください。

```bash
docker compose up -d
docker logs -f Docker_LFS   # Ctrl+C してもコンテナは止まらない
```

### ビルドエラーの確認
```bash
# Step3 エラー
tail -50 ./build/toolchain.log

# Step3.5 エラー
tail -50 ./build/temptools.log

# Step4 エラー
tail -50 ./build/lfs-base.log

# Step6 エラー
tail -50 ./build/cli-build.log
```

### ソースのダウンロードが失敗した
```bash
# ダウンロードログを確認
grep -i "error\|failed" ./build/download-lfs.log

# .env の LFS_MIRROR を変更して別のミラーを試す（OSUOSL は高速）
# LFS_MIRROR=https://ftp.osuosl.org/pub/lfs/lfs-packages/12.2
```

---

## 参照

- [Linux From Scratch 12.2](https://www.linuxfromscratch.org/lfs/view/12.2/)
- [Beyond Linux From Scratch (BLFS)](https://www.linuxfromscratch.org/blfs/view/stable/)
