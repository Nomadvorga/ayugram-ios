/* Actual SDK smoke runner: link with the selected iOS slice, never HostStub.
 * argv[1]: installed model directory; argv[2]: raw mono S16 16kHz PCM fixture.
 * Fixture/model acquisition is explicit and separately checksummed.
 */
#include "vosk_api.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    vosk_set_log_level(-1);
    VoskModel *model = vosk_model_new(argv[1]);
    if (!model) return 1;
    VoskRecognizer *recognizer = vosk_recognizer_new(model, 16000);
    if (!recognizer) { vosk_model_free(model); return 2; }
    FILE *input = fopen(argv[2], "rb");
    if (!input) { vosk_recognizer_free(recognizer); vosk_model_free(model); return 3; }
    char bytes[8192];
    size_t count;
    int failure = 0;
    while ((count = fread(bytes, 1, sizeof(bytes), input)) != 0) {
        if (count % 2) { failure = 4; break; }
        int accepted = vosk_recognizer_accept_waveform(recognizer, bytes, (int)count);
        if (accepted < 0) { failure = 5; break; }
        if (accepted == 1 && !vosk_recognizer_result(recognizer)) { failure = 6; break; }
    }
    if (ferror(input)) failure = 7;
    if (!failure && !vosk_recognizer_final_result(recognizer)) failure = 8;
    fclose(input);
    vosk_recognizer_free(recognizer);
    vosk_model_free(model);
    return failure;
}
