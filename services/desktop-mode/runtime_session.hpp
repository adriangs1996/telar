#pragma once

#include "runtime_state.hpp"
#include <functional>
#include <memory>
#include <stop_token>
#include <string>
#include <vector>

namespace telar {
  class Client;
}

// The worker owns transport; apply and subscriptions run on the application thread.
class RuntimeSession final {
public:
  // `socket` is the runtime's, for the short connections that create workspaces.
  RuntimeSession(telar::Client &client, std::string socket);
  ~RuntimeSession();

  RuntimeSession(const RuntimeSession &) = delete;
  RuntimeSession &operator=(const RuntimeSession &) = delete;

  void run(std::stop_token stop, const std::function<void(RuntimeState)> &publish);
  void interrupt() noexcept;
  void apply(RuntimeState state);
  const RuntimeState &state() const noexcept;
  std::uint64_t subscribe(std::function<void()> callback);
  void unsubscribe(std::uint64_t identifier);

  // Act on the visible workspace that holds the tab.
  std::uint64_t selectTab(std::uint64_t tab);
  std::uint64_t moveTab(std::uint64_t tab, std::uint64_t relative_to, bool after);
  // Opens a workspace on $HOME with the login shell; the outcome arrives as `created`.
  std::uint64_t createWorkspace();
  // The workspaces on screen, one per display, and the focused one among them.
  void showWorkspaces(std::vector<RuntimeWorkspace> visible,
                      std::optional<RuntimeWorkspace> focused);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
