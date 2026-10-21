#pragma once

#include <memory>

class DesktopSession;
class RuntimeSession;
struct ApplicationHost;

class DesktopControl final {
public:
  DesktopControl(ApplicationHost &host, DesktopSession &desktop, RuntimeSession &runtime);
  ~DesktopControl();

  DesktopControl(const DesktopControl &) = delete;
  DesktopControl &operator=(const DesktopControl &) = delete;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
