include_guard(GLOBAL)

# CMake helpers for compiling Qt C++23 module units with telar-qt-plugin.so
# and generating Qt 6.12 meta-objects, QML type registrations, and .qmltypes
# with telar-moc (zero Qt moc / zero AUTOMOC).

set(TELAR_QT_PLUGIN "${TELAR_ROOT}/tools/qt_moc/out/release/telar-qt-plugin.so"
  CACHE FILEPATH "Path to telar-qt-plugin.so")
set(TELAR_QT_MOC "${TELAR_ROOT}/tools/qt_moc/out/release/telar-moc"
  CACHE FILEPATH "Path to telar-moc")

if(NOT EXISTS "${TELAR_QT_PLUGIN}" OR NOT EXISTS "${TELAR_QT_MOC}")
  message(FATAL_ERROR
    "telar-qt-plugin.so or telar-moc not found in ${TELAR_ROOT}/tools/qt_moc/out/release/. "
    "Build tools/qt_moc with its release preset (or run tools/cpp configure).")
endif()

# telar-qt-plugin.so is loaded build-wide through telar::build_flags (cmake/TelarBuild.cmake)
# so every C++23 module target shares identical BMI compile flags.
function(telar_enable_qt_plugin target)
endfunction()

# Generates Qt 6.12 meta-object implementation units (*_moc.cpp) for every module interface
# in SOURCES that declares [[qt::object]] or [[qt::ns]], and optionally generates the QML
# type registration unit and .qmltypes file for a QML module.
#
# MODULES_TARGET must be the target that compiles SOURCES as CXX_MODULES so that all BMIs
# and .modmap files exist before telar-moc runs, avoiding any Ninja dependency cycle.
function(telar_add_qt_moc target)
  cmake_parse_arguments(PARSE_ARGV 1 qt_moc ""
    "MODULES_TARGET;QML_URI;QML_MAJOR;QML_MINOR;QML_OUTPUT_DIR;QML_TYPEINFO"
    "SOURCES;FOREIGN_QT_TARGETS")
  if(qt_moc_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_add_qt_moc(${target}): unexpected arguments ${qt_moc_UNPARSED_ARGUMENTS}")
  endif()
  if(NOT qt_moc_MODULES_TARGET)
    message(FATAL_ERROR "telar_add_qt_moc(${target}): MODULES_TARGET is required")
  endif()

  set(gen_dir "${CMAKE_CURRENT_BINARY_DIR}/qt_moc/${target}")
  file(MAKE_DIRECTORY "${gen_dir}")

  set(moc_sources)
  set(meta_jsons)
  set(qml_metas)

  foreach(source IN LISTS qt_moc_SOURCES)
    cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE OUTPUT_VARIABLE abs_source)
    file(STRINGS "${abs_source}" qt_markers REGEX "\\[\\[[^]]*qt::(object|ns)")
    if(NOT qt_markers)
      continue()
    endif()

    file(RELATIVE_PATH rel_source "${CMAKE_CURRENT_SOURCE_DIR}" "${abs_source}")
    string(REGEX REPLACE "[^A-Za-z0-9_]" "_" stem "${rel_source}")
    set(moc_cpp "${gen_dir}/${stem}_moc.cpp")

    set(outputs "${moc_cpp}")
    set(extra_args)
    if(qt_moc_QML_URI)
      set(meta_json "${gen_dir}/${stem}.metatypes.json")
      set(qml_meta "${gen_dir}/${stem}.qmlmeta")
      list(APPEND outputs "${meta_json}" "${qml_meta}")
      list(APPEND extra_args "--json-out=${meta_json}" "--qml-meta-out=${qml_meta}")
      list(APPEND meta_jsons "${meta_json}")
      list(APPEND qml_metas "${qml_meta}")
    endif()

    add_custom_command(
      OUTPUT ${outputs}
      COMMAND "${TELAR_QT_MOC}"
        -p "${CMAKE_BINARY_DIR}"
        --qt-module=telar.gui.qt
        "--moc-out=${moc_cpp}"
        ${extra_args}
        "${abs_source}"
      DEPENDS "${abs_source}" ${qt_moc_MODULES_TARGET} "${TELAR_QT_MOC}"
      COMMENT "telar-moc ${rel_source}"
      VERBATIM)

    set_source_files_properties("${moc_cpp}" PROPERTIES GENERATED TRUE CXX_SCAN_FOR_MODULES ON SKIP_AUTOMOC ON)
    list(APPEND moc_sources "${moc_cpp}")
  endforeach()

  if(moc_sources)
    target_sources(${target} PRIVATE ${moc_sources})
  endif()

  if(qt_moc_QML_URI AND meta_jsons)
    if(NOT qt_moc_QML_MAJOR)
      set(qt_moc_QML_MAJOR 1)
    endif()
    if(NOT qt_moc_QML_MINOR)
      set(qt_moc_QML_MINOR 0)
    endif()
    if(NOT qt_moc_QML_TYPEINFO)
      set(qt_moc_QML_TYPEINFO "${target}.qmltypes")
    endif()

    set(merged_json "${gen_dir}/${target}_metatypes.json")
    set(reg_cpp "${gen_dir}/${target}_qmltyperegistrations.cpp")
    set(qmltypes_file "${qt_moc_QML_OUTPUT_DIR}/${qt_moc_QML_TYPEINFO}")
    set(unused_reg_cpp "${gen_dir}/${target}_unused_qmlreg.cpp")

    add_custom_command(
      OUTPUT "${merged_json}" "${reg_cpp}"
      COMMAND "${TELAR_QT_MOC}"
        --collect
        --qt-module=telar.gui.qt
        "--uri=${qt_moc_QML_URI}"
        "--major=${qt_moc_QML_MAJOR}"
        "--minor=${qt_moc_QML_MINOR}"
        "--merge-json=${merged_json}"
        "--reg-out=${reg_cpp}"
        ${qml_metas}
        ${meta_jsons}
      DEPENDS ${qml_metas} ${meta_jsons} "${TELAR_QT_MOC}"
      COMMENT "telar-moc collect QML metadata for ${target}"
      VERBATIM)

    set_source_files_properties("${reg_cpp}" PROPERTIES GENERATED TRUE CXX_SCAN_FOR_MODULES ON SKIP_AUTOMOC ON)
    target_sources(${target} PRIVATE "${reg_cpp}")

    set(foreign_files)
    file(GLOB qt_metatype_jsons "${TELAR_GUI_QT_PREFIX}/lib/metatypes/qt6*_metatypes.json")
    list(SORT qt_metatype_jsons)
    list(JOIN qt_metatype_jsons "," foreign_arg)
    set(foreign_flag)
    if(foreign_arg)
      set(foreign_flag "--foreign-types=${foreign_arg}")
    endif()

    add_custom_command(
      OUTPUT "${qmltypes_file}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory "${qt_moc_QML_OUTPUT_DIR}"
      COMMAND "$<TARGET_FILE:Qt6::qmltyperegistrar>"
        "--generate-qmltypes=${qmltypes_file}"
        "--import-name=${qt_moc_QML_URI}"
        "--major-version=${qt_moc_QML_MAJOR}"
        "--minor-version=${qt_moc_QML_MINOR}"
        ${foreign_flag}
        -o "${unused_reg_cpp}"
        "${merged_json}"
      DEPENDS "${merged_json}" Qt6::qmltyperegistrar
      COMMENT "Generating ${qt_moc_QML_TYPEINFO} for ${target}"
      VERBATIM)

    add_custom_target(${target}_telar_qmltypes DEPENDS "${qmltypes_file}")
    add_dependencies(${target} ${target}_telar_qmltypes)
    if(TARGET all_qmltyperegistrations)
      add_dependencies(all_qmltyperegistrations ${target}_telar_qmltypes)
    endif()
  endif()
