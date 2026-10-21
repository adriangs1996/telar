#pragma once

#include <memory>

class Shortcuts;

class NativeShortcuts final {
public:
  explicit NativeShortcuts(Shortcuts &shortcuts);
  ~NativeShortcuts();

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
