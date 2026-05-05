/**
 * playback_info.h — AirPlay 再生情報の収集・表示モジュール (公開 API)
 *
 * 設計方針:
 *   - uxplay.cpp 側の変更を最小限にとどめる
 *   - 将来の表示先追加（OSD 等）はこのモジュール内部で完結する
 *   - 全関数は NULL を渡しても安全（no-op）
 */

#ifndef PLAYBACK_INFO_H
#define PLAYBACK_INFO_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct playback_info_s playback_info_t;

/**
 * 起動時に一度だけ生成する。
 * decoder / videosink はコマンドライン解析後の確定値を渡す。
 */
playback_info_t *playback_info_create(const char *decoder, const char *videosink);
void             playback_info_destroy(playback_info_t *info);

/**
 * 各コールバックから呼ばれるアップデート関数。
 * is_h265: 非0 なら H.265、0 なら H.264
 * ct: AirPlay の圧縮タイプ (1=PCM, 2=ALAC, 4=AAC-LC, 8=AAC-ELD)
 */
void playback_info_set_video_codec(playback_info_t *info, int is_h265);
void playback_info_set_audio_codec(playback_info_t *info, unsigned char ct);
void playback_info_set_resolution(playback_info_t *info, int width, int height);

/** 全接続が切れたときに呼ぶ。codec/resolution をリセットしタイトルを戻す。 */
void playback_info_clear(playback_info_t *info);

#ifdef __cplusplus
}
#endif

#endif /* PLAYBACK_INFO_H */
