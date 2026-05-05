# GitHub Actions Windows ビルド — Copilot 向けコンテキストドキュメント

このドキュメントは GitHub Copilot が `.github/workflows/windows-build.yml` の
問題を修正・改善する際に必要なすべての背景情報を記載したものです。

---

## ゴールと現状

### 達成したいこと

`windows-resize` ブランチへの push または手動トリガー (`workflow_dispatch`) で、
GitHub Actions が Windows 向けスタンドアロン配布パッケージを自動ビルドし、
ZIP ファイルとしてアーティファクトにアップロードする。

### 配布パッケージの内容（期待する成果物）

```
uxplay-windows.zip を展開すると:
  uxplay.exe          ← メイン実行ファイル (~1MB)
  uxplay.bat          ← ランチャー（これをダブルクリックして起動）
  ca-bundle.crt       ← HTTPS証明書検証用
  *.dll               ← 約122個の依存DLL
  gstreamer-1.0/      ← GStreamerプラグイン (~27個の.dll)
    libexec/
      gst-plugin-scanner.exe  ← プラグインスキャナー（必須）
  gio/
    modules/
      libgiognutls.dll  ← TLS/HTTPS通信モジュール（必須）
合計: 約174MB（ZIP圧縮後 約80MB）
```

### 現在の関連ファイル

- `.github/workflows/windows-build.yml` ← CI ワークフロー（要修正対象）
- `deploy_windows.sh` ← DLL同梱スクリプト（ローカル・CI 共用）
- `CMakeLists.txt` + `renderers/CMakeLists.txt` + `lib/CMakeLists.txt` ← cmake設定

---

## ローカルビルド環境（正常動作確認済み）

| 項目 | 値 |
|------|-----|
| OS | Windows 11 Pro |
| ツールチェーン | MSYS2 MINGW64 (`C:\msys64\mingw64\bin`) |
| GCC | 16.1.0 |
| CMake | 4.3.2 |
| Ninja | 1.13.2 |
| GStreamer | 1.28.2（MSYS2 pacman でインストール） |
| libplist | 2.7.0 |
| OpenSSL | 3.6.2 |
| Bonjour SDK | `C:\Program Files\Bonjour SDK`（Apple 公式 SDK） |
| ソース | `F:\git\UxPlay\` |
| ビルド出力 | `F:\git\UxPlay\build\` |

### ローカルでの正常ビルドコマンド

```bash
# MSYS2 MINGW64 シェルから実行
export PATH="/c/msys64/mingw64/bin:$PATH"
export PKG_CONFIG_EXECUTABLE="/c/msys64/mingw64/bin/pkg-config.exe"
export BONJOUR_SDK_HOME="C:/Program Files/Bonjour SDK"

cd /f/git/UxPlay
rm -rf build

cmake -B build -S . \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPKG_CONFIG_EXECUTABLE="/c/msys64/mingw64/bin/pkg-config.exe"

cmake --build build --parallel
# → build/uxplay.exe が生成される

bash deploy_windows.sh
# → build/ に DLL・プラグインが同梱される
```

---

## 依存関係の詳細

### CMake で検出される依存パッケージ

#### `lib/CMakeLists.txt` の依存

| パッケージ | 要求バージョン | cmake での検出方法 |
|-----------|-----------|------------|
| libplist | >= 2.0 | `pkg_search_module(PLIST REQUIRED libplist-2.0)` |
| OpenSSL | >= 1.1.1 | `find_package(OpenSSL 1.1.1 REQUIRED)` |
| **dns_sd（Bonjour）** | - | **Windows 専用** → 下記参照 |
| wsock32 / ws2_32 / iphlpapi | - | MinGW 標準（自動リンク） |

#### `renderers/CMakeLists.txt` の依存

| パッケージ | 要求バージョン |
|-----------|-----------|
| gstreamer-1.0 | >= 1.4 |
| gstreamer-sdp-1.0 | >= 1.4 |
| gstreamer-video-1.0 | >= 1.4 |
| gstreamer-app-1.0 | >= 1.4 |

---

## ⚠️ Bonjour SDK — 最大の課題

### なぜ問題か

`lib/CMakeLists.txt` は Windows で以下の**固定ディレクトリ構造**を要求する:

```cmake
# lib/CMakeLists.txt (抜粋)
if (WIN32)
  if (DEFINED ENV{BONJOUR_SDK_HOME})
    set(BONJOUR_SDK "$ENV{BONJOUR_SDK_HOME}")
  else()
    set(BONJOUR_SDK "C:\\Program Files\\Bonjour SDK")
  endif()
  set(DNSSD "${BONJOUR_SDK}/Lib/x64/dnssd.lib")
  target_link_libraries(airplay ${DNSSD})
  target_include_directories(airplay PUBLIC "${BONJOUR_SDK}/Include")
