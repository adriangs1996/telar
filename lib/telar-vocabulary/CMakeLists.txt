cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_vocabulary LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

add_library(telar-vocabulary STATIC)
add_library(telar::vocabulary ALIAS telar-vocabulary)
telar_modules(telar-vocabulary)
target_include_directories(telar-vocabulary PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")

telar_editor_flags(telar-vocabulary)
