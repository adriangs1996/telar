telar_add_domain(runtime server
  EXCLUDE config
  SOURCES
    server/server.cpp
  DEPS server/config suggestions host workers terminal/shell_integration terminal history traffic/tap traffic/redirect
       traffic traffic/proxy plugins core)
