/* Actual SDK smoke runner: link with the selected iOS Simulator slice, never HostStub. */
#include "vosk_api.h"
#include "SimulatorSmoke/NativeSmokeBridge.h"

#include <stdio.h>

static int write_event(FILE *report, const char *event) {
    return fprintf(report, "{\"event\":\"%s\"}\n", event) >= 0 && fflush(report) == 0;
}

static int write_result(FILE *report, const char *event, const char *json) {
    if (!json) {
        return 0;
    }
    for (const char *cursor = json; *cursor != '\0'; cursor++) {
        if (*cursor == '\n' || *cursor == '\r') {
            return 0;
        }
    }
    return fprintf(report, "{\"event\":\"%s\",\"value\":%s}\n", event, json) >= 0 && fflush(report) == 0;
}

static void write_error(FILE *report, const char *stage) {
    (void)fprintf(report, "{\"event\":\"error\",\"stage\":\"%s\"}\n", stage);
    (void)fflush(report);
}

int extera_vosk_native_smoke(const char *model_path, const char *pcm_path, const char *report_path) {
    if (!model_path || !pcm_path || !report_path) {
        return 64;
    }
    FILE *report = fopen(report_path, "wb");
    if (!report) {
        return 65;
    }
    if (!write_event(report, "model_load_started")) {
        fclose(report);
        return 9;
    }

    vosk_set_log_level(-1);
    VoskModel *model = vosk_model_new(model_path);
    if (!model) {
        write_error(report, "model_load");
        fclose(report);
        return 1;
    }
    if (!write_event(report, "model_loaded")) {
        vosk_model_free(model);
        fclose(report);
        return 9;
    }

    VoskRecognizer *recognizer = vosk_recognizer_new(model, 16000);
    if (!recognizer) {
        write_error(report, "recognizer_create");
        vosk_model_free(model);
        fclose(report);
        return 2;
    }
    if (!write_event(report, "recognizer_created")) {
        vosk_recognizer_free(recognizer);
        vosk_model_free(model);
        fclose(report);
        return 9;
    }

    FILE *input = fopen(pcm_path, "rb");
    if (!input) {
        write_error(report, "audio_open");
        vosk_recognizer_free(recognizer);
        vosk_model_free(model);
        fclose(report);
        return 3;
    }

    char bytes[8192];
    size_t count;
    int failure = 0;
    while ((count = fread(bytes, 1, sizeof(bytes), input)) != 0) {
        if (count % 2) { failure = 4; break; }
        int accepted = vosk_recognizer_accept_waveform(recognizer, bytes, (int)count);
        if (accepted < 0) { failure = 5; break; }
        if (accepted == 1 && !write_result(report, "segment", vosk_recognizer_result(recognizer))) {
            failure = 6;
            break;
        }
    }
    if (ferror(input)) failure = 7;
    if (!failure && !write_result(report, "final", vosk_recognizer_final_result(recognizer))) failure = 8;
    if (!failure && !write_event(report, "complete")) failure = 9;
    if (failure) write_error(report, "recognition");

    fclose(input);
    vosk_recognizer_free(recognizer);
    vosk_model_free(model);

    if (fclose(report) != 0 && !failure) failure = 10;
    return failure;
}
