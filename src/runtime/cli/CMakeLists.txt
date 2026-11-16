telar_add_domain(runtime cli
  SOURCES
    server/server.cpp
  DEPS config suggestions platform shell_integration terminal history vocabulary redirect
       traffic proxy plugins runtime)