endfunction()

function(_telar_collect_module_deps target out_var visited_var)
  if(NOT TARGET ${target})
    return()
  endif()
  get_target_property(aliased ${target} ALIASED_TARGET)
  if(aliased)
    set(target "${aliased}")
  endif()
  list(FIND ${visited_var} "${target}" seen_idx)
  if(NOT seen_idx EQUAL -1)
    return()
  endif()
  list(APPEND ${visited_var} "${target}")
  get_target_property(ttype ${target} TYPE)
  if(ttype STREQUAL "STATIC_LIBRARY" OR ttype STREQUAL "OBJECT_LIBRARY" OR ttype STREQUAL "SHARED_LIBRARY")
    get_target_property(mod_sets ${target} CXX_MODULE_SETS)
    if(mod_sets)
      list(APPEND ${out_var} "${target}")
    endif()
  endif()
  foreach(prop IN ITEMS LINK_LIBRARIES INTERFACE_LINK_LIBRARIES)
    get_target_property(libs ${target} ${prop})
    if(libs)
      foreach(lib IN LISTS libs)
        string(REGEX REPLACE "^\\$<LINK_ONLY:([^>]+)>$" "\\1" lib "${lib}")
        if(TARGET ${lib})
          _telar_collect_module_deps("${lib}" ${out_var} ${visited_var})
        endif()
      endforeach()
    endif()
  endforeach()
  set(${out_var} "${${out_var}}" PARENT_SCOPE)
  set(${visited_var} "${${visited_var}}" PARENT_SCOPE)
