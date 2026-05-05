# UxPlay Windows ビルド・配布メモ

## 概要

MSYS2 MINGW64 環境で UxPlay 1.73.6 を Windows 向けにビルドし、
スタンドアロン配布パッケージ（DLL同梱）を作成する手順と、
調査で判明した問題・対処をまとめたドキュメント。

---

## ビルド環境

| 項目 | 値 |
|------|----|
| ツールチェーン | MSYS2 MINGW64 (`C:\msys64\mingw64\bin`) |
| GCC | 16.1.0 |
| CMake | 4.3.2 |
| Ninja | 1.13.2 |
| GStreamer | 1.28.2 |
| libplist | 2.7.0 |
| OpenSSL | 3.6.2 |
| Bonjour SDK | `C:\Program Files\Bonjour SDK` |

---

## ビルド手順

MSYS2 MINGW64 ターミナルから実行:

```bash
export PATH="/c/msys64/mingw64/bin:$PATH"
export PKG_CONFIG_EXECUTABLE="/c/msys64/mingw64/bin/pkg-config.exe"
export BONJOUR_SDK_HOME="C:/Program Files/Bonjour SDK"

cd /f/git/UxPlay
rm -rf build

cmake -B build -S . \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPKG_CONFIG_EXECUTABLE="/c/msys64/mingw64/bin/pkg-config.exe"

cmake --build build --config Release --parallel
```

生成物: `build/uxplay.exe` (約1MB)

---

## DLL同梱デプロイ (`deploy_windows.sh`)

スクリプト: [deploy_windows.sh](deploy_windows.sh)

MSYS2 MINGW64 から実行:

```bash
bash /f/git/UxPlay/deploy_windows.sh
```

### スクリプトが行うこと

| Step | 内容 |
|------|------|
| Step 1 | `uxplay.exe` の直接DLL依存 (15個) を `build/` にコピー |
| Step 2 | GStreamerプラグイン (22個) を `build/gstreamer-1.0/` にコピー |
| Step 3 | プラグインDLLの推移的依存 (~107個) を `build/` に収集 |
| Step 3.5 | GIO TLSモジュールとCA証明書をコピー |
| Step 4 | `build/uxplay.bat` ランチャーを生成 |

### Step 2 で同梱するGStreamerプラグイン

| DLL | 役割 |
|-----|------|
| `libgstapp.dll` | appsrc |
| `libgstaudioconvert.dll` | audioconvert |
| `libgstaudioparsers.dll` | aacparse |
| `libgstaudioresample.dll` | audioresample |
| `libgstautodetect.dll` | autovideosink / autoaudiosink |
| `libgstcoreelements.dll` | queue 等 |
| `libgstd3d11.dll` | Direct3D11映像出力・HWデコード |
| `libgstdirectsound.dll` | DirectSound音声出力 |
| `libgstimagefreeze.dll` | imagefreeze |
| `libgstisomp4.dll` | mp4 demux/mux |
| `libgstjpeg.dll` | jpegdec |
| `libgstlibav.dll` | avdec_h264 / avdec_h265 / avdec_aac / avdec_alac |
| `libgstopus.dll` | Opus |
| `libgstpango.dll` | textoverlay |
| `libgstplayback.dll` | playbin / playbin3 / decodebin |
| `libgstvideoconvertscale.dll` | videoconvert / videoscale |
| `libgstvideofilter.dll` | videoflip |
| `libgstvideoparsersbad.dll` | h264parse / h265parse |
| `libgstwasapi.dll` | WASAPI音声出力 |
| `libgstwasapi2.dll` | WASAPI2音声出力 |
| `libgstvolume.dll` | volume |
| `libgstlevel.dll` | level |
| `libgstsoup.dll` | souphttpsrc (HLS用HTTP) |
| `libgsthls.dll` | hlsdemux (HLS再生) |
| `libgstadaptivedemux2.dll` | adaptivedemux2 (HLS/DASH) |
| `libgsttypefindfunctions.dll` | メディアタイプ自動検出 |
| `libgstdash.dll` | DASHストリーミング |
| `libgstmpegtsdemux.dll` | MPEG-TSデマックス (YouTube HLS .tsセグメント) |
| `libgstvpx.dll` | VP9/VP8デコード (YouTube 4K/HDR) |

### Step 3.5 で配置するファイル

