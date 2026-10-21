#pragma once

namespace ui {
  struct Services;
}

struct AppState;

struct ApplicationHost {
  virtual ~ApplicationHost() = default;
  virtual bool requestExit() = 0;
  virtual bool update() = 0;
  virtual void start() = 0;
  virtual void stop() = 0;
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

  friend int runApplication(ApplicationHost &host,
                            ApplicationWakeup &wakeup,
                            const AppState &state,
                            ui::Services &services);
};

int runApplication(ApplicationHost &host,
                   ApplicationWakeup &wakeup,
                   const AppState &state,
                   ui::Services &services);
