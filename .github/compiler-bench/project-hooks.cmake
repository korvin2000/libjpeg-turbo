# CMake hooks for the CI release builds, injected without touching the project's CMakeLists.txt:
#   cmake -DCMAKE_PROJECT_INCLUDE=<this file> -DLJT_LTO_FLAGS="-flto" -DLJT_RELOCATABLE_RPATH=ON ...
# Runs right after project(); the actual work is deferred to the end of the top-level CMakeLists.txt,
# when every target exists:
#   LJT_LTO_FLAGS          link-time optimization for SHARED libraries and EXECUTABLES only. Static and
#                          object libraries keep plain machine code, so the installed static libraries
#                          link with any compiler/linker (LTO objects only link with the same compiler).
#   LJT_RELOCATABLE_RPATH  executables find the shared libraries in ../lib relative to themselves
#                          ($ORIGIN / @loader_path) instead of the absolute install prefix, so an unpacked
#                          release zip works from any directory.

function(_ljt_project_hooks dir)
  get_property(targets DIRECTORY "${dir}" PROPERTY BUILDSYSTEM_TARGETS)
  foreach(t IN LISTS targets)
    get_target_property(type ${t} TYPE)
    if(LJT_LTO_FLAGS AND (type STREQUAL "SHARED_LIBRARY" OR type STREQUAL "EXECUTABLE"))
      separate_arguments(lto UNIX_COMMAND "${LJT_LTO_FLAGS}")
      target_compile_options(${t} PRIVATE ${lto})
      target_link_options(${t} PRIVATE ${lto})
    endif()
    if(LJT_RELOCATABLE_RPATH AND type STREQUAL "EXECUTABLE")
      if(APPLE)
        set_target_properties(${t} PROPERTIES INSTALL_RPATH "@loader_path/../lib")
      elseif(NOT WIN32)
        set_target_properties(${t} PROPERTIES INSTALL_RPATH "\$ORIGIN/../lib")
      endif()
    endif()
  endforeach()
  get_property(subdirs DIRECTORY "${dir}" PROPERTY SUBDIRECTORIES)
  foreach(d IN LISTS subdirs)
    _ljt_project_hooks("${d}")
  endforeach()
endfunction()

if(LJT_LTO_FLAGS OR LJT_RELOCATABLE_RPATH)
  message(STATUS "CI hooks: LTO for shared libs + executables = '${LJT_LTO_FLAGS}', relocatable RPATH = '${LJT_RELOCATABLE_RPATH}'")
  cmake_language(DEFER CALL _ljt_project_hooks "${CMAKE_SOURCE_DIR}")
endif()
