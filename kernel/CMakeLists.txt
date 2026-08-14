# Embed the kernel from any CMake project: add_subdirectory(kernel) and
# link cue_kernel. One static library, C99, no dependencies — the same two
# files every other build in this repo compiles directly.
cmake_minimum_required(VERSION 3.13)

if(NOT DEFINED PROJECT_NAME)
  project(cue_kernel C)
endif()

add_library(cue_kernel STATIC cue_policy.c)
target_include_directories(cue_kernel PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(cue_kernel PROPERTIES C_STANDARD 99 C_EXTENSIONS OFF)