| 配置先 | ソース | 目的 |
|--------|--------|------|
| `build/gio/modules/libgiognutls.dll` | `C:\msys64\mingw64\lib\gio\modules\` | HTTPS/TLS通信 |
| `build/ca-bundle.crt` | `C:\msys64\usr\ssl\certs\` | HTTPS証明書検証 |

---

## ランチャー (`uxplay.bat`)

```batch
@echo off
set "HERE=%~dp0"
set "GST_PLUGIN_PATH=%HERE%gstreamer-1.0"
set "GST_REGISTRY_PATH=%HERE%gst_registry.bin"
set "GST_DEBUG=*:1"
set "GST_PLUGIN_FEATURE_RANK=hlsdemux2:0"
set "GIO_MODULE_DIR=%HERE%gio\modules"
set "SSL_CERT_FILE=%HERE%ca-bundle.crt"
start "" "%HERE%uxplay.exe" %*
```

- `uxplay.exe` を直接ダブルクリックしても起動しない（DLL検索パスの問題）
- `uxplay.bat` またはショートカット (`UxPlay.lnk`) から起動する
- コマンドライン引数は `%*` により `uxplay.exe` にそのまま渡される

---

## 動作確認済みオプション

### 基本オプション

| オプション | 内容 |
|-----------|------|
| `-n <name>` | AirPlay表示名の変更 |
| `-s 1920x1080` | 解像度指定 |
| `-p <port>` | ポート番号指定 |
| `-nohold` | 新接続時に既存切断 |
| `-avdec` | ソフトウェアデコード強制 |
| `-fs` | フルスクリーン |

### Windows向け映像出力

| オプション | 内容 |
|-----------|------|
| `-vs d3d11videosink` | Direct3D11 (推奨) |
| `-vs d3d12videosink` | Direct3D12 |
| `-vs 0` | 映像なし（音声のみ） |

### Windows向け音声出力

| オプション | 内容 |
|-----------|------|
| `-as wasapi2sink` | WASAPI2 (推奨) |
| `-as wasapisink` | WASAPI |
| `-as directsoundsink` | DirectSound |

### コーデック関連

| オプション | 内容 |
|-----------|------|
| `-h265` | H.265/HEVC (4K) 対応 |
| `-hls` | YouTube等 HLSストリーミング |
| `-hls 2` / `-hls 3` | playbin バージョン指定 |
| `-mp4` | mp4録画 |
| `-vd d3d11h264dec` | DXVA H.264ハードウェアデコード |
| `-vd d3d11h265dec` | DXVA H.265ハードウェアデコード |

### Windows推奨起動例

```
uxplay.bat -vs d3d11videosink -as wasapi2sink -avdec
```

---

## トラブルシューティング履歴

### 問題1: ダブルクリックで起動しない

**症状:** `uxplay.exe` を直接起動すると終了コード `0xC0000135` (DLL not found)

**原因:** MSYS2/MinGW64 の DLL が Windows システムパスに存在しない

**対処:** `deploy_windows.sh` で DLL を `build/` に同梱、`uxplay.bat` 経由で起動

---

### 問題2: `libgstadaptivedemux2.dll` / `libgstdash.dll` 読み込み失敗

**症状:**
```
GStreamer-WARNING: Failed to load plugin 'libgstadaptivedemux2.dll': 指定されたモジュールが見つかりません。
```

**原因:** `ldd` の推移的収集に乗らない DLL が不足

**対処:** `deploy_windows.sh` の `EXTRA_BINS` に明示的に追加

```bash
EXTRA_BINS=(
    libgstnet-1.0-0.dll
    libgstisoff-1.0-0.dll
)
```

---

### 問題3: HLS再生で `adaptivedemux2` エラー

**症状:**
```
ERROR adaptivedemux2: Download error: Couldn't download fragments, too many failures
```

**原因:** `hlsdemux2` (rank 257) が `hlsdemux` (rank 256) より優先選択され、
`adaptivedemux2` 実装で localhost 接続が失敗

**対処:** `uxplay.bat` に以下を追加:

```batch
set "GST_PLUGIN_FEATURE_RANK=hlsdemux2:0"
```

これにより旧実装 `hlsdemux` が使われる。

---

### 問題4: HLS再生で `souphttpsrc` HTTPS接続エラー

**症状:**
```
GstSoupHTTPSrc:souphttpsrc2: streaming stopped, reason error (-5)
Download error: Internal data stream error.
```

**原因と構造:**

UxPlayのHLS実装:
1. iPhone が YouTube HLS プレイリストを FCUP で UxPlay に送信
2. `adjust_master_playlist()` がプレイリスト内のURLを `localhost` に書き換え
3. `adjust_yt_condensed_playlist()` がメディアプレイリストを展開するが、
   セグメント URL の `BASE-URI` は **YouTube CDN (HTTPS)** のまま
4. GStreamer の `souphttpsrc` が YouTube CDN に直接 HTTPS で接続しようとする
5. GIO TLSモジュール未配置により接続失敗

**対処:**

```bash
# GIO TLSモジュール配置
mkdir -p build/gio/modules
cp /c/msys64/mingw64/lib/gio/modules/libgiognutls.dll build/gio/modules/

# CA証明書配置
cp /c/msys64/usr/ssl/certs/ca-bundle.crt build/
```

`uxplay.bat` に追加:

```batch
set "GIO_MODULE_DIR=%HERE%gio\modules"
set "SSL_CERT_FILE=%HERE%ca-bundle.crt"
```

---

## `build/` ディレクトリ構成

```
build/
  uxplay.exe          (約1MB, メイン実行ファイル)
  uxplay.bat          (ランチャー ← これを起動する)
  UxPlay.lnk          (ショートカット)
  ca-bundle.crt       (HTTPS証明書検証用)
  *.dll               (約122個, 全依存DLL)
  gstreamer-1.0/      (約27個, GStreamerプラグイン)
  gio/
    modules/
      libgiognutls.dll  (TLSモジュール)
合計: 約174MB
```

---

## デバッグ用: ログレベル変更

`uxplay.bat` の `GST_DEBUG=*:1` を変更することで詳細ログを取得できる。

```batch
rem HTTPS接続エラーの詳細
set "GST_DEBUG=souphttpsrc:5,adaptivedemux:5,hlsdemux:4"

rem GIOモジュール読み込みの確認
set "GST_DEBUG=glib-networking:5"

rem GStreamer全体の詳細ログ
set "GST_DEBUG=*:4"
```
