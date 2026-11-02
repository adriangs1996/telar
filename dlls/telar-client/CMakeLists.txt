cmake_minimum_required(VERSION 3.24)
project(telar_client LANGUAGES CXX)

add_library(telar-client INTERFACE)
add_library(telar::client ALIAS telar-client)
target_compile_features(telar-client INTERFACE cxx_std_23)
target_include_directories(telar-client INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
