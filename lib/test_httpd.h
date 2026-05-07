/**
 * test_httpd.h — テストモード用 HTTP ステータスサーバー (公開 API)
 *
 * uxplay --test-mode 時のみ起動する。
 * GET /test/status → JSON で接続・再生状態を返す。
 */

#ifndef TEST_HTTPD_H
#define TEST_HTTPD_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    unsigned int open_connections;
    bool         hls_playing;
    char         hls_url[512];
    char         client_proc_name[64];
    char         video_codec[16];
    char         audio_codec[16];
    int          width, height;
    float        rate;
    double       position;
    double       duration;
} test_status_t;

typedef struct test_httpd_s test_httpd_t;

/** ポートを指定してサーバーを起動する。失敗時は NULL を返す。 */
test_httpd_t *test_httpd_start(unsigned short port);

/** サーバーを停止してリソースを解放する。 */
void test_httpd_stop(test_httpd_t *httpd);

/** 再生状態を更新する（スレッドセーフ）。 */
void test_httpd_update(test_httpd_t *httpd, const test_status_t *status);

#ifdef __cplusplus
}
#endif

#endif /* TEST_HTTPD_H */
