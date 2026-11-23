telar_add_domain(runtime files
  SOURCES
    content/content.cpp
    directory/directory.cpp
    entry/entry.cpp
    operations/operations.cpp
    repository/repository.cpp
    service/service.cpp
  DEPS transport workers workspaces)

if(BUILD_TESTING)
  telar_add_domain_tests(files LINK telar::base telar::platform telar::wire)
endif()
