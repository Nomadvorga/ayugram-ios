/* Host-test only: never a dependency of an app/iOS target. */
#include "vosk_api.h"
#include <stdlib.h>
VoskModel *vosk_model_new(const char *path) { (void)path; return (VoskModel *)malloc(1); }
void vosk_model_free(VoskModel *model) { free(model); }
VoskRecognizer *vosk_recognizer_new(VoskModel *model, float rate) { (void)model; (void)rate; return (VoskRecognizer *)malloc(1); }
int vosk_recognizer_accept_waveform(VoskRecognizer *r, const char *d, int n) { (void)r; (void)d; (void)n; return 1; }
const char *vosk_recognizer_result(VoskRecognizer *r) { (void)r; return "{\"text\":\"hello\"}"; }
const char *vosk_recognizer_final_result(VoskRecognizer *r) { (void)r; return "{\"text\":\"world\"}"; }
void vosk_recognizer_free(VoskRecognizer *r) { free(r); }
void vosk_set_log_level(int level) { (void)level; }
