// Copyright 2020-2021 Alpha Cephei Inc.
// Licensed under the Apache License, Version 2.0.
// https://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.
//
// C ABI subset from alphacep/vosk-api src/vosk_api.h, commit
// 4ab9821510b488efb7740094714a130bd3545e90. Deliberately excludes APIs not needed
// for file transcription. Definitions are checked against the linked archives.
#ifndef EXTERA_VOSK_API_H
#define EXTERA_VOSK_API_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct VoskModel VoskModel;
typedef struct VoskRecognizer VoskRecognizer;
VoskModel *vosk_model_new(const char *model_path);
void vosk_model_free(VoskModel *model);
VoskRecognizer *vosk_recognizer_new(VoskModel *model, float sample_rate);
int vosk_recognizer_accept_waveform(VoskRecognizer *recognizer, const char *data, int length);
const char *vosk_recognizer_result(VoskRecognizer *recognizer);
const char *vosk_recognizer_final_result(VoskRecognizer *recognizer);
void vosk_recognizer_free(VoskRecognizer *recognizer);
void vosk_set_log_level(int log_level);
#ifdef __cplusplus
}
#endif
#endif