```

つまり cmake は `$BONJOUR_SDK_HOME` 環境変数が指すディレクトリに
以下のファイルが存在することを期待する:

```
$BONJOUR_SDK_HOME/
  Include/
    dns_sd.h        ← ヘッダー
  Lib/
    x64/
      dnssd.lib     ← インポートライブラリ
```

### CI での解決策：mdnsresponder シム

Apple の Bonjour SDK を CI に配置する代わりに、
MSYS2 の **`mingw-w64-x86_64-mdnsresponder`** パッケージが提供するファイルを
上記の構造に見立てたシムディレクトリとして作成する。

```bash
# mdnsresponder がインストールするファイル
/mingw64/include/dns_sd.h          ← dns_sd.h（Apple SDK と互換）
/mingw64/lib/libdns_sd.dll.a       ← インポートライブラリ（.dll.a 形式）
/mingw64/bin/libdns_sd.dll         ← ランタイム DLL
```

```bash
# シム作成スクリプト（windows-build.yml の "Create Bonjour SDK shim" ステップ）
SHIM="$(cygpath -u "$GITHUB_WORKSPACE")/ci-bonjour-sdk"
mkdir -p "$SHIM/Lib/x64" "$SHIM/Include"
cp /mingw64/include/dns_sd.h "$SHIM/Include/"
cp /mingw64/lib/libdns_sd.dll.a "$SHIM/Lib/x64/dnssd.lib"
echo "BONJOUR_SDK_HOME=$(cygpath -w "$SHIM")" >> "$GITHUB_ENV"
```

### 注意点

- `cygpath -w` で MSYS2 パスを Windows パス形式に変換してから `BONJOUR_SDK_HOME` に設定する
  （cmake は `$ENV{BONJOUR_SDK_HOME}` を Windows パスとして扱うため）
- `.dll.a` を `.lib` にリネームしても MinGW ld.exe はリンクできる
- `libdns_sd.dll` 自体は `deploy_windows.sh` の `ldd` 収集ステップで自動的に同梱される

---

## deploy_windows.sh の詳細と CI での注意点

### ファイルパスのハードコーディング

スクリプト先頭の変数:

```bash
MINGW_BIN="/c/msys64/mingw64/bin"          # ← CI も同じパス（msys2/setup-msys2@v2 が C:\msys64 にインストール）
GST_PLUGIN_SRC="/c/msys64/mingw64/lib/gstreamer-1.0"   # ← CI も同じ
GST_LIBEXEC_SRC="/c/msys64/mingw64/libexec/gstreamer-1.0"  # ← CI も同じ
BUILD_DIR="${BUILD_DIR:-/f/git/UxPlay/build}"  # ← CI では BUILD_DIR 環境変数で上書き必須
```

**CI ワークフローでの BUILD_DIR 設定方法:**

```bash
# shell: msys2 {0} ステップ内で
export BUILD_DIR="$(cygpath -u "$GITHUB_WORKSPACE")/build"
bash deploy_windows.sh
```

### GIO TLS モジュールと CA 証明書（Step 3.5）

スクリプトは以下のパスからコピーする:

```bash
# libgiognutls.dll
cp "/c/msys64/mingw64/lib/gio/modules/libgiognutls.dll" "$BUILD_DIR/gio/modules/"

