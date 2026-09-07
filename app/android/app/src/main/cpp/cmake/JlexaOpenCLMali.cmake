include_guard(GLOBAL)

function(jlexa_add_opencl_mali_backend)
    if(NOT ANDROID OR NOT ANDROID_ABI STREQUAL "arm64-v8a")
        return()
    endif()
    include(FetchContent)
    FetchContent_Declare(jlexa_opencl_headers
        GIT_REPOSITORY https://github.com/KhronosGroup/OpenCL-Headers.git
        GIT_TAG c4c8fd6f9556c92b212308880854e6294d61b314)
    FetchContent_GetProperties(jlexa_opencl_headers)
    if(NOT jlexa_opencl_headers_POPULATED)
        FetchContent_Populate(jlexa_opencl_headers)
    endif()
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    set(_generator "${BINDINGS_DIR}/make_opencl_mali_backend.py")
    set(_vendor "${WHISPER_DIR}/ggml/src/ggml-opencl")
    set(_generated "${CMAKE_CURRENT_BINARY_DIR}/jlexa_opencl_mali")
    file(GLOB _kernels CONFIGURE_DEPENDS "${_vendor}/kernels/*.cl")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${_generator}" "${_vendor}/ggml-opencl.cpp"
        "${_vendor}/cl-program-cache.cpp" ${_kernels})
    execute_process(COMMAND "${Python3_EXECUTABLE}" "${_generator}"
        --vendor "${_vendor}" --output "${_generated}"
        RESULT_VARIABLE _result OUTPUT_VARIABLE _output ERROR_VARIABLE _error)
    if(NOT _result EQUAL 0)
        message(FATAL_ERROR "JLexa Mali OpenCL overlay failed: ${_output}${_error}")
    endif()
    add_library(jlexa_opencl_mali STATIC
        "${_generated}/ggml-opencl-mali.cpp"
        "${_generated}/cl-program-cache-mali.cpp"
        "${BINDINGS_DIR}/jlexa_opencl_api.cpp")
    target_include_directories(jlexa_opencl_mali PRIVATE
        "${_generated}" "${_vendor}" "${WHISPER_DIR}/ggml/src"
        "${WHISPER_DIR}/ggml/include" "${BINDINGS_DIR}"
        "${jlexa_opencl_headers_SOURCE_DIR}")
    target_compile_definitions(jlexa_opencl_mali PRIVATE
        GGML_OPENCL_TARGET_VERSION=300 GGML_OPENCL_EMBED_KERNELS)
    target_compile_options(jlexa_opencl_mali PRIVATE -Wno-deprecated-declarations)
    target_link_libraries(jlexa_opencl_mali PRIVATE ggml dl)
    # Only public Khronos headers are fetched. The device driver is optional and
    # opened by name at runtime; no proprietary binary is linked or packaged.
    set(JLEXA_OPENCL_INCLUDE_DIR "${jlexa_opencl_headers_SOURCE_DIR}" PARENT_SCOPE)
endfunction()
