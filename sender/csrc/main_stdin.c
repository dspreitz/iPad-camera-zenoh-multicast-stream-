// Linux/macOS-Testsender: liest H.264 Annex-B mit AUD-Trennern von stdin (z.B. ffmpeg ...
// -x264-params aud=1 -f h264 -) und publiziert jedes Access Unit über zv_sender (zenoh-pico).
// Aufruf: zv_pico_sender [-m peer] [-l udp/224.0.0.226:7447#iface=eth0] [-k video/ipad/h264] [-p pace_us]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "zv_sender.h"

static uint32_t now_ms32(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint32_t)((uint64_t)tv.tv_sec * 1000u + (uint64_t)tv.tv_usec / 1000u);
}

// Sucht 00 00 00 01 09 (AUD mit 4-Byte-Startcode) ab Position from.
static long find_aud(const uint8_t *b, size_t n, size_t from) {
    for (size_t i = from; i + 4 < n; i++)
        if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1 && (b[i + 4] & 0x1f) == 9) return (long)i;
    return -1;
}

int main(int argc, char **argv) {
    const char *mode = "peer", *loc = "udp/224.0.0.226:7447#iface=eth0", *key = "video/ipad/h264";
    int pace = 0, maxp = ZV_DEFAULT_MAX_PAYLOAD, opt;
    while ((opt = getopt(argc, argv, "m:l:k:p:s:")) != -1) {
        if (opt == 'm') mode = optarg;
        else if (opt == 'l') loc = optarg;
        else if (opt == 'k') key = optarg;
        else if (opt == 'p') pace = atoi(optarg);
        else if (opt == 's') maxp = atoi(optarg);
    }
    zv_sender_t *s = zv_open(mode, loc, key, maxp);
    if (!s) return 1;
    fprintf(stderr, "[pico-sender] zenoh-pico %s %s key=%s\n", mode, loc, key);
    sleep(1);

    size_t cap = 1 << 20, len = 0;
    uint8_t *buf = malloc(cap);
    time_t last = time(NULL), start = last;
    for (;;) {
        if (cap - len < 65536) { cap *= 2; buf = realloc(buf, cap); }
        ssize_t r = read(0, buf + len, 65536);
        if (r <= 0) break;
        len += (size_t)r;
        for (;;) {
            long a = find_aud(buf, len, 0);
            if (a < 0) break;
            long b = find_aud(buf, len, (size_t)a + 5);
            if (b < 0) break;
            const uint8_t *au = buf + a + 6;  // AUD (6 Byte) überspringen
            size_t aulen = (size_t)(b - a - 6);
            zv_send_au(s, au, aulen, now_ms32(), 0, pace);
            memmove(buf, buf + b, len - (size_t)b);
            len -= (size_t)b;
        }
        time_t now = time(NULL);
        if (now - last >= 5) {
            zv_stats_t st;
            zv_get_stats(s, &st);
            double el = (double)(now - start);
            fprintf(stderr, "[pico-sender] %llu frames, %llu key, %llu frags, zv-payload %.0f kbit/s, put_errors %llu\n",
                    (unsigned long long)st.frames, (unsigned long long)st.keyframes, (unsigned long long)st.fragments,
                    (double)st.bytes * 8 / el / 1000, (unsigned long long)st.put_errors);
            last = now;
        }
    }
    zv_close(s);
    free(buf);
    return 0;
}
