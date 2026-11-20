telar_add_domain(runtime cli
  SOURCES
    server/server.cpp
  DEPS config suggestions platform shell_integration terminal history traffic/tap traffic/redirect
       traffic traffic/proxy plugins runtime)
