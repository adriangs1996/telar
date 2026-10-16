#pragma once

struct ApplicationHost {
  virtual ~ApplicationHost() = default;
  virtual bool requestExit() = 0;
  virtual bool update() = 0;
};

int runApplication(ApplicationHost &host);
