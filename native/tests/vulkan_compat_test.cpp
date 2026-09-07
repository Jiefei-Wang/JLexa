#include "jlexa_vulkan_compat.h"

#include <cassert>
#include <cstdio>

int main() {
    using namespace jlexa;
    assert(isAdreno830(0x5143, "Adreno (TM) 830"));
    assert(!isAdreno830(0x13b5, "Adreno (TM) 830"));
    assert(!isAdreno830(0x5143, "Adreno (TM) 740"));
    assert(!isAdreno830Name("Mali-G78"));
    assert(isQuantizedMatvec("mul_mat_vec_q4_k_f32_f32"));
    assert(isQuantizedMatvec("mul_mat_vec_q6_k_f16_f32"));
    assert(!isQuantizedMatvec("matmul_q4_k_f32"));

    // Two loop hints, one with another control bit/operand, and an unrelated
    // instruction. The rewrite must retain every word except the two masks.
    const std::vector<uint32_t> original = {
        0x07230203, 0x00010300, 0, 20, 0,
        (4u << 16) | 246u, 7, 8, 1,
        (2u << 16) | 17u, 1,
        (5u << 16) | 246u, 10, 11, 9, 6,
    };
    auto expected = original;
    expected[8] = 2;
    expected[14] = 10;
    std::vector<uint32_t> result;
    assert(rollShaderLoops(original.data(), original.size(), result));
    assert(result == expected);
    std::vector<uint32_t> second;
    assert(!rollShaderLoops(result.data(), result.size(), second));
    assert(second == expected);

    auto truncated = original;
    truncated.pop_back();
    assert(!rollShaderLoops(truncated.data(), truncated.size(), result));
    assert(result.empty());
    auto invalid = original;
    invalid[5] = 246;
    assert(!rollShaderLoops(invalid.data(), invalid.size(), result));
    assert(result.empty());
    assert(!rollShaderLoops(nullptr, 0, result));
    std::puts("Vulkan compatibility tests: PASS");
}
