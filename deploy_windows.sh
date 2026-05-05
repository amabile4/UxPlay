#!/bin/bash
# deploy_windows.sh
# MSYS2 MINGW64から実行: UxPlayのWindowsスタンドアロン配布パッケージを build/ に作成する

set -e

MINGW_BIN="/c/msys64/mingw64/bin"
GST_PLUGIN_SRC="/c/msys64/mingw64/lib/gstreamer-1.0"
BUILD_DIR="${BUILD_DIR:-/f/git/UxPlay/build}"

# gst-plugin-scanner.exe: GStreamer 1.24+ では廃止・同梱されないケースがある
# 存在すればコピー、なければスキップ（GST_REGISTRY_FORK=no で不要）
GST_SCANNER_EXE=""
for _candidate in \
    "/c/msys64/mingw64/libexec/gstreamer-1.0/gst-plugin-scanner.exe" \
    "/c/msys64/mingw64/bin/gst-plugin-scanner.exe"; do
    if [ -f "$_candidate" ]; then
        GST_SCANNER_EXE="$_candidate"
        break
    fi
done
if [ -z "$GST_SCANNER_EXE" ]; then
    GST_SCANNER_EXE=$(find /c/msys64 -name "gst-plugin-scanner.exe" 2>/dev/null | head -1)
fi
if [ -n "$GST_SCANNER_EXE" ]; then
    GST_LIBEXEC_SRC="$(dirname "$GST_SCANNER_EXE")"
    echo "  scanner found at: $GST_SCANNER_EXE"
else
    GST_LIBEXEC_SRC=""
    echo "  gst-plugin-scanner.exe not found (GStreamer 1.24+ build, skipping)"
fi

echo "=== Step 1: uxplay.exe の直接DLL依存を収集 ==="
ldd "$BUILD_DIR/uxplay.exe" | grep "mingw64" | awk '{print $3}' | while read src; do
    dst="$BUILD_DIR/$(basename "$src")"
    if [ ! -f "$dst" ]; then
        echo "  copy: $(basename "$src")"
        cp "$src" "$BUILD_DIR/"
    fi
done

echo ""
echo "=== Step 2: GStreamerプラグインをコピー ==="
mkdir -p "$BUILD_DIR/gstreamer-1.0"
mkdir -p "$BUILD_DIR/gstreamer-1.0/libexec"

# プラグインスキャナー（存在する場合のみコピー）
if [ -n "$GST_LIBEXEC_SRC" ] && [ -f "$GST_LIBEXEC_SRC/gst-plugin-scanner.exe" ]; then
    cp "$GST_LIBEXEC_SRC/gst-plugin-scanner.exe" "$BUILD_DIR/gstreamer-1.0/libexec/"
    echo "  scanner: gst-plugin-scanner.exe"
    HAS_SCANNER=1
else
    HAS_SCANNER=0
    echo "  scanner: not present, skipping"
fi

PLUGINS=(
    libgstapp.dll
    libgstaudioconvert.dll
    libgstaudioparsers.dll
    libgstaudioresample.dll
    libgstautodetect.dll
    libgstcoreelements.dll
    libgstd3d11.dll
    libgstdeinterlace.dll
    libgstdirectsound.dll
    libgstimagefreeze.dll
    libgstisomp4.dll
    libgstjpeg.dll
    libgstlibav.dll
    libgstopus.dll
    libgstpango.dll
    libgstplayback.dll
    libgstvideoconvertscale.dll
    libgstvideofilter.dll
    libgstvideoparsersbad.dll
    libgstwasapi.dll
    libgstwasapi2.dll
    libgstvolume.dll
    libgstlevel.dll
    libgstid3demux.dll
    # HLS / アダプティブストリーミング
    libgstsoup.dll
    libgsthls.dll
    libgstadaptivedemux2.dll
    libgsttypefindfunctions.dll
    libgstdash.dll
    # YouTube HLS セグメント (MPEG-TS コンテナ)
    libgstmpegtsdemux.dll
    # VP9 デコード
    libgstvpx.dll
    # AV1 デコード
    libgstaom.dll
    # Matroska/WebM コンテナ
    libgstmatroska.dll
    # Windows Media Foundation デコーダー (H.264/H.265/AAC ハードウェア)
    libgstmediafoundation.dll
    # NVIDIA NVDEC ハードウェアデコード
    libgstnvcodec.dll
)

