#pragma once

#include "app_state.hpp"
#include "native-backends/desktop.hpp"
#include <map>

// Application-thread projection. Native observations and Lua requests enter App through its queue.
class DesktopSession final {
public:
  using Commands = std::function<bool(DesktopCommand)>;

  void start(NativeDesktop::Sink observations, Commands commands);
  void stop();
  void apply(DesktopState state);
  void reconcile(const std::vector<WorkspaceSummary> &workspaces);
  void execute(const DesktopCommand &command);
  const DesktopState &state() const noexcept;
  std::optional<std::uint64_t> focusedWorkspace() const;
  std::uint64_t subscribe(std::function<void()> callback);
  void unsubscribe(std::uint64_t identifier);
  void activateSpace(std::uint64_t space);
  void bindSpace(std::uint64_t space, std::optional<std::uint64_t> workspace);
  std::uint64_t createSpace(std::uint32_t display, std::optional<std::uint64_t> workspace);
  std::uint64_t removeSpace(std::uint64_t space);

private:
  NativeDesktop native_;
  DesktopState state_;
  std::vector<WorkspaceSummary> workspaces_;
  std::map<std::string, std::optional<std::uint64_t>> bindings_;
  std::map<std::uint64_t, std::function<void()>> subscribers_;
  std::uint64_t next_subscription_ = 1;
  Commands commands_;

  struct Pending {
    SpaceOperation operation;
    std::optional<std::uint64_t> workspace;
    bool automatic = false;
  };

  std::optional<Pending> pending_;
  std::map<std::string, std::uint64_t> managed_;
  std::uint64_t next_request_ = 1;
  bool automatic_paused_ = false;

  void associate();
  void synchronizeLifecycle();
  void beginOperation(Pending pending);
  void completeOperation(const SpaceCompletion &completion);
  std::uint32_t focusedDisplay() const;
  bool hasWorkspace(std::uint64_t identifier) const;
  void notify();
  void request(DesktopCommand command);
};
