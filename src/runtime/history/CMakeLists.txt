telar_add_domain(runtime history
  SOURCES
    directory_keys/directory_keys.cpp
    event/event.cpp
    index/index.cpp
    match_pool/match_pool.cpp
    matching/matching.cpp
    privacy/privacy.cpp
    store/command_stats.cpp
    store/database.cpp
    store/schema.cpp
    store/store.cpp
    store/writers.cpp
  DEPS diagnostics transport host workers)

if(BUILD_TESTING)
  telar_add_domain_tests(history LINK telar::base telar::config telar::platform telar::wire)
endif()
