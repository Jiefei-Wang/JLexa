// Experimental kernel-only test. This does not enable the application backend.
// Reuse the dynamic OpenCL entry points without linking a vendor driver.
#define main capability_probe_main
#include "opencl_capability_probe.c"
#undef main
#include "ggml-quants.h"
#include <math.h>

#define CHECK_CL(call) do { cl_int status = (call); if (status != CL_SUCCESS) { \
    printf("%s failed: %d at line %d\n", #call, status, __LINE__); return 1; } } while (0)
#define SET_ARG(index, value) CHECK_CL(p_clSetKernelArg(kernel, index, sizeof(value), &value))

static __typeof__(&quantize_row_q4_K_ref) quant_q4;
static __typeof__(&quantize_row_q6_K_ref) quant_q6;
static __typeof__(&dequantize_row_q4_K) dequant_q4;
static __typeof__(&dequantize_row_q6_K) dequant_q6;

static char *read_kernel(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    rewind(file);
    char *source = size > 0 ? calloc((size_t)size + 1, 1) : NULL;
    if (source && fread(source, 1, size, file) != (size_t)size) { free(source); source = NULL; }
    fclose(file);
    return source;
}

static int test_matvec(cl_context context, cl_command_queue queue, cl_kernel kernel,
                       int bits, int k, int rows, int columns) {
    const size_t blocks = k / QK_K;
    const size_t row_bytes = blocks * (bits == 4 ? sizeof(block_q4_K) : sizeof(block_q6_K));
    void *weights = calloc(rows, row_bytes);
    float *raw = calloc(k, sizeof(float));
    float *vector = calloc(k * columns, sizeof(float));
    float *output = calloc(rows * columns, sizeof(float));
    float *expected = calloc(rows * columns, sizeof(float));
    if (!weights || !raw || !vector || !output || !expected) return 1;
    for (int i = 0; i < k * columns; ++i) vector[i] = sinf(i * 0.317f + 0.25f);
    for (int row = 0; row < rows; ++row) {
        for (int i = 0; i < k; ++i)
            raw[i] = 3.0f * sinf(i * 0.131f + row * 0.419f) * cosf(i * 0.071f - row * 0.231f);
        void *quant = (char *)weights + row * row_bytes;
        if (bits == 4) { quant_q4(raw, quant, k); dequant_q4(quant, raw, k); }
        else { quant_q6(raw, quant, k); dequant_q6(quant, raw, k); }
        for (int column = 0; column < columns; ++column) {
            double sum = 0;
            for (int i = 0; i < k; ++i) sum += (double)raw[i] * vector[column * k + i];
            expected[column * rows + row] = (float)sum;
        }
    }
    cl_int error;
    cl_mem a = p_clCreateBuffer(context, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
                              rows * row_bytes, weights, &error);
    CHECK_CL(error);
    cl_mem b = p_clCreateBuffer(context, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
                              k * columns * sizeof(float), vector, &error);
    CHECK_CL(error);
    cl_mem result = p_clCreateBuffer(context, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR,
                                    rows * columns * sizeof(float), output, &error);
    CHECK_CL(error);
    int zero = 0, one = 1;
    cl_ulong uzero = 0, nb01 = row_bytes, nb02 = rows * row_bytes, nb03 = nb02;
    cl_ulong nb11 = k * sizeof(float), nb12 = columns * nb11, nb13 = nb12;
    if (bits == 4) {
        SET_ARG(0, a); SET_ARG(1, zero); SET_ARG(2, b); SET_ARG(3, zero);
        SET_ARG(4, result); SET_ARG(5, zero); SET_ARG(6, k); SET_ARG(7, rows);
        SET_ARG(8, nb01); SET_ARG(9, nb02); SET_ARG(10, nb03); SET_ARG(11, one);
        SET_ARG(12, nb11); SET_ARG(13, nb12); SET_ARG(14, nb13);
        SET_ARG(15, rows); SET_ARG(16, columns); SET_ARG(17, one); SET_ARG(18, one);
    } else {
        SET_ARG(0, a); SET_ARG(1, uzero); SET_ARG(2, b); SET_ARG(3, uzero);
        SET_ARG(4, result); SET_ARG(5, uzero); SET_ARG(6, k); SET_ARG(7, rows);
        SET_ARG(8, one); SET_ARG(9, k); SET_ARG(10, one); SET_ARG(11, rows);
        SET_ARG(12, columns); SET_ARG(13, one); SET_ARG(14, one);
    }
    const size_t local[3] = {bits == 4 ? 16 : 32, 1, 1};
    const size_t global[3] = {(size_t)(rows / (bits == 4 ? 4 : 2)) * local[0], (size_t)columns, 1};
    CHECK_CL(p_clEnqueueNDRangeKernel(queue, kernel, 3, NULL, global, local, 0, NULL, NULL));
    CHECK_CL(p_clEnqueueReadBuffer(queue, result, CL_TRUE, 0,
                                  rows * columns * sizeof(float), output, 0, NULL, NULL));
    int failures = 0;
    float max_error = 0, max_scaled_error = 0;
    for (int i = 0; i < rows * columns; ++i) {
        float abs_error = fabsf(output[i] - expected[i]);
        float scaled_error = abs_error / (1.0f + fabsf(expected[i]));
        max_error = fmaxf(max_error, abs_error);
        max_scaled_error = fmaxf(max_scaled_error, scaled_error);
        if (!isfinite(output[i]) || scaled_error > 0.001f) ++failures;
    }
    printf("Mali Q%d_K K=%d rows=%d columns=%d: %s; max_abs=%g max_scaled=%g; first=%g expected=%g\n",
           bits, k, rows, columns, failures ? "FAIL" : "PASS", max_error, max_scaled_error, output[0], expected[0]);
    p_clReleaseMemObject(a); p_clReleaseMemObject(b); p_clReleaseMemObject(result);
    free(weights); free(raw); free(vector); free(output); free(expected);
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    if (argc != 4) { printf("Usage: probe CPU_REFERENCE_LIBRARY Q4_KERNEL Q6_KERNEL\n"); return 1; }
    void *driver = dlopen("libOpenCL.so", RTLD_NOW | RTLD_LOCAL);
    void *reference = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!driver || !reference) { printf("dlopen: %s\n", dlerror()); return 1; }
#define LOAD(name) p_##name = (__typeof__(p_##name))dlsym(driver, #name); if (!p_##name) return 1;
    CL_FUNCTIONS(LOAD)
#undef LOAD
    quant_q4 = (__typeof__(quant_q4))dlsym(reference, "quantize_row_q4_K_ref");
    quant_q6 = (__typeof__(quant_q6))dlsym(reference, "quantize_row_q6_K_ref");
    dequant_q4 = (__typeof__(dequant_q4))dlsym(reference, "dequantize_row_q4_K");
    dequant_q6 = (__typeof__(dequant_q6))dlsym(reference, "dequantize_row_q6_K");
    if (!quant_q4 || !quant_q6 || !dequant_q4 || !dequant_q6) return 1;
    cl_platform_id platform;
    cl_device_id device;
    CHECK_CL(p_clGetPlatformIDs(1, &platform, NULL));
    CHECK_CL(p_clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 1, &device, NULL));
    device_text(device, CL_DEVICE_NAME, "Device");
    cl_int error;
    cl_context context = p_clCreateContext(NULL, 1, &device, NULL, NULL, &error);
    CHECK_CL(error);
    cl_command_queue queue = p_clCreateCommandQueue(context, device, 0, &error);
    CHECK_CL(error);
    int failures = 0;
    for (int bits = 4; bits <= 6; bits += 2) {
        char *source = read_kernel(argv[bits == 4 ? 2 : 3]);
        if (!source) return 1;
        const char *src = source;
        cl_program program = p_clCreateProgramWithSource(context, 1, &src, NULL, &error);
        CHECK_CL(error);
        error = p_clBuildProgram(program, 1, &device, "-cl-std=CL3.0 -DMALI_GPU=1", NULL, NULL);
        printf("Mali Q%d_K kernel build: %d\n", bits, error);
        if (error != CL_SUCCESS) {
            char log[16384] = {0};
            p_clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
            printf("%s\n", log); return 1;
        }
        cl_kernel kernel = p_clCreateKernel(program,
            bits == 4 ? "kernel_mul_mv_q4_K_f32" : "kernel_mul_mv_q6_K_f32", &error);
        CHECK_CL(error);
        const int sizes[] = {256, 1024, 4096};
        for (int i = 0; i < 3; ++i) {
            failures += test_matvec(context, queue, kernel, bits, sizes[i], 8, 1);
            failures += test_matvec(context, queue, kernel, bits, sizes[i], 64, 7);
        }
        p_clReleaseKernel(kernel); p_clReleaseProgram(program); free(source);
    }
    p_clReleaseCommandQueue(queue); p_clReleaseContext(context);
    dlclose(reference); dlclose(driver);
    return failures ? 1 : 0;
}
