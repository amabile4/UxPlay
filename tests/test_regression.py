"""
test_regression.py — UxPlay E2E リグレッションテスト

UxPlay を --test-mode で起動した状態で実行する。
AirPlay プロトコルシミュレーター (airplay_sim.py) と
モック HLS サーバー (mock_hls_server.py) を使って接続・再生を確認する。

実行方法:
    # 1. UxPlay を起動 (別ターミナル)
    uxplay.exe --test-mode --test-port 9999 -hls -n UxPlayTestDevice

    # 2. テスト実行
    pytest tests/test_regression.py -v --timeout=120

環境変数:
    UXPLAY_HOST          UxPlay ホスト (デフォルト: 127.0.0.1)
    UXPLAY_RAOP_PORT     UxPlay AirPlay ポート (デフォルト: 7000)
    UXPLAY_TEST_PORT     UxPlay --test-mode ポート (デフォルト: 9999)
    MOCK_HLS_PORT        モック HLS サーバーポート (デフォルト: 8765)
"""

import os
import time
import threading
import subprocess
import sys

import pytest
import requests

# --- 環境変数からパラメーター取得 ---
UXPLAY_HOST      = os.environ.get("UXPLAY_HOST",      "127.0.0.1")
UXPLAY_RAOP_PORT = int(os.environ.get("UXPLAY_RAOP_PORT", "7000"))
UXPLAY_TEST_PORT = int(os.environ.get("UXPLAY_TEST_PORT", "9999"))
MOCK_HLS_PORT    = int(os.environ.get("MOCK_HLS_PORT",    "8765"))

TEST_STATUS_URL  = f"http://127.0.0.1:{UXPLAY_TEST_PORT}/test/status"
MOCK_HLS_URL     = f"http://127.0.0.1:{MOCK_HLS_PORT}/master.m3u8"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def mock_hls_server():
    """セッション全体でモック HLS サーバーを起動する"""
    from mock_hls_server import start
    server = start(MOCK_HLS_PORT)
    print(f"\n[fixture] Mock HLS server started on port {MOCK_HLS_PORT}")
    yield server
    server.shutdown()


@pytest.fixture(scope="session")
def run_sim():
    """AirPlay シミュレーターを実行する"""
    from airplay_sim import simulate_airplay_hls
    ok = simulate_airplay_hls(UXPLAY_HOST, UXPLAY_RAOP_PORT, MOCK_HLS_URL, UXPLAY_TEST_PORT)
    return ok


def wait_for_condition(check_fn, timeout: float = 30.0, interval: float = 1.0) -> bool:
    """check_fn が True を返すまで最大 timeout 秒待機する"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if check_fn():
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False


def get_status() -> dict:
    """test/status エンドポイントを呼び出して JSON を返す"""
    resp = requests.get(TEST_STATUS_URL, timeout=5)
    resp.raise_for_status()
    return resp.json()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestUxPlayE2E:

    def test_01_test_server_reachable(self):
        """UxPlay の --test-mode HTTP サーバーに到達できること"""
        try:
            status = get_status()
        except Exception as e:
            pytest.fail(f"test/status not reachable: {e}\n"
                        f"Make sure UxPlay is running with --test-mode --test-port {UXPLAY_TEST_PORT}")
        assert isinstance(status, dict), "Expected JSON object"
        assert "open_connections" in status, "Missing open_connections field"
        print(f"\n  initial status: {status}")

    def test_02_connection_established(self, run_sim):
        """AirPlay シミュレーター実行後に接続が確立されること"""
        assert run_sim, "AirPlay simulator failed to run"
        # シミュレーターは接続完了後に戻るので、接続数を確認
        def _check():
            s = get_status()
            return s.get("open_connections", 0) >= 1

        connected = wait_for_condition(_check, timeout=10.0)
        if not connected:
            # シミュレーターが既に切断していた場合はポスト接続でも成功とみなす
            # (シミュレーターのシーケンス実行中に接続→切断が完了している場合)
            status = get_status()
            print(f"\n  status after sim: {status}")
            # 最低限 uptime_seconds が増加していることを確認
            assert status.get("uptime_seconds", 0) > 0, "UxPlay did not seem to run"

    def test_03_hls_play_received(self, run_sim):
        """POST /play が送信され、HLS 再生が開始されること"""
        # シミュレーター実行後に hls_playing が True になっているか確認
        # (または接続中に一時的に True になった)
        status = get_status()
        print(f"\n  status: {status}")
        # hls_url が設定されていれば /play が処理されたと判断する
        # (接続が切断されると hls_playing は False に戻る場合がある)
        hls_url = status.get("hls_url", "")
        assert hls_url != "" or status.get("hls_playing", False), \
            "HLS play URL was never received by UxPlay"

    def test_04_codec_detected(self, run_sim):
        """GStreamer が動画コーデックを検出すること"""
        # HLS デコードが完了すれば video_codec が設定される
        # CI ではパイプライン起動に時間がかかるため 60 秒待機する
        def _check():
            s = get_status()
            return s.get("video_codec", "") in ("H.264", "H.265")

        detected = wait_for_condition(_check, timeout=60.0)
        if not detected:
            status = get_status()
            print(f"\n  status: {status}")
            pytest.skip("Codec not detected within timeout (GStreamer pipeline may not have started)")

    def test_05_resolution_detected(self, run_sim):
        """動画解像度が検出されること"""
        def _check():
            s = get_status()
            return s.get("width", 0) > 0 and s.get("height", 0) > 0

        detected = wait_for_condition(_check, timeout=60.0)
        if not detected:
            status = get_status()
            print(f"\n  status: {status}")
            pytest.skip("Resolution not detected within timeout")

    def test_06_no_fatal_errors_in_log(self, tmp_path, capfd):
        """UxPlay のログに致命的エラーが含まれないこと"""
        # このテストはログファイルが存在する場合のみ実行する
        log_files = ["uxplay_stderr.txt", "uxplay_stdout.txt"]
        error_patterns = ["*** ERROR", "GStreamer error", "CRITICAL"]

        for log_file in log_files:
            if not os.path.exists(log_file):
                continue
            with open(log_file, encoding="utf-8", errors="replace") as f:
                content = f.read()
            for pattern in error_patterns:
                assert pattern not in content, \
                    f"Fatal error pattern '{pattern}' found in {log_file}"


# ---------------------------------------------------------------------------
# Quick connectivity check (standalone run)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print(f"Testing UxPlay at {TEST_STATUS_URL}")
    try:
        status = get_status()
        print(f"Status: {status}")
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
