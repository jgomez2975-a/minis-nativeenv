/*
 * RuntimeArchive.h — gzip decoding for the RuntimeHost installer.
 *
 * Lives in C because it needs zlib's inflateInit2 with the 16+MAX_WBITS gzip
 * window, which Swift cannot express without a shim. Apple's Compression
 * framework is deliberately not used here: COMPRESSION_ZLIB is RFC 1950, and
 * relying on it accepting a headerless RFC 1952 payload is exactly the kind of
 * undocumented behaviour that breaks on the next OS.
 *
 * Link: libz.tbd (already present transitively via FFmpeg).
 */

#ifndef RUNTIME_ARCHIVE_H
#define RUNTIME_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*RAWriteCallback)(void *ctx, const uint8_t *bytes, size_t length);

/**
 * Inflate a gzip member (RFC 1952) from `inPath` into `callback`.
 *
 * The whole member is streamed: no full-archive buffer is allocated, which
 * matters for TheosRuntime.tar.gz where the decompressed tar stream is ~1 GB.
 *
 * Returns 0 on success, a negative errno-style code otherwise:
 *   -1 open failed   -2 read failed   -3 not a gzip stream
 *   -4 corrupt       -5 write callback rejected the data
 *   -6 truncated at end of member data
 */
int ra_gunzip_stream(const char *inPath, RAWriteCallback callback, void *ctx);

/**
 * Inflate a gzip member from a memory buffer into `callback`.
 * Same return codes as above.
 */
int ra_gunzip_memory(const uint8_t *inBytes, size_t inLength,
                     RAWriteCallback callback, void *ctx);

/** zlib version actually linked, for the diagnostics panel. */
const char *ra_zlib_version(void);

#ifdef __cplusplus
}
#endif

#endif /* RUNTIME_ARCHIVE_H */
