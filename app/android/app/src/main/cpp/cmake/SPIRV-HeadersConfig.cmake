# Android NDK shaderc already bundles the Khronos SPIR-V headers used by its
# glslc executable. ggml only requires this package to be discoverable here.
if(NOT TARGET SPIRV-Headers::SPIRV-Headers)
  add_library(SPIRV-Headers::SPIRV-Headers INTERFACE IMPORTED)
  set_target_properties(SPIRV-Headers::SPIRV-Headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${ANDROID_NDK}/sources/third_party/shaderc/third_party/spirv-tools/external/spirv-headers/include")
endif()
set(SPIRV-Headers_FOUND TRUE)
