#include "VoskInflate.h"
#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

struct ExteraVoskInflate { z_stream stream; };

ExteraVoskInflate *extera_vosk_inflate_new(void) {
    ExteraVoskInflate *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    if (inflateInit2(&state->stream, -MAX_WBITS) != Z_OK) {
        free(state);
        return NULL;
    }
    return state;
}

int extera_vosk_inflate(ExteraVoskInflate *state, const uint8_t *input, size_t count,
                       uint8_t *output, size_t capacity, size_t *consumed, size_t *written) {
    if (!state || count > UINT_MAX || capacity > UINT_MAX) return -1;
    state->stream.next_in = (Bytef *)input;
    state->stream.avail_in = (uInt)count;
    state->stream.next_out = output;
    state->stream.avail_out = (uInt)capacity;
    int result = inflate(&state->stream, Z_NO_FLUSH);
    *consumed = count - state->stream.avail_in;
    *written = capacity - state->stream.avail_out;
    if (result == Z_STREAM_END) return 1;
    return result == Z_OK || result == Z_BUF_ERROR ? 0 : -1;
}

void extera_vosk_inflate_free(ExteraVoskInflate *state) {
    if (state) { inflateEnd(&state->stream); free(state); }
}

uint32_t extera_vosk_crc32(uint32_t previous, const uint8_t *data, size_t count) {
    if (count > UINT_MAX) return 0;
    return (uint32_t)crc32(previous, data, (uInt)count);
}
