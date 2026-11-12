// zv_sender: H.264-Access-Units fragmentieren (zv-Protokoll v1) und über zenoh-pico
// (Peer-Modus, UDP-Multicast) publizieren. Wird identisch im Linux-Test-Sender und in der
// iPad-App (über die Swift-Bridging-Header) verwendet.
#ifndef ZV_SENDER_H
#define ZV_SENDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZV_FLAG_KEY 0x01
#define ZV_FLAG_CONFIG 0x02
#define ZV_CODEC_H264 1
#define ZV_CODEC_HEVC 2
#define ZV_HDR_SIZE 16
#define ZV_DEFAULT_MAX_PAYLOAD 1200

typedef struct zv_sender zv_sender_t;

typedef struct {
    uint64_t frames;
    uint64_t keyframes;
    uint64_t fragments;
    uint64_t bytes;       // zv-Nutzlast inkl. 16-B-Header
    uint64_t put_errors;
    uint64_t keyreqs;     // empfangene Keyframe-Anforderungen (Rückkanal)
} zv_stats_t;

// mode: "peer" (Multicast) oder "client"; locator z.B. "udp/224.0.0.226:7447#iface=en0"
// (bei "client": connect-Endpoint, z.B. "tcp/192.168.1.10:7447"). Gibt NULL bei Fehler zurück.
zv_sender_t *zv_open(const char *mode, const char *locator, const char *key, int max_payload);

// annexb: komplettes Access Unit im Annex-B-Format (Startcodes), bei Keyframes inkl. SPS/PPS.
// flags: ZV_FLAG_* (0 = automatisch aus den NAL-Typen bestimmen). pace_us: Pause zwischen
// Fragmenten (0 = keine) - glättet Keyframe-Bursts, nützlich im WLAN.
int zv_send_au(zv_sender_t *s, const uint8_t *annexb, size_t len, uint32_t pts_ms, int flags, int pace_us);

// Rückkanal: abonniert key (z.B. "video/ipad/h264/keyreq"). Jede eintreffende Nachricht zählt als
// Keyframe-Anforderung (z.B. von der Bridge nach einem verlorenen Frame). 0 = ok.
int zv_subscribe_keyreq(zv_sender_t *s, const char *key);
// Liefert die Zahl der seit dem letzten Aufruf eingegangenen Anforderungen und setzt sie zurück.
// Thread-sicher, blockiert nicht (kann vor jedem Encoder-Aufruf abgefragt werden).
uint32_t zv_take_keyreq(zv_sender_t *s);

void zv_get_stats(zv_sender_t *s, zv_stats_t *out);
void zv_close(zv_sender_t *s);

// Hilfsfunktion: Flags aus den H.264-NAL-Typen (5 = IDR, 7/8 = SPS/PPS).
int zv_h264_flags(const uint8_t *annexb, size_t len);

#ifdef __cplusplus
}
#endif
#endif
