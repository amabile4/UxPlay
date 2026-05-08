#!/bin/bash
# deploy_windows.sh
# MSYS2 MINGW64から実行: UxPlayのWindowsスタンドアロン配布パッケージを build/ に作成する

set -e

MINGW_PREFIX="${MINGW_PREFIX:-/mingw64}"
MINGW_BIN="$MINGW_PREFIX/bin"
GST_PLUGIN_SRC="$MINGW_PREFIX/lib/gstreamer-1.0"
GIO_MODULE_SRC="$MINGW_PREFIX/lib/gio/modules"
CA_BUNDLE_SRC="/usr/ssl/certs/ca-bundle.crt"
BUILD_DIR="${BUILD_DIR:-/f/git/UxPlay/build}"

# gst-plugin-scanner.exe: GStreamer 1.24+ では廃止・同梱されないケースがある
# 存在すればコピー、なければスキップ（GST_REGISTRY_FORK=no で不要）
GST_SCANNER_EXE=""
for _candidate in \
    "$MINGW_PREFIX/libexec/gstreamer-1.0/gst-plugin-scanner.exe" \
    "$MINGW_BIN/gst-plugin-scanner.exe"; do
    if [ -f "$_candidate" ]; then
        GST_SCANNER_EXE="$_candidate"
        break
    fi
done
if [ -z "$GST_SCANNER_EXE" ]; then
    GST_SCANNER_EXE=$(find "$MINGW_PREFIX" -name "gst-plugin-scanner.exe" 2>/dev/null | head -1)
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
        src="$MINGW_BIN/$bin"
        if [ ! -f "$src" ]; then
            src=$(find "$MINGW_PREFIX" -name "$bin" 2>/dev/null | head -1)
        fi
        if [ -n "$src" ] && [ -f "$src" ]; then
            echo "  extra: $bin"
            cp "$src" "$BUILD_DIR/"
        else
            echo "  WARNING: extra runtime $bin が見つかりません（スキップ）"
        fi
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
cp "$GIO_MODULE_SRC/libgiognutls.dll" "$BUILD_DIR/gio/modules/"
echo "  copied: libgiognutls.dll"
cp "$CA_BUNDLE_SRC" "$BUILD_DIR/"
echo "  copied: ca-bundle.crt"
cp "tools/windows/uxplay_gst_rank.ps1" "$BUILD_DIR/"
echo "  copied: uxplay_gst_rank.ps1"
cp "tools/windows/check_bonjour_safety.ps1" "$BUILD_DIR/"
echo "  copied: check_bonjour_safety.ps1"

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
    printf 'set "UXPLAY_LAUNCH_ARGS=%%*"\r\n'
    printf 'set "_UXPLAY_TMP=%%TEMP%%\\_uxplay_env_%%RANDOM%%.bat"\r\n'
    printf 'powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%%HERE%%uxplay_gst_rank.ps1" -BundleRoot "%%HERE%%" | findstr /B /C:"set " > "%%_UXPLAY_TMP%%"\r\n'
    printf 'call "%%_UXPLAY_TMP%%"\r\n'
    printf 'del "%%_UXPLAY_TMP%%" 2>nul\r\n'
    printf 'set "_UXPLAY_TMP="\r\n'
    printf 'set "UXPLAY_LAUNCH_ARGS="\r\n'
    printf 'echo %%* | findstr /C:"-vs " >nul 2>&1\r\n'
    printf 'if errorlevel 1 (\r\n'
    printf '    "%%HERE%%uxplay.exe" -vs "d3d11videosink fullscreen-toggle-mode=alt-enter" %%*\r\n'
    printf ') else (\r\n'
    printf '    "%%HERE%%uxplay.exe" %%*\r\n'
    printf ')\r\n'
    printf 'if /I not "%%UXPLAY_NO_PAUSE%%"=="1" pause\r\n'
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
