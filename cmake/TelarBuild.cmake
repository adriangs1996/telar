include_guard(GLOBAL)

# The settings every telar C++ target builds with: the language standard and module
# scanning, the toolchain gates, the compile job pool, ThinLTO and telar::build_flags.

# The module ABI, diagnostics layouts and toolchain are selected once per build.
# Importers cannot change a compiled interface with their own preprocessor flags.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_SCAN_FOR_MODULES ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
# Module units import std: a textual standard library in every global module
# fragment is serialized into each BMI and merged again by every importer.
set(CMAKE_CXX_MODULE_STD ON)
if(NOT "23" IN_LIST CMAKE_CXX_COMPILER_IMPORT_STD)
  message(FATAL_ERROR "This toolchain cannot provide import std for C++23; configure through tools/cpp so the pinned libc++ and CMake's import std gate are selected")
endif()
option(TELAR_DIAGNOSTICS "Enable allocation and timing diagnostics outside Debug" OFF)
option(TELAR_SANITIZERS "Instrument all owned C++ targets with ASan/UBSan" OFF)

if(NOT CMAKE_GENERATOR STREQUAL "Ninja")
  message(FATAL_ERROR "Telar C++ modules require Ninja; run python3 tools/bootstrap-cpp.py and configure with -G Ninja")
endif()
if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang" OR CMAKE_CXX_COMPILER_VERSION VERSION_LESS 23.1.5)
  message(FATAL_ERROR "Telar requires LLVM Clang 23.1.5 or newer. Use the pinned tools/bootstrap-cpp.py toolchain (AppleClang cannot scan these modules).")
endif()

# Clang reads every transitively imported BMI into its heap, so one translation
# unit commonly peaks at 3-5 GiB. Scheduling by core count alone drives smaller
# machines into swap, which costs far more than the lost parallelism.
cmake_host_system_information(RESULT telar_memory_mib QUERY TOTAL_PHYSICAL_MEMORY)
cmake_host_system_information(RESULT telar_core_count QUERY NUMBER_OF_LOGICAL_CORES)
math(EXPR telar_default_compile_jobs "${telar_memory_mib} / 4096")
if(telar_default_compile_jobs GREATER telar_core_count)
  set(telar_default_compile_jobs ${telar_core_count})
elseif(telar_default_compile_jobs LESS 1)
  set(telar_default_compile_jobs 1)
endif()
set(TELAR_COMPILE_JOBS ${telar_default_compile_jobs} CACHE STRING "Parallel compilations in one build")
set_property(GLOBAL PROPERTY JOB_POOLS telar_compile=${TELAR_COMPILE_JOBS})
set(CMAKE_JOB_POOL_COMPILE telar_compile)

# The warnings every telar process compiles with. A field a designated initializer leaves out is
# value-initialized, which is how this tree asks for a field's default, so only the designated
# variant of -Wmissing-field-initializers is off: a positional initializer still reports a field
# it misses.
set(TELAR_WARNINGS -Wall -Wextra -Wpedantic -Wno-missing-designated-field-initializers)

# The pinned toolchain compiles against its libc++ through CMAKE_CXX_FLAGS, which CMake also hands
# the link step, and links that libc++ itself after -nostdlib++. The driver then reports
# -stdlib=libc++ unused on every link; nothing a link drops is compiled code.
add_link_options("$<$<LINK_LANGUAGE:CXX,OBJCXX>:-Wno-unused-command-line-argument>")

# The build-wide variants every telar target compiles and links with. A library
# passes them on to its importers (telar_modules), so a module interface is
# compiled with the flags of the code that imports it; a target that imports
# none links them itself.
add_library(telar-build-flags INTERFACE)
add_library(telar::build_flags ALIAS telar-build-flags)
set_target_properties(telar-build-flags PROPERTIES EXPORT_NAME build_flags)
target_compile_definitions(telar-build-flags INTERFACE TELAR_DEBUG=$<CONFIG:Debug>
  TELAR_DIAGNOSTICS=$<OR:$<CONFIG:Debug>,$<BOOL:${TELAR_DIAGNOSTICS}>>)
if(TELAR_SANITIZERS)
  target_compile_options(telar-build-flags INTERFACE -fsanitize=address,undefined -fno-omit-frame-pointer)
  target_link_options(telar-build-flags INTERFACE -fsanitize=address,undefined)
endif()

# Optimized builds link with ThinLTO, so a function body can inline into
# callers in other translation units and modules. CMake's IPO compiles with
# -flto=thin and archives with the toolchain's llvm-ar, which indexes the
# bitcode. Managed dependencies stay native objects; their key ignores this.
option(TELAR_THIN_LTO "Link Release and RelWithDebInfo builds with ThinLTO" ON)
if(TELAR_THIN_LTO)
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELWITHDEBINFO ON)
  # Relinking reuses the backend output of every module whose summary did not change.
  set(telar_lto_cache "${CMAKE_BINARY_DIR}/thinlto-cache")
  if(APPLE)
    # Clang passes ld64 its own libLTO, which reads the bitcode it writes.
    add_link_options("$<$<CONFIG:Release,RelWithDebInfo>:-Wl,-cache_path_lto,${telar_lto_cache}>")
  else()
    # GNU ld needs a gold plugin the pinned toolchain does not ship; lld is part of it.
    add_link_options("$<$<CONFIG:Release,RelWithDebInfo>:-fuse-ld=lld;-Wl,--thinlto-cache-dir=${telar_lto_cache}>")
  endif()
endif()
