#pragma once

struct ApplicationHost {
  virtual ~ApplicationHost() = default;
  virtual bool requestExit() = 0;
  virtual bool update() = 0;
};

struct ApplicationWakeup final {
  ApplicationWakeup(const ApplicationWakeup &) = delete;
  ApplicationWakeup();

  ~ApplicationWakeup();
  ApplicationWakeup &operator=(const ApplicationWakeup &) = delete;

  void wakeup() noexcept;

private:
  struct Impl;
  Impl *impl;

  friend int runApplication(ApplicationHost &host, ApplicationWakeup &wakeup);
};

int runApplication(ApplicationHost &host, ApplicationWakeup &wakeup);