# ca-bundle.crt  ← これが問題になりやすい
cp "/c/msys64/usr/ssl/certs/ca-bundle.crt" "$BUILD_DIR/"
```

`/c/msys64/usr/ssl/certs/ca-bundle.crt` は MSYS2 の `ca-certificates` パッケージが提供する。
CI で `base-devel` だけをインストールした場合、このファイルが存在しない可能性がある。

**対策**: `ca-certificates` を pacman でインストールするか、
代替として `/mingw64/etc/ssl/certs/ca-bundle.crt` が存在するか確認する。

### ldd によるDLL収集

```bash
ldd "$BUILD_DIR/uxplay.exe" | grep "mingw64" | awk '{print $3}'
```

- `grep "mingw64"` は `C:\msys64\mingw64\bin\` にある DLL のみを対象とする
- `/c/windows/` や `/c/msys64/usr/bin/` の DLL はスキップされる（Windows システム DLL は同梱不要）
- CI 環境でも `msys2/setup-msys2@v2` が `C:\msys64` にインストールするため、同じ挙動になるはず

### EXTRA_BINS（ldd が拾わない追加 DLL）

以下は明示的にコピーが必要（GStreamer の dlopen ロードのため ldd に出てこない）:

```bash
libgstnet-1.0-0.dll
libgstisoff-1.0-0.dll
libgstmpegts-1.0-0.dll
libgstcodecparsers-1.0-0.dll
libgstgl-1.0-0.dll        # NVCODEC依存
libgstcuda-1.0-0.dll      # NVCODEC依存
libgstd3d12-1.0-0.dll     # NVCODEC依存
```

これらが存在しない場合、以下のような実行時エラーになる:

```
GStreamer-WARNING: Failed to load plugin 'libgstadaptivedemux2.dll':
  指定されたモジュールが見つかりません。
```

---

## CMake ビルドで気を付けること

### pkg-config の明示指定

MSYS2 環境では cmake が Windows の pkg-config を拾う可能性があるため明示指定が必要:

```bash
cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPKG_CONFIG_EXECUTABLE="/mingw64/bin/pkg-config.exe"
  # または "/c/msys64/mingw64/bin/pkg-config.exe"（どちらも同じ場所）
```

### BONJOUR_SDK_HOME は cmake 実行前に環境変数として設定する

cmake は `-D` フラグでなく `$ENV{BONJOUR_SDK_HOME}` で読み込むため、
cmake 起動前に `export BONJOUR_SDK_HOME=...` または `$GITHUB_ENV` 経由で設定する必要がある。

### -march=native について

`CMakeLists.txt` はデフォルトで `-march=native` を付ける。
CI ランナーの CPU は不特定だが、通常は問題なくビルドできる。
互換性が必要な場合は `-DNO_MARCH_NATIVE=ON` を追加する。

---

## uxplay.bat（ランチャー）の重要な環境変数

`deploy_windows.sh` が生成する `uxplay.bat` には以下の設定が含まれる:

```batch
set "GST_PLUGIN_PATH=%HERE%gstreamer-1.0"
set "GST_PLUGIN_SYSTEM_PATH=%HERE%gstreamer-1.0"
set "GST_PLUGIN_SCANNER=%HERE%gstreamer-1.0\libexec\gst-plugin-scanner.exe"
set "GST_PLUGIN_SCANNER_1_0=%HERE%gstreamer-1.0\libexec\gst-plugin-scanner.exe"
set "GST_REGISTRY_PATH=%HERE%gst_registry.bin"
set "GST_REGISTRY_FORK=no"
set "GIO_MODULE_DIR=%HERE%gio\modules"
set "GIO_USE_TLS=gnutls"
set "SSL_CERT_FILE=%HERE%ca-bundle.crt"
set "G_TLS_CA_FILE=%HERE%ca-bundle.crt"
set "GST_DEBUG=*:1"
set "GST_PLUGIN_FEATURE_RANK=hlsdemux:0,nvh264dec:0,nvh265dec:0,wasapi2sink:0,wasapisink:0"
```

**`GST_PLUGIN_FEATURE_RANK` の意味（重要）:**

| エントリ | 理由 |
|---------|------|
| `hlsdemux:0` | 旧 hlsdemux を無効化し hlsdemux2 (adaptivedemux2) を使用 |
| `nvh264dec:0,nvh265dec:0` | この GPU では NVCODEC の D3D11 出力が失敗するため無効化 |
| `wasapi2sink:0,wasapisink:0` | RAOP 音声が wasapi2 を占有するため HLS は directsoundsink を使用 |

`uxplay.bat` は `deploy_windows.sh` が Step 4 で自動生成するため、
現在の `deploy_windows.sh` のテンプレートには上記 `GST_PLUGIN_FEATURE_RANK` が含まれていない。
手動で `build/uxplay.bat` に追記するか、スクリプトを修正する必要がある（未対応）。

---

## 現在の windows-build.yml

```yaml
name: Windows Build

on:
  workflow_dispatch:
  push:
    branches:
      - windows-resize

