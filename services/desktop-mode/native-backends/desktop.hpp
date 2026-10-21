#pragma once

#include "desktop_state.hpp"
#include <functional>
#include <memory>

class NativeDesktop final {
public:
  using Sink = std::function<bool(DesktopState)>;

  NativeDesktop();
  ~NativeDesktop();
  NativeDesktop(const NativeDesktop &) = delete;
  NativeDesktop &operator=(const NativeDesktop &) = delete;

  void start(Sink publish);
  void stop();
  void activate(std::uint64_t space);
  void changeSpace(SpaceOperation operation);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
