cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_vocabulary LANGUAGES CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

telar_add_library(telar-vocabulary INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include")

telar_editor_flags(telar-vocabulary)
