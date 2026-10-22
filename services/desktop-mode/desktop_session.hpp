#pragma once

#include "app_state.hpp"
#include "runtime_state.hpp"
#include "native-backends/desktop.hpp"
#include "desktop_registry.hpp"
#include <map>

// Application-thread projection. Native observations and Lua requests enter App through its queue.
class DesktopSession final {
public:
  DesktopSession() = default;
  explicit DesktopSession(std::string runtime_socket);
  using Commands = std::function<bool(DesktopCommand)>;
  // Asks the runtime for a workspace on $HOME and returns the request, whose outcome comes back
  // through reconcile.
  using WorkspaceCreator = std::function<std::uint64_t()>;

  void start(NativeDesktop::Sink observations,
             Commands commands,
             WorkspaceCreator create_workspace = {});
  void stop();
  void apply(DesktopState state);
  void reconcile(const std::vector<WorkspaceSummary> &workspaces,
                 bool ready = true,
                 const WorkspaceCreation &created = {});
  void execute(const DesktopCommand &command);
  const DesktopState &state() const noexcept;
  // What the state being notified differs in from the one notified before it.
  const DesktopChanges &changes() const noexcept;
  std::optional<std::uint64_t> focusedWorkspace() const;
  std::uint64_t subscribe(std::function<void()> callback);
  void unsubscribe(std::uint64_t identifier);
  void activateSpace(std::uint64_t space);
  void bindSpace(std::uint64_t space, std::optional<std::uint64_t> workspace);
  std::uint64_t createSpace(std::uint32_t display, std::optional<std::uint64_t> workspace);
  std::uint64_t removeSpace(std::uint64_t space);
  // A workspace for the focused display.
  std::uint64_t createWorkspace();

private:
  NativeDesktop native_;
  DesktopState state_;
  DesktopState notified_;
  DesktopChanges changes_;
  std::vector<WorkspaceSummary> workspaces_;
  std::map<std::string, std::optional<std::uint64_t>> bindings_;
  std::map<std::uint64_t, std::function<void()>> subscribers_;
  std::uint64_t next_subscription_ = 1;
  Commands commands_;
  WorkspaceCreator create_workspace_;
  // The display each pending workspace creation is for, by request.
  std::map<std::uint64_t, std::uint32_t> creating_;
  // The display each created workspace goes to, until it has a Space there.
  std::map<std::uint64_t, std::uint32_t> placements_;
  bool fill_paused_ = false;

  struct Pending {
    SpaceOperation operation;
    std::optional<std::uint64_t> workspace;
    bool automatic = false;
  };

  std::optional<Pending> pending_;
  std::map<std::string, std::uint64_t> managed_;
  std::uint64_t next_request_ = 1;
  bool automatic_paused_ = false;
  bool runtime_ready_ = false;
  bool associations_restored_ = false;
  std::string persistence_error_;
  std::optional<DesktopRegistry> registry_;

  void associate();
  void synchronizeLifecycle();
  void synchronizeOwnedSpaces();
  void fillDisplays();
  std::uint64_t createWorkspace(std::uint32_t display);
  bool learn(const WorkspaceCreation &created);
  void beginOperation(Pending pending);
  void completeOperation(const SpaceCompletion &completion);
  std::uint32_t focusedDisplay() const;
  bool hasWorkspace(std::uint64_t identifier) const;
  void notify();
  void request(DesktopCommand command);
};
