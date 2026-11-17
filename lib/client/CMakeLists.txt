# telar-client has no textual headers: the telar_wire/ headers it includes are telar-wire's.
telar_add_library(telar-client
  SOURCES client.cpp
  DEPS telar::base telar::sys telar::vocabulary telar::wire)
