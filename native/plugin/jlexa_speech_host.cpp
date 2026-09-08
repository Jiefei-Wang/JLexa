#include "jlexa_speech_host.h"
#include "jlexa_speech_plugin.h"
#include <cstring>
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

struct JLexaSpeechHost::Backend {
    void *library = nullptr, *handle = nullptr;
    const jlexa_speech_api *api = nullptr;
    explicit Backend(const std::string &path) {
        if (!path.empty()) {
            int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            Elf64_Ehdr h{}; struct stat st{};
            bool valid = fd >= 0 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
                read(fd, &h, sizeof(h)) == sizeof(h) &&
                !memcmp(h.e_ident, ELFMAG, SELFMAG) &&
                h.e_ident[EI_CLASS] == ELFCLASS64 && h.e_ident[EI_DATA] == ELFDATA2LSB &&
                h.e_machine == EM_AARCH64 && h.e_type == ET_DYN;
            if (fd >= 0) close(fd);
            if (!valid) throw std::runtime_error("Incompatible: expected an arm64-v8a speech plugin.");
            if (st.st_mode & 0222) throw std::runtime_error("Failed: speech plugin must be read-only.");
        }
        library = dlopen(path.empty() ? "libjlexa_whisper.so" : path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!library) throw std::runtime_error(std::string("Failed: dlopen: ") + dlerror());
        try {
            auto entry = reinterpret_cast<const jlexa_speech_api *(*)()>(dlsym(library, "jlexa_speech_plugin_get_api"));
            if (!entry) throw std::runtime_error("Incompatible: missing jlexa_speech_plugin_get_api. Select a Whisper speech plugin, not an LLM plugin.");
            api = entry();
            if (!api || api->abi_version != JLEXA_SPEECH_ABI || api->struct_size < sizeof(jlexa_speech_api))
                throw std::runtime_error("Incompatible: expected JLexa speech API version 1.");
            if (!api->name || !api->engine || !api->version || !api->backend_type ||
                !api->create || !api->destroy || !api->load_model || !api->unload_model ||
                !api->is_model_loaded || !api->transcribe || !api->stop || !api->reset_cancellation)
                throw std::runtime_error("Incompatible: incomplete speech plugin API table.");
            char error[1024]{};
            handle = api->create(error, sizeof(error)); error[1023] = 0;
            if (!handle) throw std::runtime_error(std::string("Failed: speech initialization: ") + error);
        } catch (...) { dlclose(library); library = nullptr; throw; }
    }
    ~Backend() { if (handle) api->destroy(handle); if (library) dlclose(library); }
};
JLexaSpeechHost &JLexaSpeechHost::instance() { static JLexaSpeechHost h; return h; }
std::shared_ptr<JLexaSpeechHost::Backend> JLexaSpeechHost::current() {
    std::lock_guard<std::mutex> l(state);
    if (!active) active = std::make_shared<Backend>("");
    return active;
}
void JLexaSpeechHost::select(const std::string &path) {
    std::lock_guard<std::recursive_mutex> op(operations);
    { std::lock_guard<std::mutex> l(state); active.reset(); }
    auto next = std::make_shared<Backend>(path);
    std::lock_guard<std::mutex> l(state); active = std::move(next);
}
std::vector<std::string> JLexaSpeechHost::pluginInfo() {
    std::lock_guard<std::recursive_mutex> op(operations); auto b = current();
    return {b->api->name, b->api->engine, b->api->version, b->api->backend_type};
}
bool JLexaSpeechHost::loadModel(const std::string &path) {
    std::lock_guard<std::recursive_mutex> op(operations);
    try {
        // SAF adapters may dup() the descriptor, sharing its current offset.
        // Every backend attempt (including fallback and benchmark restoration)
        // must see the beginning of the model, not the end of the last load.
        constexpr const char *prefix = "/proc/self/fd/";
        if (path.compare(0, std::strlen(prefix), prefix) == 0) {
            const char *number = path.c_str() + std::strlen(prefix);
            char *end = nullptr;
            errno = 0;
            const long fd = std::strtol(number, &end, 10);
            if (errno || end == number || *end || fd < 0 || fd > INT_MAX ||
                lseek(static_cast<int>(fd), 0, SEEK_SET) < 0) {
                lastError = "Could not rewind the speech model file descriptor.";
                return false;
            }
        }
        auto b = current(); char error[1024]{};
        int code = b->api->load_model(b->handle, path.c_str(), error, sizeof(error));
        error[1023] = 0; lastError = code ? error : "";
        return code == 0;
    } catch (const std::exception &e) { lastError = e.what(); return false; }
}
void JLexaSpeechHost::unloadModel() {
    std::lock_guard<std::recursive_mutex> op(operations);
    std::shared_ptr<Backend> b; { std::lock_guard<std::mutex> l(state); b = active; }
    if (b) b->api->unload_model(b->handle);
}
bool JLexaSpeechHost::isModelLoaded() {
    std::lock_guard<std::recursive_mutex> op(operations);
    std::shared_ptr<Backend> b; { std::lock_guard<std::mutex> l(state); b = active; }
    return b && b->api->is_model_loaded(b->handle);
}
void JLexaSpeechHost::cancel() {
    std::shared_ptr<Backend> b; { std::lock_guard<std::mutex> l(state); b = active; }
    if (b) b->api->stop(b->handle);
}
void JLexaSpeechHost::resetCancellation() {
    std::lock_guard<std::recursive_mutex> op(operations); auto b = current();
    b->api->reset_cancellation(b->handle);
}
std::string JLexaSpeechHost::getLastError() { std::lock_guard<std::recursive_mutex> op(operations); return lastError; }
std::vector<JLexaAudioSegment> JLexaSpeechHost::transcribe(const float *samples, size_t count,
    int threads, const std::string &language, std::function<void(int)> progress) {
    std::lock_guard<std::recursive_mutex> op(operations);
    std::vector<JLexaAudioSegment> results; lastError.clear();
    struct Call { std::vector<JLexaAudioSegment> &out; std::function<void(int)> &progress; } call{results, progress};
    try {
        if (count > INT32_MAX) throw std::runtime_error("Audio is too long for the speech backend");
        auto b = current(); char error[1024]{};
        int code = b->api->transcribe(b->handle, samples, static_cast<uint32_t>(count), threads, language.c_str(),
            [](void *p, int32_t value) { auto &cb = static_cast<Call *>(p)->progress; if (cb) cb(value); },
            [](void *p, const jlexa_speech_segment *s) {
                if (!s || !s->text || (s->token_count && !s->tokens)) return;
                JLexaAudioSegment result{s->start_ms, s->end_ms, s->text, s->confidence, {}};
                for (uint32_t i = 0; i < s->token_count; ++i) {
                    const auto &t = s->tokens[i];
                    result.tokens.push_back({t.text ? t.text : "", t.start_ms, t.end_ms, t.confidence});
                }
                static_cast<Call *>(p)->out.push_back(std::move(result));
            }, &call, error, sizeof(error));
        error[1023] = 0;
        if (code != 0) results.clear();
        if (code < 0) lastError = error[0] ? error : "Speech backend failed";
    } catch (const std::exception &e) { lastError = e.what(); results.clear(); }
    return results;
}
