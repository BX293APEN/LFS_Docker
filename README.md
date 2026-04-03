# Linux From Scratch ビルド on Docker

寝ている間に Docker 上で LFS (Linux From Scratch) をビルドし、
朝起きたら USB に焼いてすぐ起動できるプロジェクトです。

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
    ├── lfs-rootfs/         # chroot 作業ディレクトリ
    ├── lfs-rootfs.tar.gz   # 完成した rootfs（morning.sh が使用）
    ├── lfs-rootfs.tar.gz.sha256
    ├── download.log        # ソースダウンロードログ
    ├── toolchain.log       # クロスツールチェーンビルドログ
    ├── chroot-build.log    # chroot 内ビルドログ
    └── FLAGS/
        ├── .step1_dirs_done
        ├── .step2_sources_done
        ├── .step3_toolchain_done
        ├── .step5_chroot_done
        └── .build_done     # ビルド完了フラグ
```

---

## 🌙 寝る前：ビルド開始

```bash
docker compose up --build -d
```

進捗確認（別ターミナル）:
```bash
docker logs -f Docker_LFS
```

ビルドには **6〜12時間** かかります（CPU・回線速度による）。

---

## ☀️ 朝起きたら：USB に書き込む

### 1. ビルド完了確認
```bash
docker logs Docker_LFS | tail -5
# [DONE] ... ビルド完了！ と出ていればOK
```

### 2. 実行

```bash
sudo bash morning.sh
```

⚠️ 指定した USB デバイスは **完全に消去** されます。

---

## 🖥️ 起動

1. USB を抜いてターゲット PC に差す
2. BIOS/UEFI の Boot Order を USB 優先に設定
3. 起動！
   - ログイン: `root`
   - パスワード: `password`（`.env` の `ROOT_PASSWORD` で変更可）

---

## 🔁 再ビルドしたい場合

```bash
# 全部やり直し
rm -rf ./build/FLAGS ./build/lfs-rootfs
docker compose up --build -d

# 特定ステップから再開（例: Step3 からやり直し）
rm ./build/FLAGS/.step3_toolchain_done
rm ./build/FLAGS/.step5_chroot_done
rm ./build/FLAGS/.build_done
docker compose up -d
```

---

## ⚙️ カスタマイズ

| 変更したい項目 | 変更箇所 |
|---|---|
| LFS バージョン | `.env` の `LFS_VERSION` |
| CPU コア数 | `.env` の `CPU_CORE` |
| root パスワード | `.env` の `ROOT_PASSWORD` |
| タイムゾーン | `.env` の `TIME_ZONE` |
| ソースミラー | `.env` の `LFS_MIRROR` |
| ロケール | `.env` の `LOCALE` / `LANG` |

---

## 🐛 トラブルシューティング

**ビルドが途中で止まった**
```bash
docker compose down
# 止まったステップのフラグだけ削除して再開
rm ./build/FLAGS/.step3_toolchain_done
docker compose up -d
```

**ソースのダウンロードが失敗した**
```bash
# download.log を確認
cat ./build/download.log | grep -i error
# 手動で再ダウンロード
docker compose run --rm linux wget -c <URL> -P /build/lfs-rootfs/sources/
```

**morning.sh が "ビルド完了フラグなし" と言う**
→ `docker logs Docker_LFS` でエラーを確認してください。

---

## 📋 ビルドステップ概要

| ステップ | 内容 | 参照 |
|---|---|---|
| Step1 | FHS ディレクトリ作成 | LFS Book Chapter 4 |
| Step2 | ソースパッケージ取得 | LFS Book Chapter 3 |
| Step3 | クロスツールチェーン | LFS Book Chapter 5 |
| Step5 | chroot 内システムビルド | LFS Book Chapter 7-8 |
| Step6 | tar.gz 圧縮 | — |

参照: https://www.linuxfromscratch.org/lfs/view/stable/
