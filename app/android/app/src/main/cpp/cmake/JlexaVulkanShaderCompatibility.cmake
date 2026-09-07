# Keep vendor submodules pristine. Generate equivalent Q4_K/Q6_K byte-unpack
# shaders in the build tree: Adreno 830 miscompiles the 8-bit vector conversion.
# Loop-control changes are applied separately, only on the affected device.
function(jlexa_apply_vulkan_shader_compatibility target)
    if(POLICY CMP0116)
        cmake_policy(SET CMP0116 NEW)
    endif()
    if(NOT TARGET "${target}")
        message(FATAL_ERROR "Vulkan shader compatibility requires ${target}")
    endif()
    get_target_property(vulkan_source_dir "${target}" SOURCE_DIR)
    get_target_property(vulkan_binary_dir "${target}" BINARY_DIR)
    get_target_property(vulkan_sources "${target}" SOURCES)
    set(shader_source_dir "${vulkan_source_dir}/vulkan-shaders")
    set(overlay_dir "${CMAKE_CURRENT_BINARY_DIR}/jlexa-vulkan-shaders")
    file(MAKE_DIRECTORY "${overlay_dir}")

    # glslc resolves nested includes relative to the generated shader. Copy
    # dependencies with configure_file so changes also trigger reconfiguration.
    file(GLOB shader_includes CONFIGURE_DEPENDS "${shader_source_dir}/*.glsl")
    foreach(include_file IN LISTS shader_includes)
        get_filename_component(include_name "${include_file}" NAME)
        configure_file("${include_file}" "${overlay_dir}/${include_name}" COPYONLY)
    endforeach()
    file(GLOB generator_sources CONFIGURE_DEPENDS
        "${shader_source_dir}/*.cpp" "${shader_source_dir}/*.h")
    if(CMAKE_HOST_WIN32)
        set(host_suffix ".exe")
    else()
        set(host_suffix "")
    endif()
    set(generator "${CMAKE_BINARY_DIR}/$<CONFIG>/vulkan-shaders-gen${host_suffix}")
    set(shader_header "${vulkan_binary_dir}/ggml-vulkan-shaders.hpp")
    set(layout_anchor "layout(local_size_x_id = 0, local_size_y = 1, local_size_z = 1) in;")
    set(unpack_helper [=[

// Equivalent to unpack8(), without 8-bit arithmetic conversions.
uvec4 jlexa_unpack_bytes(uint value) {
    return (uvec4(value) >> uvec4(0u, 8u, 16u, 24u)) & uvec4(255u);
}
]=])
    set(generated_shaders "")
    foreach(quant IN ITEMS q4_k q6_k)
        set(shader_name "mul_mat_vec_${quant}.comp")
        set(source_shader "${shader_source_dir}/${shader_name}")
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${source_shader}")
        file(READ "${source_shader}" shader)
        # Fail closed when updating GGML: a stale textual overlay must never
        # silently omit this correctness fix or modify an unexpected kernel.
        string(REGEX MATCHALL "unpack8\\(" unpack_calls "${shader}")
        list(LENGTH unpack_calls unpack_count)
        if(quant STREQUAL "q4_k")
            set(expected_unpack_count 6)
        else()
            set(expected_unpack_count 4)
        endif()
        string(FIND "${shader}" "${layout_anchor}" layout_position)
        if(NOT unpack_count EQUAL expected_unpack_count OR layout_position EQUAL -1)
            message(FATAL_ERROR "GGML ${shader_name} changed; review the JLexa Vulkan shader overlay")
        endif()
        string(REPLACE "unpack8(" "jlexa_unpack_bytes(" shader "${shader}")
        string(REPLACE "${layout_anchor}" "${layout_anchor}\n${unpack_helper}" shader "${shader}")
        set(generated_shader "${overlay_dir}/${shader_name}")
        file(CONFIGURE OUTPUT "${generated_shader}" CONTENT "${shader}" @ONLY)
        set(original_cpp "${vulkan_binary_dir}/${shader_name}.cpp")
        list(FIND vulkan_sources "${original_cpp}" source_index)
        if(source_index EQUAL -1)
            message(FATAL_ERROR "Missing expected generated shader source: ${original_cpp}")
        endif()
        list(REMOVE_ITEM vulkan_sources "${original_cpp}")
        set(generated_cpp "${overlay_dir}/${shader_name}.cpp")
        add_custom_command(
            OUTPUT "${generated_cpp}"
            DEPFILE "${generated_cpp}.d"
            COMMAND "${generator}"
                --glslc "${Vulkan_GLSLC_EXECUTABLE}"
                --source "${generated_shader}"
                --output-dir "${overlay_dir}/spv"
                --target-hpp "${shader_header}"
                --target-cpp "${generated_cpp}"
            DEPENDS "${generated_shader}" ${shader_includes} ${generator_sources}
                vulkan-shaders-gen
            COMMENT "Generate JLexa compatible Vulkan shader ${shader_name}"
            VERBATIM)
        set_source_files_properties("${generated_cpp}" TARGET_DIRECTORY "${target}"
            PROPERTIES GENERATED TRUE)
        list(APPEND vulkan_sources "${generated_cpp}")
        list(APPEND generated_shaders "${generated_cpp}")
    endforeach()
    set_property(TARGET "${target}" PROPERTY SOURCES "${vulkan_sources}")
    # Explicit dependency bridges the parent directory's generation rules to
    # the GGML target created in a vendor subdirectory (including clean builds).
    add_custom_target(jlexa-vulkan-compatible-shaders DEPENDS ${generated_shaders})
    add_dependencies("${target}" jlexa-vulkan-compatible-shaders)
endfunction()
