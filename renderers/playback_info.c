/**
 * playback_info.c — AirPlay 再生情報の収集・表示実装
 *
 * 表示先:
 *   - タイトルバー: video_renderer_set_title() 経由（Win32: SetWindowTextA、他: g_set_application_name）
 *   - コンソール:   g_print()
 *
 * 将来の拡張例:
 *   - OSD オーバーレイ: update_title() 内に textoverlay パイプライン制御を追加
 */

#include <glib.h>      /* guint 等の GLib 型が video_renderer.h で使われるため先行 include */
#include "playback_info.h"
#include "video_renderer.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>

struct playback_info_s {
    char decoder[64];
    char videosink[64];
    char video_codec[16];   /* "H.264" / "H.265" / ""  */
    char audio_codec[16];   /* "AAC-ELD" / "ALAC" / "AAC-LC" / "PCM" / "" */
    int  width, height;
    bool is_hls;
    char hls_decoder[64];   /* GStreamer が自動選択したビデオデコーダー要素名 */
};

/* ---- 内部ヘルパー ---- */

static void normalize_video_str(const char *src, char *dst, size_t dstsz) {
    if (strstr(src, "264") || strstr(src, "AVC"))
        snprintf(dst, dstsz, "H.264");
    else if (strstr(src, "265") || strstr(src, "HEVC") || strstr(src, "hevc"))
        snprintf(dst, dstsz, "H.265");
    else
        snprintf(dst, dstsz, "%.15s", src);
}

static void normalize_audio_str(const char *src, char *dst, size_t dstsz) {
    if (strstr(src, "AAC") || strstr(src, "aac"))
        snprintf(dst, dstsz, "AAC");
    else
        snprintf(dst, dstsz, "%.15s", src);
}

static const char *ct_to_name(unsigned char ct) {
    switch (ct) {
        case 1: return "PCM";
        case 2: return "ALAC";
        case 4: return "AAC-LC";
        case 8: return "AAC-ELD";
        default: return "unknown";
    }
}

static void update_title(playback_info_t *info) {
    char title[256];

    if (info->video_codec[0] && info->width > 0) {
        snprintf(title, sizeof(title), "UxPlay - %dx%d %s / %s",
                 info->width, info->height,
                 info->video_codec,
                 info->audio_codec[0] ? info->audio_codec : "?");
    } else if (info->video_codec[0]) {
        snprintf(title, sizeof(title), "UxPlay - %s / %s",
                 info->video_codec,
                 info->audio_codec[0] ? info->audio_codec : "?");
    } else if (info->audio_codec[0]) {
        snprintf(title, sizeof(title), "UxPlay - %s", info->audio_codec);
    } else {
        snprintf(title, sizeof(title), "UxPlay");
    }

    video_renderer_set_title(title);
}

/* ---- 公開 API ---- */

playback_info_t *playback_info_create(const char *decoder, const char *videosink) {
    playback_info_t *info = (playback_info_t *)calloc(1, sizeof(playback_info_t));
    if (!info) return NULL;
    snprintf(info->decoder,   sizeof(info->decoder),   "%s", decoder   ? decoder   : "");
    snprintf(info->videosink, sizeof(info->videosink), "%s", videosink ? videosink : "");
    return info;
}

void playback_info_destroy(playback_info_t *info) {
    free(info);
}

void playback_info_set_video_codec(playback_info_t *info, int is_h265) {
    if (!info) return;
    snprintf(info->video_codec, sizeof(info->video_codec),
             "%s", is_h265 ? "H.265" : "H.264");
    update_title(info);
}

void playback_info_set_audio_codec(playback_info_t *info, unsigned char ct) {
    if (!info) return;
    snprintf(info->audio_codec, sizeof(info->audio_codec), "%s", ct_to_name(ct));
    g_print("[AirPlay] Audio: %s\n", info->audio_codec);
    update_title(info);
}

void playback_info_set_resolution(playback_info_t *info, int width, int height) {
    if (!info) return;
    info->width  = width;
    info->height = height;
    if (info->is_hls) {
        g_print("[HLS] %dx%d  Video: %s  Audio: %s  Decoder: %s  Sink: %s\n",
                width, height,
                info->video_codec[0]  ? info->video_codec  : "?",
                info->audio_codec[0]  ? info->audio_codec  : "?",
                info->hls_decoder[0]  ? info->hls_decoder  : "?",
                info->videosink[0]    ? info->videosink    : "?");
    } else {
        g_print("[AirPlay] %dx%d  Video: %s  Audio: %s  Decoder: %s  Sink: %s\n",
                width, height,
                info->video_codec[0] ? info->video_codec : "?",
                info->audio_codec[0] ? info->audio_codec : "?",
                info->decoder[0]     ? info->decoder     : "?",
                info->videosink[0]   ? info->videosink   : "?");
    }
    update_title(info);
}

void playback_info_set_hls_decoder(playback_info_t *info, const char *decoder) {
    if (!info || !decoder) return;
    snprintf(info->hls_decoder, sizeof(info->hls_decoder), "%s", decoder);
}

void playback_info_print_hls_state(playback_info_t *info) {
    if (!info) return;
    char res[32];
    if (info->width > 0)
        snprintf(res, sizeof(res), "%dx%d", info->width, info->height);
    else
        snprintf(res, sizeof(res), "unknown");
    g_print("[HLS] State: Codec=%s  Decoder=%s  Sink=%s  Resolution=%s\n",
            info->video_codec[0] ? info->video_codec : "?",
            info->hls_decoder[0] ? info->hls_decoder : "?",
            info->videosink[0]   ? info->videosink   : "?",
            res);
}

void playback_info_set_hls_mode(playback_info_t *info, bool is_hls) {
    if (!info) return;
    info->is_hls = is_hls;
}

void playback_info_set_video_codec_str(playback_info_t *info, const char *str) {
    if (!info || !str) return;
    normalize_video_str(str, info->video_codec, sizeof(info->video_codec));
    update_title(info);
}

void playback_info_set_audio_codec_str(playback_info_t *info, const char *str) {
    if (!info || !str) return;
    normalize_audio_str(str, info->audio_codec, sizeof(info->audio_codec));
    update_title(info);
}

void playback_info_clear(playback_info_t *info) {
    if (!info) return;
    bool had_content = info->video_codec[0] != '\0' || info->audio_codec[0] != '\0';
    info->video_codec[0] = '\0';
    info->audio_codec[0] = '\0';
    info->hls_decoder[0] = '\0';
    info->width  = 0;
    info->height = 0;
    if (had_content) {
        g_print("%s Stream ended\n", info->is_hls ? "[HLS]" : "[AirPlay]");
    }
    video_renderer_set_title("UxPlay");
}
