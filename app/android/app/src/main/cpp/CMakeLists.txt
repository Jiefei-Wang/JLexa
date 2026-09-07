cmake_minimum_required(VERSION 3.18)
project("jlexa_native" C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

get_filename_component(JLEXA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." ABSOLUTE)
set(WHISPER_DIR "${JLEXA_ROOT}/native/whisper.cpp")
set(LLAMA_DIR "${JLEXA_ROOT}/native/llama.cpp")
set(BINDINGS_DIR "${JLEXA_ROOT}/native/bindings")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "No tests" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "No examples" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "No tests" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "No examples" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "No server" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "No dynamic backend" FORCE)

# Android's NDK ships Vulkan headers, loader stubs and the host glslc tool.
# Keep x86_64 emulator builds CPU-only; the physical ARM64 build includes the
# backend and still retains the CPU fallback.
if(ANDROID AND ANDROID_ABI STREQUAL "arm64-v8a")
    include(FetchContent)
    FetchContent_Declare(vulkan_headers
        GIT_REPOSITORY https://github.com/KhronosGroup/Vulkan-Headers.git
        GIT_TAG vulkan-sdk-1.3.290.0
        GIT_SHALLOW TRUE)
    FetchContent_GetProperties(vulkan_headers)
    if(NOT vulkan_headers_POPULATED)
        FetchContent_Populate(vulkan_headers)
    endif()
    set(Vulkan_INCLUDE_DIR "${vulkan_headers_SOURCE_DIR}/include" CACHE PATH "Pinned Vulkan-Headers" FORCE)
    if(CMAKE_HOST_WIN32)
        set(Vulkan_GLSLC_EXECUTABLE "${ANDROID_NDK}/shader-tools/windows-x86_64/glslc.exe" CACHE FILEPATH "NDK glslc" FORCE)
    else()
        set(Vulkan_GLSLC_EXECUTABLE "${ANDROID_NDK}/shader-tools/linux-x86_64/glslc" CACHE FILEPATH "NDK glslc" FORCE)
    endif()
    set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan on Android ARM64" FORCE)
    set(SPIRV-Headers_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cmake" CACHE PATH "Bundled NDK SPIR-V headers" FORCE)
    include_directories(SYSTEM
        "${ANDROID_NDK}/sources/third_party/shaderc/third_party/spirv-tools/external/spirv-headers/include")
else()
    set(GGML_VULKAN OFF CACHE BOOL "CPU-only non-ARM64 build" FORCE)
endif()
set(GGML_OPENCL OFF CACHE BOOL "Use the restricted app-owned Mali OpenCL backend" FORCE)

add_subdirectory("${WHISPER_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/whisper_build" EXCLUDE_FROM_ALL)
if(GGML_VULKAN)
    include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/JlexaVulkanCompatibility.cmake")
    jlexa_apply_vulkan_compatibility()
    include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/JlexaVulkanShaderCompatibility.cmake")
    jlexa_apply_vulkan_shader_compatibility(ggml-vulkan)
endif()
add_subdirectory("${LLAMA_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/llama_build" EXCLUDE_FROM_ALL)
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/JlexaOpenCLMali.cmake")
jlexa_add_opencl_mali_backend()

# The host and Whisper never link llama.cpp. Both bundled and imported LLMs
# enter through jlexa_plugin_get_api. Hide engine symbols to prevent ggml interposition.
set(PLUGIN_DIR "${JLEXA_ROOT}/native/plugin")
add_library(jlexa_llama SHARED
    "${PLUGIN_DIR}/llama_plugin.cpp"
    "${BINDINGS_DIR}/jlexa_llama_bridge.cpp")
target_include_directories(jlexa_llama PRIVATE "${PLUGIN_DIR}" "${BINDINGS_DIR}")
target_link_libraries(jlexa_llama PRIVATE llama log)
target_link_options(jlexa_llama PRIVATE "-Wl,--exclude-libs,ALL" "-Wl,-Bsymbolic" "-Wl,--version-script=${PLUGIN_DIR}/exports.map")
set_target_properties(jlexa_llama PROPERTIES CXX_VISIBILITY_PRESET hidden)
if(GGML_VULKAN)
    target_compile_definitions(jlexa_llama PRIVATE JLEXA_HAS_VULKAN=1)
endif()
if(TARGET jlexa_opencl_mali)
    target_link_libraries(jlexa_llama PRIVATE jlexa_opencl_mali)
    target_include_directories(jlexa_llama PRIVATE "${JLEXA_OPENCL_INCLUDE_DIR}")
    target_compile_definitions(jlexa_llama PRIVATE JLEXA_HAS_OPENCL=1)
endif()
add_library(jlexa_native SHARED jlexa_jni.cpp
    "${BINDINGS_DIR}/jlexa_whisper_bridge.cpp"
    "${PLUGIN_DIR}/jlexa_backend_host.cpp")
target_include_directories(jlexa_native PRIVATE "${BINDINGS_DIR}" "${PLUGIN_DIR}")
target_link_libraries(jlexa_native PRIVATE whisper log dl)
target_link_options(jlexa_native PRIVATE "-Wl,--exclude-libs,ALL")
add_dependencies(jlexa_native jlexa_llama)
