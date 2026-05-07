/**
 * test_httpd.c — テストモード用 HTTP ステータスサーバー実装
 *
 * GET /test/status のみ対応。JSON で再生状態を返す。
 * lib/compat.h のクロスプラットフォーム抽象化を使用する。
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

#include "test_httpd.h"
#include "compat.h"

#ifdef WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/in.h>
#endif

#define BACKLOG       4
#define REQ_BUFSIZE   512
#define JSON_MAXSIZE  1024
#define RESP_MAXSIZE  (JSON_MAXSIZE + 256)

struct test_httpd_s {
    thread_handle_t thread;
    mutex_handle_t  mutex;
    int             running;
    int             server_fd;
    test_status_t   status;
    time_t          start_time;
};

/* ---- 内部ヘルパー ---- */

static void build_json(const struct test_httpd_s *h, char *buf, int bufsz) {
    long uptime = (long)(time(NULL) - h->start_time);
    snprintf(buf, bufsz,
        "{"
        "\"open_connections\":%u,"
        "\"hls_playing\":%s,"
        "\"hls_url\":\"%s\","
        "\"client_proc_name\":\"%s\","
        "\"video_codec\":\"%s\","
        "\"audio_codec\":\"%s\","
        "\"width\":%d,"
        "\"height\":%d,"
        "\"rate\":%.2f,"
        "\"position\":%.3f,"
        "\"duration\":%.3f,"
        "\"uptime_seconds\":%ld"
        "}",
        h->status.open_connections,
        h->status.hls_playing ? "true" : "false",
        h->status.hls_url,
        h->status.client_proc_name,
        h->status.video_codec,
        h->status.audio_codec,
        h->status.width,
        h->status.height,
        (double)h->status.rate,
        h->status.position,
        h->status.duration,
        uptime);
}

static THREAD_RETVAL server_thread(void *arg) {
    struct test_httpd_s *h = (struct test_httpd_s *)arg;
    char req[REQ_BUFSIZE];
    char json[JSON_MAXSIZE];
    char resp[RESP_MAXSIZE];

    while (h->running) {
        fd_set fds;
        struct timeval tv;
        tv.tv_sec  = 1;
        tv.tv_usec = 0;
        FD_ZERO(&fds);
        FD_SET(h->server_fd, &fds);
        if (select(h->server_fd + 1, &fds, NULL, NULL, &tv) <= 0)
            continue;

        int client_fd = (int)accept(h->server_fd, NULL, NULL);
        if (client_fd < 0)
            continue;

        int n = (int)recv(client_fd, req, sizeof(req) - 1, 0);
        if (n > 0) {
            req[n] = '\0';
            if (strncmp(req, "GET /test/status", 16) == 0) {
                MUTEX_LOCK(h->mutex);
                build_json(h, json, sizeof(json));
                MUTEX_UNLOCK(h->mutex);
                snprintf(resp, sizeof(resp),
                    "HTTP/1.0 200 OK\r\n"
                    "Content-Type: application/json\r\n"
                    "Content-Length: %d\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    "%s",
                    (int)strlen(json), json);
            } else {
                snprintf(resp, sizeof(resp),
                    "HTTP/1.0 404 Not Found\r\n"
                    "Content-Length: 0\r\n"
                    "Connection: close\r\n\r\n");
            }
            send(client_fd, resp, (int)strlen(resp), 0);
        }
        CLOSESOCKET(client_fd);
    }
    return NULL;
}

/* ---- 公開 API ---- */

test_httpd_t *test_httpd_start(unsigned short port) {
    test_httpd_t *h = (test_httpd_t *)calloc(1, sizeof(test_httpd_t));
    if (!h) return NULL;

    h->start_time = time(NULL);
    h->server_fd  = (int)socket(AF_INET, SOCK_STREAM, 0);
    if (h->server_fd < 0) {
        free(h);
        return NULL;
    }

    int opt = 1;
#ifdef WIN32
    setsockopt(h->server_fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&opt, sizeof(opt));
#else
    setsockopt(h->server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  /* localhost のみ */
    addr.sin_port        = htons(port);

    if (bind(h->server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        listen(h->server_fd, BACKLOG) < 0) {
        CLOSESOCKET(h->server_fd);
        free(h);
        return NULL;
    }

    MUTEX_CREATE(h->mutex);
    h->running = 1;
    THREAD_CREATE(h->thread, server_thread, h);
    if (!h->thread) {
        h->running = 0;
        CLOSESOCKET(h->server_fd);
        MUTEX_DESTROY(h->mutex);
        free(h);
        return NULL;
    }
    return h;
}

void test_httpd_stop(test_httpd_t *h) {
    if (!h) return;
    h->running = 0;
    THREAD_JOIN(h->thread);
    CLOSESOCKET(h->server_fd);
    MUTEX_DESTROY(h->mutex);
    free(h);
}

void test_httpd_update(test_httpd_t *h, const test_status_t *s) {
    if (!h || !s) return;
    MUTEX_LOCK(h->mutex);
    memcpy(&h->status, s, sizeof(test_status_t));
    MUTEX_UNLOCK(h->mutex);
}
