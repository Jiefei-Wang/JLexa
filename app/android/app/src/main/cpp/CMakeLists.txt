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

add_subdirectory("${WHISPER_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/whisper_build" EXCLUDE_FROM_ALL)
add_subdirectory("${LLAMA_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/llama_build" EXCLUDE_FROM_ALL)

add_library(jlexa_native SHARED
    jlexa_jni.cpp
    "${BINDINGS_DIR}/jlexa_whisper_bridge.cpp"
    "${BINDINGS_DIR}/jlexa_llama_bridge.cpp"
)

target_include_directories(jlexa_native PRIVATE
    "${BINDINGS_DIR}"
    "${WHISPER_DIR}/include"
    "${WHISPER_DIR}/ggml/include"
    "${LLAMA_DIR}/include"
    "${LLAMA_DIR}/ggml/include"
)

target_link_libraries(jlexa_native PRIVATE
    whisper
    llama
    log
)
