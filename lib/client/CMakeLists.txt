# The telar_client/ textual headers are telar-wire's.
telar_add_library(telar-client
  SOURCES client.cpp
  DEPS telar::base telar::sys telar::vocabulary telar::wire)
