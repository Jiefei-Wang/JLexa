cmake_minimum_required(VERSION 3.22)
project(jlexa_snapdragon LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
get_filename_component(JLEXA_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
option(JLEXA_SNAPDRAGON_OPTIMIZED "Enable guarded dotprod/i8mm CPU kernels" ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
if(JLEXA_SNAPDRAGON_OPTIMIZED)
  set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+i8mm+fp16" CACHE STRING "" FORCE)
else()
  set(GGML_CPU_ARM_ARCH "armv8-a" CACHE STRING "" FORCE)
endif()
# Match the app's pinned shared GGML version and existing FILE* model loader.
add_subdirectory("${JLEXA_ROOT}/native/whisper.cpp" whisper EXCLUDE_FROM_ALL)
add_subdirectory("${JLEXA_ROOT}/native/llama.cpp" llama EXCLUDE_FROM_ALL)
add_library(jlexa_snapdragon SHARED snapdragon_plugin.cpp
  "${JLEXA_ROOT}/native/bindings/jlexa_llama_bridge.cpp")
target_include_directories(jlexa_snapdragon PRIVATE
  "${JLEXA_ROOT}/native/plugin" "${JLEXA_ROOT}/native/bindings")
target_compile_definitions(jlexa_snapdragon PRIVATE
  JLEXA_SNAPDRAGON_OPTIMIZED=$<BOOL:${JLEXA_SNAPDRAGON_OPTIMIZED}>)
target_link_libraries(jlexa_snapdragon PRIVATE llama log)
target_link_options(jlexa_snapdragon PRIVATE "-Wl,--exclude-libs,ALL" "-Wl,-Bsymbolic"
  "-Wl,-z,max-page-size=16384"
  "-Wl,--version-script=${JLEXA_ROOT}/native/plugin/exports.map")
set_target_properties(jlexa_snapdragon PROPERTIES CXX_VISIBILITY_PRESET hidden)
add_library(jlexa_whisper_cpu SHARED
  "${JLEXA_ROOT}/native/plugin/whisper_plugin.cpp"
  "${JLEXA_ROOT}/native/bindings/jlexa_whisper_bridge.cpp")
target_include_directories(jlexa_whisper_cpu PRIVATE
  "${JLEXA_ROOT}/native/plugin" "${JLEXA_ROOT}/native/bindings")
target_compile_definitions(jlexa_whisper_cpu PRIVATE
  JLEXA_WHISPER_OPTIMIZED=$<BOOL:${JLEXA_SNAPDRAGON_OPTIMIZED}>)
target_link_libraries(jlexa_whisper_cpu PRIVATE whisper log)
target_link_options(jlexa_whisper_cpu PRIVATE "-Wl,--exclude-libs,ALL" "-Wl,-Bsymbolic"
  "-Wl,-z,max-page-size=16384"
  "-Wl,--version-script=${JLEXA_ROOT}/native/plugin/speech_exports.map")
set_target_properties(jlexa_whisper_cpu PROPERTIES CXX_VISIBILITY_PRESET hidden)
