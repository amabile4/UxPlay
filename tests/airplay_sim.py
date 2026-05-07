"""
airplay_sim.py — AirPlay HLS プロトコルシミュレーター

UxPlay の --test-mode 向けに、iOS クライアントが POST /play で
HLS ストリームを開始するシーケンスを再現する。

mDNS 発見をスキップし、ポートを直接指定する。
FairPlay ペアリングには対応しない (UxPlay の --test-mode 時にバイパス前提)。

使用例:
    python tests/airplay_sim.py \
        --host 127.0.0.1 --raop-port 7000 \
        --hls-url http://127.0.0.1:8765/master.m3u8 \
        --test-api-port 9999
"""

import argparse
import socket
import time
import sys
import uuid as _uuid
import plistlib
import requests


# ---------------------------------------------------------------------------
# Low-level RTSP helper
# ---------------------------------------------------------------------------

class RTSPSession:
    def __init__(self, host: str, port: int, timeout: float = 10.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self.cseq = 0
        self.session_id: str | None = None

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def send_request(self, method: str, uri: str, headers: dict, body: bytes = b"") -> tuple[int, dict, bytes]:
        self.cseq += 1
        lines = [f"{method} {uri} RTSP/1.0", f"CSeq: {self.cseq}"]
        for k, v in headers.items():
            lines.append(f"{k}: {v}")
        if body:
            lines.append(f"Content-Length: {len(body)}")
        request = "\r\n".join(lines) + "\r\n\r\n"
        if body:
            request_bytes = request.encode() + body
        else:
            request_bytes = request.encode()

        self.sock.sendall(request_bytes)
        return self._read_response()

    def _read_response(self) -> tuple[int, dict, bytes]:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("Connection closed by server")
            buf += chunk

        header_part, rest = buf.split(b"\r\n\r\n", 1)
        lines = header_part.decode(errors="replace").split("\r\n")
        status_line = lines[0]
        status_code = int(status_line.split(" ")[1])

        headers: dict[str, str] = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()

        content_length = int(headers.get("content-length", 0))
        body = rest
        while len(body) < content_length:
            body += self.sock.recv(4096)

        return status_code, headers, body[:content_length]


# ---------------------------------------------------------------------------
# HTTP helper for AirPlay HTTP channel
# ---------------------------------------------------------------------------

def send_http_request(host: str, port: int, method: str, path: str,
                      headers: dict, body: bytes = b"", timeout: float = 10.0) -> tuple[int, bytes]:
    """シンプルな1リクエスト HTTP クライアント"""
    with socket.create_connection((host, port), timeout=timeout) as s:
        lines = [f"{method} {path} HTTP/1.1", f"Host: {host}:{port}"]
        for k, v in headers.items():
            lines.append(f"{k}: {v}")
        if body:
            lines.append(f"Content-Length: {len(body)}")
        lines.append("Connection: close")
        request = "\r\n".join(lines) + "\r\n\r\n"
        s.sendall(request.encode() + body)

        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk

    header_end = buf.find(b"\r\n\r\n")
    if header_end < 0:
        return 0, buf
    header_part = buf[:header_end].decode(errors="replace")
    status_code = int(header_part.split("\r\n")[0].split(" ")[1])
    return status_code, buf[header_end + 4:]


# ---------------------------------------------------------------------------
# AirPlay HLS simulation
# ---------------------------------------------------------------------------

def simulate_airplay_hls(host: str, raop_port: int, hls_url: str, test_api_port: int) -> bool:
    """
    AirPlay HLS 接続シーケンスを実行する。

    Returns:
        True: シミュレーション成功
        False: 失敗
    """
    rtsp_url = f"rtsp://{host}:{raop_port}/stream"

    print(f"[sim] Connecting to UxPlay at {host}:{raop_port}")
    session = RTSPSession(host, raop_port)
    try:
        session.connect()
    except Exception as e:
        print(f"[sim] ERROR: Cannot connect to UxPlay: {e}")
        return False

    # --- Step 1: OPTIONS ---
    print("[sim] Step 1: OPTIONS")
    code, hdrs, _ = session.send_request("OPTIONS", "*", {
        "User-Agent": "AirPlay/540.31",
        "X-Apple-Device-ID": "aa:bb:cc:dd:ee:ff",
    })
    if code != 200:
        print(f"[sim] WARNING: OPTIONS returned {code} (continuing anyway)")

    # --- Step 2: POST /play via HTTP ---
    # UxPlay の HLS モードでは RTSP ではなく HTTP で /play を受け付ける
    print("[sim] Step 2: POST /play")
    playback_uuid = str(_uuid.uuid4())
    session_id = str(_uuid.uuid4())
    play_body = plistlib.dumps({
        "Content-Location": hls_url,
        "clientProcName": "YouTube",
        "Start-Position-Seconds": 0.0,
        "uuid": playback_uuid,
    }, fmt=plistlib.FMT_BINARY)
    try:
        resp = requests.post(
            f"http://{host}:{raop_port}/play",
            data=play_body,
            headers={
                "Content-Type": "application/x-apple-binary-plist",
                "User-Agent": "AirPlay/540.31",
                "X-Apple-Session-ID": session_id,
            },
            timeout=15,
        )
        if resp.status_code not in (200, 204):
            print(f"[sim] WARNING: POST /play returned {resp.status_code}")
        else:
            print(f"[sim] POST /play → {resp.status_code}")
    except Exception as e:
        print(f"[sim] WARNING: POST /play failed: {e}")

    # --- Step 3: ステータス確認 ---
    print("[sim] Step 3: Waiting for UxPlay to start HLS playback...")
    time.sleep(10)

    # --- Step 4: GET /playback_info ---
    print("[sim] Step 4: GET /playback_info")
    for _ in range(3):
        try:
            code, body = send_http_request(host, raop_port, "GET", "/playback_info", {
                "User-Agent": "AirPlay/540.31",
            }, timeout=5)
            print(f"[sim] GET /playback_info → {code} ({len(body)} bytes)")
        except Exception as e:
            print(f"[sim] WARNING: GET /playback_info failed: {e}")
        time.sleep(1)

    # --- Step 5: test/status 確認 ---
    print(f"[sim] Step 5: GET http://127.0.0.1:{test_api_port}/test/status")
    try:
        resp = requests.get(f"http://127.0.0.1:{test_api_port}/test/status", timeout=5)
        print(f"[sim] test/status → {resp.status_code}: {resp.text}")
    except Exception as e:
        print(f"[sim] test/status failed: {e}")

    # --- Step 6: POST /stop ---
    print("[sim] Step 6: POST /stop")
    try:
        send_http_request(host, raop_port, "POST", "/stop", {"User-Agent": "AirPlay/540.31"}, timeout=5)
    except Exception as e:
        print(f"[sim] WARNING: POST /stop failed: {e}")

    session.close()
    print("[sim] Simulation complete")
    return True


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="AirPlay HLS simulator for UxPlay testing")
    parser.add_argument("--host", default="127.0.0.1", help="UxPlay host")
    parser.add_argument("--raop-port", type=int, default=7000, help="UxPlay RAOP/HTTP port")
    parser.add_argument("--hls-url", default="http://127.0.0.1:8765/master.m3u8",
                        help="HLS master playlist URL to send to UxPlay")
    parser.add_argument("--test-api-port", type=int, default=9999,
                        help="UxPlay --test-mode HTTP status port")
    args = parser.parse_args()

    ok = simulate_airplay_hls(args.host, args.raop_port, args.hls_url, args.test_api_port)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
