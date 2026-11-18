telar_add_domain(runtime paths
  SOURCES
    query_task/query_task.cpp
  DEPS transport platform)

if(BUILD_TESTING)
  telar_add_domain_tests(paths LINK telar::base telar::platform telar::wire)
endif()