jobs:
  build:
    runs-on: windows-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup MSYS2
        uses: msys2/setup-msys2@v2
        with:
          msystem: MINGW64
          update: true
          cache: true
          install: >-
            base-devel
            mingw-w64-x86_64-toolchain
            mingw-w64-x86_64-cmake
            mingw-w64-x86_64-ninja
            mingw-w64-x86_64-gstreamer
            mingw-w64-x86_64-gst-plugins-base
            mingw-w64-x86_64-gst-plugins-good
            mingw-w64-x86_64-gst-plugins-bad
            mingw-w64-x86_64-gst-plugins-ugly
            mingw-w64-x86_64-gst-libav
            mingw-w64-x86_64-libplist
            mingw-w64-x86_64-openssl
            mingw-w64-x86_64-mdnsresponder

      - name: Create Bonjour SDK shim from mdnsresponder
        shell: msys2 {0}
        run: |
          SHIM="$(cygpath -u "$GITHUB_WORKSPACE")/ci-bonjour-sdk"
          mkdir -p "$SHIM/Lib/x64" "$SHIM/Include"
          cp /mingw64/include/dns_sd.h "$SHIM/Include/"
          cp /mingw64/lib/libdns_sd.dll.a "$SHIM/Lib/x64/dnssd.lib"
          echo "BONJOUR_SDK_HOME=$(cygpath -w "$SHIM")" >> "$GITHUB_ENV"

      - name: Build
        shell: msys2 {0}
        run: |
          cmake -B build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DPKG_CONFIG_EXECUTABLE="/mingw64/bin/pkg-config.exe"
          cmake --build build --parallel

      - name: Deploy (bundle DLLs and plugins)
        shell: msys2 {0}
        run: |
          export BUILD_DIR="$(cygpath -u "$GITHUB_WORKSPACE")/build"
          bash deploy_windows.sh

      - name: Create ZIP archive
        shell: pwsh
        run: |
          Compress-Archive -Path build\* -DestinationPath uxplay-windows.zip

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: uxplay-windows-${{ github.ref_name }}-${{ github.sha }}
          path: uxplay-windows.zip
          retention-days: 30
```

---

## よくあるエラーと対処

### cmake: `Could not find dnssd.lib`

```
CMake Error: Could not find: C:/Program Files/Bonjour SDK/Lib/x64/dnssd.lib
```

→ `BONJOUR_SDK_HOME` が cmake 実行前に設定されていない。
  シム作成ステップで `$GITHUB_ENV` に書き込んだ値が次ステップで有効になっているか確認。
  Windows パス形式（バックスラッシュ）である必要がある。

### cmake: pkg-config が見つからない

```
CMake Error: Could not find PkgConfig
```

→ `PKG_CONFIG_EXECUTABLE` の指定か、`/mingw64/bin/pkg-config.exe` の存在を確認。
  または `find_package(PkgConfig REQUIRED)` の前に PATH に `/mingw64/bin` が含まれているか確認。

### deploy_windows.sh: `cp: ca-bundle.crt: No such file`

```
cp: /c/msys64/usr/ssl/certs/ca-bundle.crt: No such file or directory
```

→ MSYS2 の `ca-certificates` パッケージが未インストール。
  pacman の `install:` リストに `ca-certificates` を追加する。
  または代替パス `/mingw64/etc/ssl/certs/ca-bundle.crt` を使用する。

### deploy_windows.sh: `gst-plugin-scanner.exe: No such file`

```
cp: /c/msys64/mingw64/libexec/gstreamer-1.0/gst-plugin-scanner.exe: No such file
```

→ GStreamer のインストールが不完全。`mingw-w64-x86_64-gstreamer` に含まれるはずだが、
  `mingw-w64-x86_64-gst-devtools` の追加が必要な場合もある。

### cmake: libplist not found

```
Could NOT find PkgConfig module: libplist-2.0
```

→ `mingw-w64-x86_64-libplist` が pacman でインストールされていることを確認。

### shell: msys2 {0} での環境変数 BONJOUR_SDK_HOME が空

→ `$GITHUB_ENV` へ書き込んだ環境変数は**次のステップから**有効になる。
  Bonjour SDK シム作成と cmake ビルドは別ステップに分かれていることを確認。

---

## CI での動作確認方法

1. `.github/workflows/windows-build.yml` を修正してプッシュ
2. GitHub の **Actions** タブでビルドログを確認
3. 各ステップのログで以下を確認:
   - `Create Bonjour SDK shim`: `dns_sd.h` と `dnssd.lib` のコピー成功
   - `Build`: `cmake --build` が `[100%] Linking CXX executable uxplay.exe` で完了
   - `Deploy`: `=== デプロイ完了 ===` が出力される
4. アーティファクト `uxplay-windows-*.zip` をダウンロード・展開して `uxplay.bat` で動作確認
