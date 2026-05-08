"""
mock_hls_server.py — CI/CD 環境用のモック HLS サーバー

UxPlay が GStreamer 経由でアクセスする HLS プレイリストとセグメントを
localhost で提供する。実際の YouTube ストリームの代わりに使用する。
"""

import argparse
import os
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


# --- 最小限の MPEG-TS セグメント生成 ---

def _make_pat():
    """Program Association Table (PAT) パケット"""
    pat_data = bytes([
        0x00,                   # table_id: PAT
        0xb0, 0x0d,             # section_syntax_indicator, section_length=13
        0x00, 0x01,             # transport_stream_id
        0xc1, 0x00, 0x00,       # version, section_number, last_section_number
        0x00, 0x01,             # program_number
        0xe1, 0x00,             # PMT PID = 0x100
    ])
    crc = _crc32(pat_data)
    pat_data += struct.pack(">I", crc)
    header = bytes([0x47, 0x40, 0x00, 0x10, 0x00])  # sync, PID=0, payload_unit
    payload = pat_data.ljust(184, b'\xff')
    return header[:4] + payload[:184]


def _make_pmt():
    """Program Map Table (PMT) パケット — H.264 video only"""
    pmt_data = bytes([
        0x02,                   # table_id: PMT
        0xb0, 0x12,             # section_length=18
        0x00, 0x01,             # program_number
        0xc1, 0x00, 0x00,       # version, section_number, last_section_number
        0xe1, 0x01,             # PCR PID=0x101
        0xf0, 0x00,             # program_info_length=0
        0x1b,                   # stream_type: H.264
        0xe1, 0x01,             # elementary PID=0x101
        0xf0, 0x00,             # ES_info_length=0
    ])
    crc = _crc32(pmt_data)
    pmt_data += struct.pack(">I", crc)
    header = bytes([0x47, 0x41, 0x00, 0x10, 0x00])  # PID=0x100
    payload = pmt_data.ljust(184, b'\xff')
    return header[:4] + payload[:184]


def _crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if (crc & 0x80000000) else (crc << 1)
            crc &= 0xFFFFFFFF
    return crc


def _make_null_ts_packet():
    """NULL パケット (PID=0x1FFF)"""
    return bytes([0x47, 0x1F, 0xFF, 0x10]) + bytes(184)


# 単一セグメント: PAT + PMT + NULL × 6 = 8 × 188 bytes = 1504 bytes
SEGMENT_DATA = _make_pat() + _make_pmt() + (_make_null_ts_packet() * 6)

MASTER_PLAYLIST = """\
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS="avc1.42e01e,mp4a.40.2",RESOLUTION=1280x720
media.m3u8
"""

MEDIA_PLAYLIST = """\
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.0,
segment0.ts
#EXT-X-ENDLIST
"""


class MockHLSHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # 標準ログを抑制

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/master.m3u8", "/"):
            self._send(200, "application/vnd.apple.mpegurl", MASTER_PLAYLIST.encode())
        elif path == "/media.m3u8":
            self._send(200, "application/vnd.apple.mpegurl", MEDIA_PLAYLIST.encode())
        elif path == "/segment0.ts":
            self._send(200, "video/mp2t", SEGMENT_DATA)
        else:
            self._send(404, "text/plain", b"Not Found")

    def _send(self, code: int, content_type: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start(port: int) -> HTTPServer:
    server = HTTPServer(("127.0.0.1", port), MockHLSHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock HLS server for UxPlay testing")
    parser.add_argument("--port", type=int, default=8765, help="HTTP server port")
    args = parser.parse_args()

    server = start(args.port)
    print(f"Mock HLS server running at http://127.0.0.1:{args.port}/master.m3u8")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        server.shutdown()
