# HLS モード トラブルシューティング

`-hls` オプションで起動した場合の、デコーダー関連の不具合調査ガイド。

---

## コンソールの出力形式

正常再生時：
```
[HLS] 1920x1080  Video: H.264  Audio: AAC  Decoder: avdec_h264  Sink: d3d11videosink
```

エラー発生時：
```
[HLS] Error in nvh264dec-0: Internal data stream error
[HLS] State: Codec=H.264  Decoder=nvh264dec  Sink=d3d11videosink  Resolution=unknown
```

---

## GStreamer が自動選択するデコーダー一覧

| 要素名          | 種別                         | 対象コーデック      |
|-----------------|------------------------------|---------------------|
| `avdec_h264`    | ソフトウェア (FFmpeg)        | H.264               |
| `avdec_h265`    | ソフトウェア (FFmpeg)        | H.265 / HEVC        |
| `nvh264dec`     | ハードウェア (NVIDIA GPU)    | H.264               |
| `nvh265dec`     | ハードウェア (NVIDIA GPU)    | H.265               |
| `d3d11h264dec`  | ハードウェア (Direct3D 11)   | H.264               |
| `d3d11h265dec`  | ハードウェア (Direct3D 11)   | H.265               |
| `msdkh264dec`   | ハードウェア (Intel QSV)     | H.264               |
| `msdkh265dec`   | ハードウェア (Intel QSV)     | H.265               |
| `vp9dec`        | ソフトウェア (libvpx)        | VP9                 |
| `av1dec`        | ソフトウェア                 | AV1                 |

GStreamer は **ランク（優先度）の高いデコーダーを優先的に選択**する。
ハードウェアデコーダーはランクが高く設定されているため、GPU ドライバーの問題があると
エラーになる。

---

## デコーダーを無効化する方法

`uxplay.bat` の `GST_PLUGIN_FEATURE_RANK` にデコーダー名と `:0` を追加する。

```bat
set "GST_PLUGIN_FEATURE_RANK=hlsdemux:0,nvh264dec:0,nvh265dec:0,wasapi2sink:0,wasapisink:0"
```

### 例: NVIDIA デコーダーを無効化する

`nvh264dec:0,nvh265dec:0` はすでにデフォルトで設定済み。

### 例: D3D11 ハードウェアデコーダーを無効化する

```bat
set "GST_PLUGIN_FEATURE_RANK=hlsdemux:0,nvh264dec:0,nvh265dec:0,d3d11h264dec:0,d3d11h265dec:0,wasapi2sink:0,wasapisink:0"
```

### 例: VP9 / AV1 を無効化して H.264 のみにする（YouTube 広告の問題対策）

```bat
set "GST_PLUGIN_FEATURE_RANK=hlsdemux:0,nvh264dec:0,nvh265dec:0,vp9dec:0,av1dec:0,wasapi2sink:0,wasapisink:0"
```

YouTube の一部広告ストリームは VP9/AV1 フォーマット (itag 231/616 等) で配信される場合があり、
デコーダーが対応していない環境では `Internal data stream error` になる。

---

## ランクの数値の意味

| 値    | 意味                          |
|-------|-------------------------------|
| `0`   | 無効化（選択されない）        |
| `1`   | 最低優先度（他に選択肢がなければ使用）|
| `256` | 通常（`PRIMARY`）             |
| `512` | 高優先度（`MARGINAL`）        |

---

## よくあるエラーと原因

### `Internal data stream error`

**原因候補:**
- ハードウェアデコーダーがそのストリームに対応していない
  （例: 4K ストリームをハードウェアの最大解像度超えで処理しようとした）
- ストリームのコーデックがデコーダーに対応していない
  （例: VP9 ストリームに H.264 デコーダーが割り当てられた）
- GPU ドライバーの不具合

**対処:** コンソールの `Decoder=` 欄を確認し、該当デコーダーを `:0` で無効化して再試行。

### `not-negotiated` / `caps negotiation failed`

**原因候補:**
- videosink がデコーダーの出力フォーマットに対応していない
- コンバーター要素が不足している

**対処:** `-vs autovideosink` に変更するか、`videoconvert` を挟む。

---

## バグ報告時に含める情報

エラー報告の際には、コンソールの以下の行をそのまま貼り付けてください：

```
[HLS] Error in <element>: <message>
[HLS] State: Codec=<codec>  Decoder=<decoder>  Sink=<sink>  Resolution=<resolution>
```

加えて、`uxplay.bat` の `GST_PLUGIN_FEATURE_RANK` の現在の値も含めると調査が早くなります。
