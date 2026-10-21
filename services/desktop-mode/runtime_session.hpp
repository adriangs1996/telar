#pragma once

#include "runtime_state.hpp"
#include <functional>
#include <memory>
#include <stop_token>

namespace telar {
  class Client;
}

// The worker owns transport; apply and subscriptions run on the application thread.
class RuntimeSession final {
public:
  explicit RuntimeSession(telar::Client &client);
  ~RuntimeSession();

  RuntimeSession(const RuntimeSession &) = delete;
  RuntimeSession &operator=(const RuntimeSession &) = delete;

  void run(std::stop_token stop, const std::function<void(RuntimeState)> &publish);
  void interrupt() noexcept;
  void apply(RuntimeState state);
  const RuntimeState &state() const noexcept;
  std::uint64_t subscribe(std::function<void()> callback);
  void unsubscribe(std::uint64_t identifier);

  std::uint64_t selectTab(std::uint64_t tab);
  std::uint64_t moveTab(std::uint64_t tab, std::uint64_t relative_to, bool after);
  void selectWorkspace(std::optional<RuntimeWorkspace> workspace);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
