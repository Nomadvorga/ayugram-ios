#ifndef EXTERA_VOSK_INFLATE_H
#define EXTERA_VOSK_INFLATE_H
#include <stddef.h>
#include <stdint.h>

typedef struct ExteraVoskInflate ExteraVoskInflate;
ExteraVoskInflate *extera_vosk_inflate_new(void);
/* Returns 1 at stream end, 0 while processing, -1 on invalid stream.
 * Updates consumed/written counts; never retains input/output pointers. */
int extera_vosk_inflate(ExteraVoskInflate *, const uint8_t *, size_t,
                       uint8_t *, size_t, size_t *, size_t *);
void extera_vosk_inflate_free(ExteraVoskInflate *);
uint32_t extera_vosk_crc32(uint32_t, const uint8_t *, size_t);
#endif
