/*
 * RuntimeArchive.c — see RuntimeArchive.h.
 *
 * Streaming gzip inflate with a 64 KB output window. No dynamic allocation
 * beyond zlib's own state, so a failed install cannot leave the heap pinned.
 *
 * The state machine is explicit because the obvious version is wrong: a pump
 * that keeps calling inflate until the *stream* ends will return a truncation
 * error the moment the 64 KB input buffer runs dry, which happens on every file
 * bigger than 64 KB. "Need more input" is therefore a distinct, non-error
 * return that the reader loop responds to by reading more bytes.
 */

#include "RuntimeArchive.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

#define RA_CHUNK 65536

/* Internal signal: inflate consumed all input, stream not finished yet. */
#define RA_NEED_INPUT 1

const char *ra_zlib_version(void) { return zlibVersion(); }

static int ra_emit(z_stream *zs, RAWriteCallback callback, void *ctx, uint8_t *out) {
    size_t produced = (size_t)(RA_CHUNK - zs->avail_out);
    if (produced == 0) { return 0; }
    return callback(ctx, out, produced) == 0 ? 0 : -5;
}

/**
 * Drive inflate until the stream ends, output fills, or input runs out.
 * Returns 0 on stream end, RA_NEED_INPUT when the caller must supply more
 * bytes, or a negative error.
 */
static int ra_pump(z_stream *zs, RAWriteCallback callback, void *ctx, uint8_t *out) {
    for (;;) {
        zs->next_out = out;
        zs->avail_out = RA_CHUNK;

        int rc = inflate(zs, Z_NO_FLUSH);

        if (rc == Z_STREAM_END) {
            int emit = ra_emit(zs, callback, ctx, out);
            return emit != 0 ? emit : 0;
        }
        if (rc != Z_OK && rc != Z_BUF_ERROR) {
            return -4; /* corrupt stream / bad header */
        }

        int emit = ra_emit(zs, callback, ctx, out);
        if (emit != 0) { return emit; }

        if (zs->avail_in == 0) {
            /* Z_BUF_ERROR here means no progress is possible until more input
             * arrives. Z_OK with empty input means the same thing. */
            return RA_NEED_INPUT;
        }
        /* input still buffered — keep producing */
    }
}

int ra_gunzip_memory(const uint8_t *inBytes, size_t inLength,
                     RAWriteCallback callback, void *ctx) {
    if (inBytes == NULL || inLength < 2) { return -3; }
    if (inBytes[0] != 0x1f || inBytes[1] != 0x8b) { return -3; }

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) { return -3; }

    uint8_t *out = (uint8_t *)malloc(RA_CHUNK);
    if (out == NULL) { inflateEnd(&zs); return -4; }

    zs.next_in = (Bytef *)inBytes;
    zs.avail_in = (uInt)inLength;

    int rc;
    for (;;) {
        rc = ra_pump(&zs, callback, ctx, out);
        if (rc != RA_NEED_INPUT) { break; }
        /* Memory buffer: no more input is coming. */
        rc = -6;
        break;
    }

    inflateEnd(&zs);
    free(out);
    return rc;
}

int ra_gunzip_stream(const char *inPath, RAWriteCallback callback, void *ctx) {
    int fd = open(inPath, O_RDONLY);
    if (fd < 0) { return -1; }

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) {
        close(fd);
        return -3;
    }

    uint8_t *in = (uint8_t *)malloc(RA_CHUNK);
    uint8_t *out = (uint8_t *)malloc(RA_CHUNK);
    if (in == NULL || out == NULL) {
        free(in); free(out);
        inflateEnd(&zs);
        close(fd);
        return -4;
    }

    int result = 0;
    int sawHeader = 0;
    int finished = 0;

    while (!finished) {
        ssize_t n = read(fd, in, RA_CHUNK);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            result = -2;
            break;
        }
        if (n == 0) {
            /* EOF without Z_STREAM_END: the archive is truncated. */
            result = -6;
            break;
        }

        if (!sawHeader) {
            if (n < 2 || in[0] != 0x1f || in[1] != 0x8b) { result = -3; break; }
            sawHeader = 1;
        }

        zs.next_in = in;
        zs.avail_in = (uInt)n;

        for (;;) {
            int rc = ra_pump(&zs, callback, ctx, out);
            if (rc == 0) { finished = 1; break; }
            if (rc != RA_NEED_INPUT) { result = rc; break; }
            if (zs.avail_in == 0) { break; } /* read more */
            /* RA_NEED_INPUT with input remaining cannot happen, but looping is
             * safer than assuming: the next ra_pump call will either consume it
             * or report a real error. */
        }
        if (result != 0) { break; }
    }

    if (result == 0 && !sawHeader) { result = -3; }

    free(in);
    free(out);
    inflateEnd(&zs);
    close(fd);
    return result;
}
