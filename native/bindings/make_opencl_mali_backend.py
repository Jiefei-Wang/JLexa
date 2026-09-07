"""Build a restricted Mali-G78 OpenCL backend from the pinned GGML source.

Only contiguous Q4_K/Q6_K matmul is admitted. No vendor source is modified.
All other operations stay on CPU; KV offload must remain disabled in the bridge.
"""
from pathlib import Path
import argparse
import hashlib
import re

parser = argparse.ArgumentParser()
parser.add_argument('--vendor', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
base = Path(args.vendor)
out = Path(args.output)
out.mkdir(parents=True, exist_ok=True)

EXPECTED = {
    'ggml-opencl.cpp': '5765d831821c10ac7a92ef696a069afbbf6d78ea8561daee51f51de8c344a3b4',
    'cl-program-cache.cpp': 'f6a15a96350163de97b2c2feb00e5d675f2a9b69fff26b35e516d695b5877efe',
    'kernels/mul_mv_q4_k_f32.cl': '33f27d50ccb006a9d31ab677ac69fab61a39423a8df4f5e55dc17e8f896535b5',
    'kernels/mul_mv_q6_k_f32.cl': '3a672447e9603cb434b956037aaaf1960c81083e21a18594b2719cfce77e012a',
}
for name, expected in EXPECTED.items():
    actual = hashlib.sha256((base / name).read_text(encoding='utf-8').encode()).hexdigest()
    if actual != expected:
        raise RuntimeError(f'JLexa OpenCL overlay: pinned source changed: {name}; review required ({actual})')
src = (base / 'ggml-opencl.cpp').read_text(encoding='utf-8')
src = src.replace('    if (strstr(dev_ctx->device_name.c_str(), "Adreno") ||',
'''    if (dev_ctx->device_name != "Mali-G78" && dev_ctx->device_name.rfind("Mali-G78 ", 0) != 0) return false;
    if (strstr(dev_ctx->device_name.c_str(), "Adreno") ||''')
src = src.replace('    INTEL,\n    UNKNOWN,', '    INTEL,\n    MALI,\n    UNKNOWN,')
src = src.replace('    } else if (strstr(dev_ctx->device_name.c_str(), "Intel")) {',
'''    } else if (dev_ctx->device_name == "Mali-G78" || dev_ctx->device_name.rfind("Mali-G78 ", 0) == 0) {
        dev_ctx->gpu_family = GPU_FAMILY::MALI;
    } else if (strstr(dev_ctx->device_name.c_str(), "Intel")) {''')
# Restrict this experimental backend to two validated matvec paths.
start = src.index('static void load_cl_kernels(ggml_backend_opencl_context *backend_ctx) {')
end = src.index('static ggml_backend_opencl_context * ggml_cl_init', start)
src = src[:start] + '''static void load_cl_kernels(ggml_backend_opencl_context *backend_ctx) {
    if (backend_ctx->kernels_loaded) return;
    cl_int err;
    const std::string opts = "-cl-std=CL3.0 -DMALI_GPU=1";
    const std::string q4 {
        #include "mul_mv_q4_k_f32.cl.h"
    };
    const std::string q6 {
        #include "mul_mv_q6_k_f32.cl.h"
    };
    cl_program p4 = nullptr, p6 = nullptr;
    cl_kernel k4 = nullptr, k6 = nullptr;
    try {
        p4 = build_program_from_source(backend_ctx, q4.c_str(), opts);
        p6 = build_program_from_source(backend_ctx, q6.c_str(), opts);
        CL_CHECK((k4 = clCreateKernel(p4, "kernel_mul_mv_q4_K_f32", &err), err));
        CL_CHECK((k6 = clCreateKernel(p6, "kernel_mul_mv_q6_K_f32", &err), err));
        size_t local4[] = {16, 1, 1}, local6[] = {32, 1, 1}, subgroup4 = 0, subgroup6 = 0;
        CL_CHECK(clGetKernelSubGroupInfo(k4, backend_ctx->device, CL_KERNEL_MAX_SUB_GROUP_SIZE_FOR_NDRANGE,
            sizeof(local4), local4, sizeof(subgroup4), &subgroup4, nullptr));
        CL_CHECK(clGetKernelSubGroupInfo(k6, backend_ctx->device, CL_KERNEL_MAX_SUB_GROUP_SIZE_FOR_NDRANGE,
            sizeof(local6), local6, sizeof(subgroup6), &subgroup6, nullptr));
        if (subgroup4 != 16 || subgroup6 != 16)
            throw std::runtime_error("Experimental Mali OpenCL requires 16-thread kernel subgroups");
    } catch (...) {
        if (k4) clReleaseKernel(k4);
        if (k6) clReleaseKernel(k6);
        if (p4) clReleaseProgram(p4);
        if (p6) clReleaseProgram(p6);
        throw;
    }
    clReleaseProgram(p4); clReleaseProgram(p6);
    backend_ctx->kernel_mul_mv_q4_K_f32 = k4;
    backend_ctx->kernel_mul_mv_q6_K_f32 = k6;
    backend_ctx->kernels_loaded = true;
}

''' + src[end:]
start = src.index('static bool ggml_opencl_supports_op(')
insert = src.index('    // reject ops', start)
src = src[:insert] + '''    if (dev_ctx->gpu_family != MALI) return false;
    if (op->op == GGML_OP_NONE || op->op == GGML_OP_RESHAPE ||
        op->op == GGML_OP_VIEW || op->op == GGML_OP_PERMUTE || op->op == GGML_OP_TRANSPOSE) return true;
    return op->op == GGML_OP_MUL_MAT && op->src[0] && op->src[1] &&
        (op->src[0]->type == GGML_TYPE_Q4_K || op->src[0]->type == GGML_TYPE_Q6_K) &&
        op->src[1]->type == GGML_TYPE_F32 && op->type == GGML_TYPE_F32 &&
        ggml_is_contiguous(op->src[0]) && ggml_is_contiguous(op->src[1]) &&
        op->src[0]->ne[0] % 256 == 0 && op->src[0]->ne[1] % 4 == 0 &&
        op->src[0]->ne[0] <= INT32_MAX && op->src[0]->ne[1] <= INT32_MAX &&
        op->src[1]->ne[1] <= INT32_MAX && ggml_nbytes(op->src[0]) <= INT32_MAX &&
        ggml_nbytes(op->src[1]) <= INT32_MAX && ggml_nbytes(op) <= INT32_MAX &&
        op->src[0]->ne[2] == 1 && op->src[0]->ne[3] == 1 &&
        op->src[1]->ne[2] == 1 && op->src[1]->ne[3] == 1;

''' + src[insert:]
# Use the tested 16-wide work decomposition directly, without enabling an
# Intel/Adreno dispatch family or unvalidated matrix/fusion variants.
start = src.index('static void ggml_cl_mul_mat(ggml_backend_t backend, const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst) {')
end = src.index('\nstatic ', start + 10)
src = src[:start] + '''static void ggml_cl_mul_mat(ggml_backend_t backend, const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst) {
    auto * ctx = (ggml_backend_opencl_context *)backend->context;
    auto * x = (ggml_tensor_extra_cl *)src0->extra;
    auto * y = (ggml_tensor_extra_cl *)src1->extra;
    auto * z = (ggml_tensor_extra_cl *)dst->extra;
    cl_mem a = x->data_device, b = y->data_device, result = z->data_device;
    const bool q4 = src0->type == GGML_TYPE_Q4_K;
    GGML_ASSERT(q4 || src0->type == GGML_TYPE_Q6_K);
    static std::atomic<size_t> dispatch_count{0};
    if (dispatch_count.fetch_add(1) < 2) GGML_LOG_INFO("JLexa Mali OpenCL dispatch: %s [%lld,%lld] x [%lld,%lld]\\n", ggml_type_name(src0->type), (long long)src0->ne[0], (long long)src0->ne[1], (long long)src1->ne[0], (long long)src1->ne[1]);
    cl_kernel kernel = q4 ? ctx->kernel_mul_mv_q4_K_f32 : ctx->kernel_mul_mv_q6_K_f32;
    int k = src0->ne[0], rows = src0->ne[1], columns = src1->ne[1], one = 1;
    cl_ulong ua = x->offset + src0->view_offs, ub = y->offset + src1->view_offs, uz = z->offset + dst->view_offs;
    if (q4 && (ua > INT32_MAX || ub > INT32_MAX || uz > INT32_MAX))
        throw std::runtime_error("Experimental OpenCL Q4_K tensor offset exceeds 2 GiB");
    int ia = ua, ib = ub, iz = uz;
    cl_ulong nb01 = src0->nb[1], nb02 = src0->nb[2], nb03 = src0->nb[3];
    cl_ulong nb11 = src1->nb[1], nb12 = src1->nb[2], nb13 = src1->nb[3];
    #define JLEXA_ARG(index, value) CL_CHECK(clSetKernelArg(kernel, index, sizeof(value), &value))
    if (q4) {
        JLEXA_ARG(0, a); JLEXA_ARG(1, ia); JLEXA_ARG(2, b); JLEXA_ARG(3, ib);
        JLEXA_ARG(4, result); JLEXA_ARG(5, iz); JLEXA_ARG(6, k); JLEXA_ARG(7, rows);
        JLEXA_ARG(8, nb01); JLEXA_ARG(9, nb02); JLEXA_ARG(10, nb03); JLEXA_ARG(11, one);
        JLEXA_ARG(12, nb11); JLEXA_ARG(13, nb12); JLEXA_ARG(14, nb13);
        JLEXA_ARG(15, rows); JLEXA_ARG(16, columns); JLEXA_ARG(17, one); JLEXA_ARG(18, one);
    } else {
        JLEXA_ARG(0, a); JLEXA_ARG(1, ua); JLEXA_ARG(2, b); JLEXA_ARG(3, ub);
        JLEXA_ARG(4, result); JLEXA_ARG(5, uz); JLEXA_ARG(6, k); JLEXA_ARG(7, rows);
        JLEXA_ARG(8, one); JLEXA_ARG(9, k); JLEXA_ARG(10, one); JLEXA_ARG(11, rows);
        JLEXA_ARG(12, columns); JLEXA_ARG(13, one); JLEXA_ARG(14, one);
    }
    #undef JLEXA_ARG
    size_t local[] = {q4 ? 16u : 32u, 1, 1};
    size_t global[] = {(size_t)(rows / (q4 ? 4 : 2)) * local[0], (size_t)columns, 1};
    ctx->enqueue_ndrange_kernel(kernel, 3, global, local, dst);
}
''' + src[end:]
start = src.index('static void ggml_cl_mul_mat_id(ggml_backend_t backend, const ggml_tensor * src0, const ggml_tensor * src1, ggml_tensor * dst) {')
end = src.index('\nstatic ', start + 10)
src = src[:start] + '''static void ggml_cl_mul_mat_id(ggml_backend_t, const ggml_tensor *, const ggml_tensor *, ggml_tensor *) {
    GGML_ABORT("Mali experiment does not support MUL_MAT_ID");
}
''' + src[end:]

# Driver/API failures propagate to the bridge's existing exception handling.
# The full upstream backend aborts/exits on these failures, which is unsuitable
# for an optional backend in a GUI application.
src = src.replace('GGML_ASSERT(0);', 'throw std::runtime_error("OpenCL call failed: " + std::to_string(err_));')
src = src.replace('exit(1);', 'throw std::runtime_error("OpenCL initialization or kernel compilation failed");')
# Cleanup must remain non-throwing, including destructors during stack unwind.
src = re.sub(r'CL_CHECK\((clRelease\w+\([^;\n]+\))\);', r'(void)\1;', src)
src = src.replace('#define CL_TARGET_OPENCL_VERSION GGML_OPENCL_TARGET_VERSION\n', '')
src = re.sub(r'^#pragma message\(.*\)\n', '', src, flags=re.MULTILINE)
cache = (base / 'cl-program-cache.cpp').read_text(encoding='utf-8')
names = sorted(set(re.findall(r'\b(cl[A-Z]\w*)\s*\(', src + cache)))
def dynamic_calls(text):
    text = text.replace('#define CL_TARGET_OPENCL_VERSION GGML_OPENCL_TARGET_VERSION\n', '')
    for name in names:
        # Also replace function references passed to cache query helpers.
        text = re.sub(r'\b' + name + r'\b', 'jlexa_opencl::api().' + name, text)
    return '#include "jlexa_opencl_api.h"\n#include <stdexcept>\n' + text
(out / 'ggml-opencl-mali.cpp').write_text(dynamic_calls(src), encoding='utf-8')
(out / 'cl-program-cache-mali.cpp').write_text(dynamic_calls(cache), encoding='utf-8')

for path in (base / 'kernels').glob('*.cl'):
    body = path.read_text(encoding='utf-8')
    if path.name in ('mul_mv_q4_k_f32.cl', 'mul_mv_q6_k_f32.cl'):
        q4 = 'q4_' in path.name
        needle = '#ifdef INTEL_GPU\n#define N_DST'
        if body.count(needle) != 1:
            raise RuntimeError(f'Kernel branch changed: {path.name}')
        branch = ('#if defined(MALI_GPU)\n#define N_DST ' + ('4' if q4 else '1') +
                  '\n#define N_SIMDGROUP ' + ('1' if q4 else '2') +
                  '\n#define N_SIMDWIDTH 16\n#elif defined(INTEL_GPU)\n#define N_DST')
        body = body.replace(needle, branch)
    if ')JLEXA"' in body:
        raise RuntimeError(f'Unexpected kernel delimiter: {path.name}')
    (out / (path.name + '.h')).write_text('R"JLEXA(' + body + ')JLEXA"', encoding='utf-8')
