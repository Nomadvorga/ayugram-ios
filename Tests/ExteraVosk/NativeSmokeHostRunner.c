/* Test-only CLI adapter for the callable smoke function; linked only with NativeHostStub.c. */
#include "SimulatorSmoke/NativeSmokeBridge.h"

int main(int argc, char **argv) {
    if (argc != 4) {
        return 64;
    }
    return extera_vosk_native_smoke(argv[1], argv[2], argv[3]);
}
