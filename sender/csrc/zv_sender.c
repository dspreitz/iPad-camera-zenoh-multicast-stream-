#include "zv_sender.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zenoh-pico.h>

struct zv_sender {
    z_owned_session_t session;
    // Nur zu Testzwecken (Umgebungsvariable ZV_DECLARE_PUBLISHER=1): deklarierter Publisher statt z_put,
    // um zenoh #2820 (spät verbundener Client sieht Multicast-Subscriber nicht) mit zenoh-pico zu prüfen.
    z_owned_publisher_t pub;
    int use_pub;
    z_owned_subscriber_t keyreq_sub;
    int has_keyreq_sub;
    atomic_uint keyreq_pending;
    atomic_ullong keyreq_total;
    char key[256];
    int max_payload;
    uint32_t seq;
    zv_stats_t st;
    uint8_t *buf;
};

static void put_be16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

int zv_h264_flags(const uint8_t *b, size_t n) {
    int f = 0;
    for (size_t i = 0; i + 3 < n; i++) {
        if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
            int t = b[i + 3] & 0x1f;
            if (t == 5) f |= ZV_FLAG_KEY;
            if (t == 7 || t == 8) f |= ZV_FLAG_CONFIG;
            i += 2;
        }
    }
    return f;
}

zv_sender_t *zv_open(const char *mode, const char *locator, const char *key, int max_payload) {
    zv_sender_t *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->max_payload = max_payload > 0 ? max_payload : ZV_DEFAULT_MAX_PAYLOAD;
    s->buf = malloc((size_t)s->max_payload + ZV_HDR_SIZE);
    snprintf(s->key, sizeof(s->key), "%s", key);

    z_owned_config_t config;
    z_config_default(&config);
    zp_config_insert(z_loan_mut(config), Z_CONFIG_MODE_KEY, mode);
    if (strcmp(mode, "peer") == 0) {
        zp_config_insert(z_loan_mut(config), Z_CONFIG_LISTEN_KEY, locator);
    } else {
        zp_config_insert(z_loan_mut(config), Z_CONFIG_CONNECT_KEY, locator);
        // Kein Multicast-Scouting: der Server ist bekannt (und iOS blockiert Multicast ohne Entitlement).
        zp_config_insert(z_loan_mut(config), Z_CONFIG_MULTICAST_SCOUTING_KEY, "false");
    }
    if (z_open(&s->session, z_move(config), NULL) < 0) {
        fprintf(stderr, "zv: z_open(%s, %s) fehlgeschlagen\n", mode, locator);
        free(s->buf);
        free(s);
        return NULL;
    }
    const char *dp = getenv("ZV_DECLARE_PUBLISHER");
    if (dp && strcmp(dp, "1") == 0) {
        z_view_keyexpr_t vke;
        z_view_keyexpr_from_str(&vke, s->key);
        z_publisher_options_t popts;
        z_publisher_options_default(&popts);
        popts.congestion_control = Z_CONGESTION_CONTROL_DROP;
        if (z_declare_publisher(z_loan(s->session), &s->pub, z_loan(vke), &popts) == 0) {
            s->use_pub = 1;
            fprintf(stderr, "zv: deklarierter Publisher (Test #2820)\n");
        }
    }
    return s;
}

static void sleep_us(int us) {
    struct timespec ts = {us / 1000000, (long)(us % 1000000) * 1000L};
    nanosleep(&ts, NULL);
}

int zv_send_au(zv_sender_t *s, const uint8_t *au, size_t len, uint32_t pts_ms, int flags, int pace_us) {
    if (!s || !au || len == 0) return -1;
    if (flags == 0) flags = zv_h264_flags(au, len);
    size_t mp = (size_t)s->max_payload;
    size_t cnt = (len + mp - 1) / mp;
    if (cnt > 65535) return -2;
    z_view_keyexpr_t vke;
    if (z_view_keyexpr_from_str(&vke, s->key) < 0) return -3;
    int errors = 0;
    for (size_t i = 0; i < cnt; i++) {
        size_t off = i * mp;
        size_t n = len - off < mp ? len - off : mp;
        uint8_t *h = s->buf;
        h[0] = 1;
        h[1] = (uint8_t)flags;
        put_be16(h + 2, (uint16_t)i);
        put_be16(h + 4, (uint16_t)cnt);
        h[6] = ZV_CODEC_H264;
        h[7] = 0;
        put_be32(h + 8, s->seq);
        put_be32(h + 12, pts_ms);
        memcpy(h + ZV_HDR_SIZE, au + off, n);

        z_owned_bytes_t payload;
        z_bytes_copy_from_buf(&payload, s->buf, n + ZV_HDR_SIZE);
        z_put_options_t opts;
        z_put_options_default(&opts);
        opts.congestion_control = Z_CONGESTION_CONTROL_DROP;
        z_result_t r;
        if (s->use_pub) {
            r = z_publisher_put(z_loan(s->pub), z_move(payload), NULL);
        } else {
            r = z_put(z_loan(s->session), z_loan(vke), z_move(payload), &opts);
        }
        if (r < 0) {
            errors++;
            s->st.put_errors++;
        } else {
            s->st.fragments++;
            s->st.bytes += n + ZV_HDR_SIZE;
        }
        if (pace_us > 0 && i + 1 < cnt) sleep_us(pace_us);
    }
    s->seq++;
    s->st.frames++;
    if (flags & ZV_FLAG_KEY) s->st.keyframes++;
    return errors ? -4 : 0;
}

static void keyreq_handler(z_loaned_sample_t *sample, void *ctx) {
    (void)sample;
    zv_sender_t *s = (zv_sender_t *)ctx;
    atomic_fetch_add(&s->keyreq_pending, 1);
    atomic_fetch_add(&s->keyreq_total, 1);
}

int zv_subscribe_keyreq(zv_sender_t *s, const char *key) {
    if (!s || !key || s->has_keyreq_sub) return -1;
    z_view_keyexpr_t vke;
    if (z_view_keyexpr_from_str(&vke, key) < 0) return -2;
    z_owned_closure_sample_t cb;
    z_closure(&cb, keyreq_handler, NULL, s);
    if (z_declare_subscriber(z_loan(s->session), &s->keyreq_sub, z_loan(vke), z_move(cb), NULL) < 0) return -3;
    s->has_keyreq_sub = 1;
    return 0;
}

uint32_t zv_take_keyreq(zv_sender_t *s) {
    return s ? atomic_exchange(&s->keyreq_pending, 0) : 0;
}

void zv_get_stats(zv_sender_t *s, zv_stats_t *out) {
    if (!s || !out) return;
    *out = s->st;
    out->keyreqs = atomic_load(&s->keyreq_total);
}

void zv_close(zv_sender_t *s) {
    if (!s) return;
    if (s->has_keyreq_sub) z_drop(z_move(s->keyreq_sub));
    if (s->use_pub) z_drop(z_move(s->pub));
    z_drop(z_move(s->session));
    free(s->buf);
    free(s);
}