# lddの推移的収集に乗らないランタイム依存DLL
EXTRA_BINS=(
    libgstnet-1.0-0.dll
    libgstisoff-1.0-0.dll
    libgstmpegts-1.0-0.dll
    libgstcodecparsers-1.0-0.dll
    # NVCODEC依存
    libgstgl-1.0-0.dll
    libgstcuda-1.0-0.dll
    libgstd3d12-1.0-0.dll
)

for bin in "${EXTRA_BINS[@]}"; do
    dst="$BUILD_DIR/$bin"
    if [ ! -f "$dst" ]; then
        echo "  extra: $bin"
        cp "$MINGW_BIN/$bin" "$BUILD_DIR/"
    fi
done

for plugin in "${PLUGINS[@]}"; do
    if [ -f "$GST_PLUGIN_SRC/$plugin" ]; then
        echo "  plugin: $plugin"
        cp "$GST_PLUGIN_SRC/$plugin" "$BUILD_DIR/gstreamer-1.0/"
    else
        echo "  WARNING: $plugin が見つかりません（スキップ）"
    fi
done

echo ""
echo "=== Step 3: プラグインDLLの推移的依存を収集 ==="
for plugin in "$BUILD_DIR/gstreamer-1.0/"*.dll; do
    ldd "$plugin" 2>/dev/null | grep "mingw64" | awk '{print $3}' | while read src; do
        dst="$BUILD_DIR/$(basename "$src")"
        if [ ! -f "$dst" ]; then
            echo "  transitive: $(basename "$src")"
            cp "$src" "$BUILD_DIR/"
        fi
    done
done

echo ""
echo "=== Step 3.5: GIO TLSモジュールとCA証明書をコピー ==="
mkdir -p "$BUILD_DIR/gio/modules"
cp "/c/msys64/mingw64/lib/gio/modules/libgiognutls.dll" "$BUILD_DIR/gio/modules/"
echo "  copied: libgiognutls.dll"
cp "/c/msys64/usr/ssl/certs/ca-bundle.crt" "$BUILD_DIR/"
echo "  copied: ca-bundle.crt"

echo ""
echo "=== Step 4: ランチャーバッチファイルを作成 ==="
{
    printf '@echo off\r\n'
    printf 'setlocal\r\n'
    printf 'set "HERE=%%~dp0"\r\n'
    printf 'set "PATH=%%HERE%%;%%HERE%%gstreamer-1.0\\libexec;C:\\Windows\\System32\\downlevel;%%PATH%%"\r\n'
    printf 'set "GST_PLUGIN_PATH=%%HERE%%gstreamer-1.0"\r\n'
    printf 'set "GST_PLUGIN_SYSTEM_PATH=%%HERE%%gstreamer-1.0"\r\n'
    if [ "$HAS_SCANNER" -eq 1 ]; then
        printf 'set "GST_PLUGIN_SCANNER=%%HERE%%gstreamer-1.0\\libexec\\gst-plugin-scanner.exe"\r\n'
        printf 'set "GST_PLUGIN_SCANNER_1_0=%%HERE%%gstreamer-1.0\\libexec\\gst-plugin-scanner.exe"\r\n'
    fi
    printf 'set "GST_REGISTRY_PATH=%%HERE%%gst_registry.bin"\r\n'
    printf 'set "GST_REGISTRY_FORK=no"\r\n'
    printf 'set "GIO_MODULE_DIR=%%HERE%%gio\\modules"\r\n'
    printf 'set "GIO_USE_TLS=gnutls"\r\n'
    printf 'set "SSL_CERT_FILE=%%HERE%%ca-bundle.crt"\r\n'
    printf 'set "G_TLS_CA_FILE=%%HERE%%ca-bundle.crt"\r\n'
    printf 'set "GST_DEBUG=*:1"\r\n'
    printf 'set "GST_PLUGIN_FEATURE_RANK=hlsdemux:0,nvh264dec:0,nvh265dec:0,wasapi2sink:0,wasapisink:0"\r\n'
    printf '"%%HERE%%uxplay.exe" %%*\r\n'
    printf 'pause\r\n'
} > "$BUILD_DIR/uxplay.bat"
echo "  作成: $BUILD_DIR/uxplay.bat"

echo ""
echo "=== デプロイ完了 ==="
echo "ダブルクリック起動: build\\uxplay.bat"
echo ""
echo "--- コピーされたDLL一覧 ---"
ls "$BUILD_DIR"/*.dll | wc -l
echo "個"
echo "--- プラグイン一覧 ---"
ls "$BUILD_DIR/gstreamer-1.0/"*.dll | wc -l
echo "個"
