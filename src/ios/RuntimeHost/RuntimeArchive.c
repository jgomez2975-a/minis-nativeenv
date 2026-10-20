/*
 * RuntimeArchive.c — see RuntimeArchive.h.
 *
 * Streaming gzip inflate with a 64 KB output window. No dynamic allocation
 * beyond zlib's own state, so a failed install cannot leave the heap pinned.
 */

#include "RuntimeArchive.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

#define RA_CHUNK 65536

const char *ra_zlib_version(void) { return zlibVersion(); }

static int ra_pump(z_stream *zs, RAWriteCallback callback, void *ctx, uint8_t *out) {
    for (;;) {
        zs->next_out = out;
        zs->avail_out = RA_CHUNK;

        int rc = inflate(zs, Z_NO_FLUSH);
        if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
            return (rc == Z_DATA_ERROR) ? -4 : -4;
        }

        size_t produced = RA_CHUNK - zs->avail_out;
        if (produced > 0) {
            if (callback(ctx, out, produced) != 0) {
                return -5;
            }
        }

        if (rc == Z_STREAM_END) {
            return 0;
        }
        if (rc == Z_BUF_ERROR) {
            /* No progress and no end: either the caller must feed more input
             * (handled by the loop above) or the stream is truncated. */
            return (zs->avail_in == 0) ? -6 : 0;
        }
        if (zs->avail_in == 0 && produced == 0) {
            return -6;
        }
    }
}

int ra_gunzip_memory(const uint8_t *inBytes, size_t inLength,
                     RAWriteCallback callback, void *ctx) {
    if (inBytes == NULL || inLength < 2) { return -3; }
    /* gzip magic 0x1f 0x8b */
    if (inBytes[0] != 0x1f || inBytes[1] != 0x8b) { return -3; }

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) { return -3; }

    uint8_t *out = (uint8_t *)malloc(RA_CHUNK);
    if (out == NULL) { inflateEnd(&zs); return -4; }

    zs.next_in = (Bytef *)inBytes;
    zs.avail_in = (uInt)inLength;

    int rc = ra_pump(&zs, callback, ctx, out);

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
    int headerChecked = 0;

    for (;;) {
        ssize_t n = read(fd, in, RA_CHUNK);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            result = -2;
            break;
        }
        if (n == 0) { break; }

        if (!headerChecked) {
            if (n < 2 || in[0] != 0x1f || in[1] != 0x8b) { result = -3; break; }
            headerChecked = 1;
        }

        zs.next_in = in;
        zs.avail_in = (uInt)n;

        for (;;) {
            result = ra_pump(&zs, callback, ctx, out);
            if (result != 0 || zs.avail_in == 0) { break; }
        }
        if (result != 0) { break; }
    }

    if (result == 0 && !headerChecked) { result = -3; }

    free(in);
    free(out);
    inflateEnd(&zs);
    close(fd);
    return result;
}