endfunction()

# Generates #include-able <stem>.moc fragments via telar-moc --fragment for QtTest
# translation units that declare [[qt::object]] classes directly inside *_test.cpp.
function(telar_add_qt_test_moc target)
  cmake_parse_arguments(PARSE_ARGV 1 qt_test "" "" "MODULE_DEPS;SOURCES")
  if(qt_test_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "telar_add_qt_test_moc(${target}): unexpected arguments ${qt_test_UNPARSED_ARGUMENTS}")
  endif()

  telar_enable_qt_plugin(${target} PRIVATE)
  set_target_properties(${target} PROPERTIES AUTOMOC OFF AUTOUIC OFF)

  if(NOT qt_test_SOURCES)
    get_target_property(qt_test_SOURCES ${target} SOURCES)
  endif()

  set(auto_deps)
  set(visited)
  _telar_collect_module_deps(${target} auto_deps visited)
  list(APPEND qt_test_MODULE_DEPS ${auto_deps})
  list(REMOVE_DUPLICATES qt_test_MODULE_DEPS)

  set(cxx_mod_args)
  foreach(dep IN LISTS qt_test_MODULE_DEPS)
    if(TARGET ${dep})
      get_target_property(dep_bin ${dep} BINARY_DIR)
      list(APPEND cxx_mod_args "--cxx-modules-json=${dep_bin}/CMakeFiles/${dep}.dir/CXXModules.json")
    endif()
  endforeach()

  set(gen_dir "${CMAKE_CURRENT_BINARY_DIR}/qt_moc/${target}")
  set(added_any FALSE)

  foreach(source IN LISTS qt_test_SOURCES)
    if(source MATCHES "\\$<" OR NOT source MATCHES "\\.cpp$")
      continue()
    endif()
    cmake_path(ABSOLUTE_PATH source BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" NORMALIZE OUTPUT_VARIABLE abs_source)
    if(NOT EXISTS "${abs_source}")
      continue()
    endif()
    file(STRINGS "${abs_source}" qt_markers REGEX "\\[\\[[^]]*qt::(object|ns)")
    if(NOT qt_markers)
      continue()
    endif()

    if(NOT added_any)
      file(MAKE_DIRECTORY "${gen_dir}")
      target_include_directories(${target} PRIVATE "${gen_dir}")
      set(added_any TRUE)
    endif()

    get_filename_component(stem "${abs_source}" NAME_WE)
    set(moc_fragment "${gen_dir}/${stem}.moc")

    add_custom_command(
      OUTPUT "${moc_fragment}"
      COMMAND "${TELAR_QT_MOC}"
        -p "${CMAKE_BINARY_DIR}"
        --fragment
        "--build-root=${CMAKE_BINARY_DIR}"
        ${cxx_mod_args}
        "--moc-out=${moc_fragment}"
        "${abs_source}"
      DEPENDS "${abs_source}" ${qt_test_MODULE_DEPS} "${TELAR_QT_MOC}"
      COMMENT "telar-moc --fragment ${stem}.cpp"
      VERBATIM)

    set_source_files_properties("${moc_fragment}" PROPERTIES GENERATED TRUE HEADER_FILE_ONLY TRUE)
    target_sources(${target} PRIVATE "${moc_fragment}")
    set_property(SOURCE "${abs_source}" TARGET_DIRECTORY ${target} APPEND PROPERTY OBJECT_DEPENDS "${moc_fragment}")
  endforeach()
endfunction()
