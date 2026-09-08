#include "jlexa_speech_host.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <unistd.h>

// argv[1]: SHARED_FD_MODEL fixture; argv[2]: same + FAIL_MODEL fixture.
// Provide the valid fixture as libjlexa_whisper.so on LD_LIBRARY_PATH too.
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char name[] = "speech-host-fd-XXXXXX";
    const int fd = mkstemp(name);
    if (fd < 0) return 3;
    unlink(name);
    const char payload[] = "JLEXAFD1: deterministic shared file descriptor model";
    if (write(fd, payload, sizeof(payload)) != sizeof(payload)) return 4;
    const std::string path = "/proc/self/fd/" + std::to_string(fd);
    auto &host = JLexaSpeechHost::instance();
    auto require = [&](bool ok, const char *message) {
        if (!ok) throw std::runtime_error(std::string(message) + ": " + host.getLastError());
    };
    auto loadAtEof = [&] {
        require(lseek(fd, 0, SEEK_CUR) == sizeof(payload), "fixture must leave owner FD at EOF");
        require(host.loadModel(path), "reload from shared EOF descriptor");
        require(host.isModelLoaded(), "model ready after reload");
        require(lseek(fd, 0, SEEK_CUR) == sizeof(payload), "dup must consume owner's descriptor");
    };
    try {
        host.select(argv[1]);
        for (int i = 0; i < 3; ++i) {
            loadAtEof();
            host.unloadModel();
            require(!host.isModelLoaded(), "unload clears model state");
        }
        std::puts("PASS repeated load/unload with retained SAF descriptor at EOF");
        host.select(argv[2]);
        require(!host.loadModel(path), "failing plugin must fail");
        require(host.getLastError() == "Fixture model load failure", "failure must follow successful header read");
        require(lseek(fd, 0, SEEK_CUR) == sizeof(payload), "failed load must also consume descriptor");
        host.select("");
        loadAtEof();
        std::puts("PASS failed external load then built-in fallback on same descriptor");
        host.unloadModel();
        host.select(argv[1]);
        loadAtEof();
        std::puts("PASS benchmark restoration to original plugin on same descriptor");
        host.unloadModel();
        require(!host.loadModel("/proc/self/fd/999999999999999999999"), "overflow FD rejected");
        require(!host.loadModel(path + "suffix"), "malformed FD rejected");
        int pipeFds[2];
        require(pipe(pipeFds) == 0, "create non-seekable descriptor");
        require(!host.loadModel("/proc/self/fd/" + std::to_string(pipeFds[0])), "non-seekable FD rejected");
        close(pipeFds[0]); close(pipeFds[1]);
        std::puts("PASS invalid and non-seekable descriptor rejection");
        close(fd);
        std::puts("Speech host shared-FD regression: PASS");
        return 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "FAIL %s\n", e.what());
        close(fd);
        return 1;
    }
}
