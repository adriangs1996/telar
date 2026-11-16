telar_add_domain(cli machine
  SOURCES
    machine.cpp
  DEPS base command_limit control_session runtime_observer server integration plugin window
       machine_ssh)
