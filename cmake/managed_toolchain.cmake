include_guard(GLOBAL)

# For a managed recipe: the toolchain settings telar_managed_build handed it,
# as ExternalProject CMAKE_ARGS whose lists use "|" (pass LIST_SEPARATOR "|").
# What reaches the dependency's build, so its digest is part of every key.
function(telar_forwarded_toolchain result)
  set(arguments)
  foreach(variable IN ITEMS
      CMAKE_C_COMPILER CMAKE_CXX_COMPILER CMAKE_MAKE_PROGRAM
      CMAKE_OBJC_COMPILER CMAKE_OBJCXX_COMPILER CMAKE_OBJC_FLAGS CMAKE_OBJCXX_FLAGS
      CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
      CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET CMAKE_OSX_SYSROOT
      CMAKE_TOOLCHAIN_FILE CMAKE_SYSROOT CMAKE_C_FLAGS CMAKE_CXX_FLAGS
      CMAKE_C_FLAGS_RELEASE CMAKE_CXX_FLAGS_RELEASE)
    if(DEFINED ${variable} AND NOT "${${variable}}" STREQUAL "")
      string(REPLACE ";" "|" value "${${variable}}")
      list(APPEND arguments "-D${variable}:STRING=${value}")
    endif()
  endforeach()

  set(${result} "${arguments}" PARENT_SCOPE)
endfunction()
