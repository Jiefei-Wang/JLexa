#include "jlexa_speech_plugin.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <vector>
#include <string>
#include <thread>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { std::puts(dlerror()); return 3; }
    auto entry = reinterpret_cast<const jlexa_speech_api *(*)()>(dlsym(library, "jlexa_speech_plugin_get_api"));
    if (!entry) return 4;
    const auto *api = entry();
    if (!api || api->abi_version != 1 || api->struct_size < sizeof(*api)) return 4;
    char error[1024]{}; void *handle = api->create(error, sizeof(error));
    if (!handle) { std::puts(error); return 5; }
    if (api->load_model(handle, argv[2], error, sizeof(error))) { std::puts(error); return 6; }
    std::ifstream input(argv[3], std::ios::binary); char header[44];
    if (!input.read(header, 44) || memcmp(header, "RIFF", 4) || memcmp(header+36, "data", 4)) return 7;
    uint32_t bytes, rate; uint16_t format, channels, bits;
    memcpy(&bytes, header+40, 4); memcpy(&rate, header+24, 4);
    memcpy(&format, header+20, 2); memcpy(&channels, header+22, 2); memcpy(&bits, header+34, 2);
    if (format != 1 || channels != 1 || bits != 16 || rate != 16000 || bytes % 2) return 7;
    std::vector<int16_t> pcm(bytes/2); if (!input.read(reinterpret_cast<char *>(pcm.data()), bytes)) return 8;
    std::vector<float> samples(pcm.size());
    for (size_t i=0; i<pcm.size(); ++i) samples[i] = pcm[i]/32768.0f;
    auto emit = [](void *p, const jlexa_speech_segment *s) { *static_cast<std::string *>(p) += s->text; };
    for (int run=0; run<4; ++run) {
        api->reset_cancellation(handle); std::string text;
        auto start=std::chrono::steady_clock::now();
        int code=api->transcribe(handle, samples.data(), samples.size(), 4, "en", nullptr, emit, &text, error, sizeof(error));
        double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        std::printf("RESULT run=%d ms=%.3f audio_s=%.3f speed=%.3fx code=%d text=%s\n",run,ms,samples.size()/16000.0,samples.size()/16.0/ms,code,text.c_str()); fflush(stdout);
        if (code || text.empty()) { std::puts(error); return 9; }
    }
    api->stop(handle); std::string text;
    if (api->transcribe(handle,samples.data(),samples.size(),4,"en",nullptr,emit,&text,error,sizeof(error)) != 1 || !text.empty()) return 10;
    api->reset_cancellation(handle);
    std::thread stopper([&] { std::this_thread::sleep_for(std::chrono::milliseconds(50)); api->stop(handle); });
    int stopped=api->transcribe(handle,samples.data(),samples.size(),4,"en",nullptr,emit,&text,error,sizeof(error)); stopper.join();
    if (stopped != 1 || !text.empty()) return 11;
    api->reset_cancellation(handle);
    if (api->transcribe(handle,samples.data(),samples.size(),4,"en",nullptr,emit,&text,error,sizeof(error)) || text.empty()) return 12;
    api->unload_model(handle); if (api->is_model_loaded(handle)) return 13;
    api->destroy(handle); dlclose(library);
    std::puts("Speech plugin load/transcribe/stop/reset/unload/destroy: PASS");
}
