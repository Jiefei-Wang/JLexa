#ifndef JLEXA_VULKAN_COMPAT_H
#define JLEXA_VULKAN_COMPAT_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace jlexa {

inline bool isAdreno830Name(const std::string& name) {
    return name == "Adreno (TM) 830" || name == "Adreno 830";
}

inline bool isAdreno830(uint32_t vendor, const std::string& name) {
    return vendor == 0x5143 && isAdreno830Name(name);
}

inline bool isQuantizedMatvec(const std::string& name) {
    return name.rfind("mul_mat_vec_q4_k_", 0) == 0 ||
           name.rfind("mul_mat_vec_q6_k_", 0) == 0;
}

// Retain loop bodies on the Adreno 830 compiler instead of expanding the
// quantized matrix/vector shader's runtime-sized nested loops. These are the
// SPIR-V OpLoopMerge opcode and Unroll/DontUnroll masks from spirv.hpp.
inline bool rollShaderLoops(const uint32_t* words, size_t count,
                            std::vector<uint32_t>& output) {
    output.clear();
    if (!words || count < 5 || words[0] != 0x07230203u) return false;
    output.assign(words, words + count);
    bool changed = false;
    for (size_t position = 5; position < count;) {
        const uint32_t instruction = words[position];
        const size_t length = instruction >> 16;
        const uint32_t opcode = instruction & 0xffffu;
        if (length == 0 || length > count - position ||
            (opcode == 246u && length < 4)) {
            output.clear();
            return false;
        }
        if (opcode == 246u) {
            const uint32_t control = (words[position + 3] & ~1u) | 2u;
            changed |= control != words[position + 3];
            output[position + 3] = control;
        }
        position += length;
    }
    return changed;
}

} // namespace jlexa
#endif
