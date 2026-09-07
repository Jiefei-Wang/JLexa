include_guard(GLOBAL)

# Keep compatibility changes in the app rather than modifying the vendored
# whisper.cpp checkout. Refuse to silently patch a different upstream revision.
function(_jlexa_vk_replace_once text_variable needle replacement)
    set(_text "${${text_variable}}")
    string(FIND "${_text}" "${needle}" _first)
    if(_first EQUAL -1)
        message(FATAL_ERROR "JLexa Vulkan overlay: expected source fragment is missing")
    endif()
    string(LENGTH "${needle}" _needle_length)
    math(EXPR _after "${_first} + ${_needle_length}")
    string(SUBSTRING "${_text}" ${_after} -1 _tail)
    string(FIND "${_tail}" "${needle}" _second)
    if(NOT _second EQUAL -1)
        message(FATAL_ERROR "JLexa Vulkan overlay: source fragment is ambiguous")
    endif()
    string(REPLACE "${needle}" "${replacement}" _text "${_text}")
    set(${text_variable} "${_text}" PARENT_SCOPE)
endfunction()

function(jlexa_apply_vulkan_compatibility)
    if(NOT TARGET ggml-vulkan)
        return()
    endif()
    get_target_property(_already_applied ggml-vulkan JLEXA_VULKAN_COMPATIBILITY)
    if(_already_applied)
        return()
    endif()

    set(_original "${WHISPER_DIR}/ggml/src/ggml-vulkan/ggml-vulkan.cpp")
    file(READ "${_original}" _source)
    string(REPLACE "\r\n" "\n" _source "${_source}")
    string(SHA256 _source_sha "${_source}")
    # whisper.cpp c4ac0012a8f5a2082dfca6aad4ddfd8b2c02b337, LF normalized.
    if(NOT _source_sha STREQUAL "4f4def9c9ac3d455159aada09a3ff7374b8388ef572d359c8062a502a2fa741d")
        message(FATAL_ERROR
            "JLexa Vulkan overlay requires the pinned, unmodified whisper.cpp Vulkan source. "
            "Review this compatibility overlay when updating the vendor revision. SHA256=${_source_sha}")
    endif()

    _jlexa_vk_replace_once(_source
        [=[#include "ggml-vulkan.h"]=]
        [=[#include "ggml-vulkan.h"
#include "jlexa_vulkan_compat.h"
#include <exception>]=])

    _jlexa_vk_replace_once(_source
        [=[    std::atomic<bool> compiled {};]=]
        [=[    std::atomic<bool> compiled {};
    // A failed compile is terminal for this pipeline on this device. All
    // current and future requesters receive the same failure, never a wait
    // for a compiler that has already exited. Protected by compile_mutex.
    std::exception_ptr compile_error {};]=])

    _jlexa_vk_replace_once(_source
        [=[    pipeline->shader_module = device->device.createShaderModule(shader_module_create_info);]=]
        [=[    // Adreno 830's proprietary compiler miscompiles/fails heavily
    // unrolled quantized matvec kernels. Keep the arithmetic but roll loops.
    if (jlexa::isAdreno830(device->vendor_id, std::string(device->properties.deviceName.data())) &&
        jlexa::isQuantizedMatvec(pipeline->name)) {
        const uint32_t * src = spirv.empty() ? reinterpret_cast<const uint32_t *>(spv_data) : spirv.data();
        const size_t word_count = spirv.empty() ? spv_size / sizeof(uint32_t) : spirv.size();
        std::vector<uint32_t> rolled;
        if (jlexa::rollShaderLoops(src, word_count, rolled)) {
            spirv = std::move(rolled);
            shader_module_create_info = vk::ShaderModuleCreateInfo({}, spirv.size() * sizeof(uint32_t), spirv.data());
        }
    }

    pipeline->shader_module = device->device.createShaderModule(shader_module_create_info);]=])

    _jlexa_vk_replace_once(_source
        [=[            if (pipeline->compiled) {
                continue;
            }

            wait_pipeline = pipeline;]=]
        [=[            if (pipeline->compiled) {
                continue;
            }
            if (pipeline->compile_error) {
                std::rethrow_exception(pipeline->compile_error);
            }

            wait_pipeline = pipeline;]=])

    _jlexa_vk_replace_once(_source
        [=[            if (!pipeline->compile_pending) {
                pipeline->compile_pending = true;
                claimed_task.pipeline = pipeline;]=]
        [=[            if (!pipeline->compile_pending) {
                claimed_task.pipeline = pipeline;]=])

    _jlexa_vk_replace_once(_source
        [=[    // Drop compile_mutex so other threads can walk while we compile.
    compile_lock.unlock();]=]
        [=[    // Publish the claim only after copying task arguments and finishing
    // the walk. An allocation failure above must not leave a pending compiler.
    if (has_claimed_task) {
        claimed_task.pipeline->compile_pending = true;
    }

    // Drop compile_mutex so other threads can walk while we compile.
    compile_lock.unlock();]=])

    _jlexa_vk_replace_once(_source
        [=[        ggml_vk_create_pipeline_func(device, task.pipeline, task.spv_size, task.spv_data,
                                     task.entrypoint, task.parameter_count, task.wg_denoms,
                                     task.specialization_constants, task.disable_robustness,
                                     task.require_full_subgroups, task.required_subgroup_size);]=]
        [=[        try {
            ggml_vk_create_pipeline_func(device, task.pipeline, task.spv_size, task.spv_data,
                                         task.entrypoint, task.parameter_count, task.wg_denoms,
                                         task.specialization_constants, task.disable_robustness,
                                         task.require_full_subgroups, task.required_subgroup_size);
        } catch (...) {
            const std::exception_ptr error = std::current_exception();
            // Failed compiles are not in all_pipelines, so the device's normal
            // teardown cannot release these partially created handles.
            device->device.destroyPipeline(task.pipeline->pipeline);
            device->device.destroyPipelineLayout(task.pipeline->layout);
            device->device.destroyShaderModule(task.pipeline->shader_module);
            task.pipeline->pipeline = nullptr;
            task.pipeline->layout = nullptr;
            task.pipeline->shader_module = nullptr;
            {
                std::lock_guard<std::mutex> guard(device->compile_mutex);
                task.pipeline->compiled = false;
                task.pipeline->compile_error = error;
                task.pipeline->compile_pending = false;
            }
            device->compile_cv.notify_all();
            std::rethrow_exception(error);
        }]=])

    _jlexa_vk_replace_once(_source
        [=[        device->compile_cv.wait(wait_lock, [&] {
            return wait_pipeline->compiled.load();
        });]=]
        [=[        device->compile_cv.wait(wait_lock, [&] {
            return wait_pipeline->compiled.load() || wait_pipeline->compile_error;
        });
        if (wait_pipeline->compile_error) {
            std::rethrow_exception(wait_pipeline->compile_error);
        }]=])

    set(_generated "${CMAKE_CURRENT_BINARY_DIR}/jlexa-ggml-vulkan.cpp")
    # Avoid changing the timestamp (and recompiling) on an identical configure.
    set(_write_generated TRUE)
    if(EXISTS "${_generated}")
        file(READ "${_generated}" _existing)
        if(_existing STREQUAL _source)
            set(_write_generated FALSE)
        endif()
    endif()
    if(_write_generated)
        file(WRITE "${_generated}" "${_source}")
    endif()

    get_target_property(_target_directory ggml-vulkan SOURCE_DIR)
    get_target_property(_target_sources ggml-vulkan SOURCES)
    set(_sources)
    set(_replaced 0)
    foreach(_entry IN LISTS _target_sources)
        if(_entry MATCHES "(^|/)ggml-vulkan\\.cpp$")
            get_filename_component(_entry_absolute "${_entry}" ABSOLUTE BASE_DIR "${_target_directory}")
            get_filename_component(_original_absolute "${_original}" ABSOLUTE)
            if(NOT _entry_absolute STREQUAL _original_absolute)
                message(FATAL_ERROR "JLexa Vulkan overlay: unexpected ggml-vulkan source ${_entry_absolute}")
            endif()
            list(APPEND _sources "${_generated}")
            math(EXPR _replaced "${_replaced} + 1")
        else()
            list(APPEND _sources "${_entry}")
        endif()
    endforeach()
    if(NOT _replaced EQUAL 1)
        message(FATAL_ERROR "JLexa Vulkan overlay: expected exactly one ggml-vulkan.cpp source, found ${_replaced}")
    endif()
    set_property(TARGET ggml-vulkan PROPERTY SOURCES "${_sources}")
    target_include_directories(ggml-vulkan PRIVATE "${BINDINGS_DIR}")
    set_property(TARGET ggml-vulkan PROPERTY JLEXA_VULKAN_COMPATIBILITY TRUE)
    message(STATUS "JLexa Vulkan compatibility overlay enabled")
endfunction()
