module;
#include "tbc/annotations.hpp"

export module telar.runtime.core.model.slot_store;

import std;

import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.execution;
import telar.wire.files;
import telar.wire.graphics;
import telar.wire.history;
import telar.wire.layout;
import telar.wire.monitor;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.config.core;
import telar.platform.primitives;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.shell_integration.token;
import telar.base.ds;

// Interface: model/client_role.cppm
export {
  namespace telar::runtime {

    enum class ClientRole : std::uint8_t {
      undecided,
      interactive,
      control,
    };

    // Where a request runs once the runtime's thread decoded its tag. Each lane includes the ones
    // after it: a history request is run by the background service, and every service request is
    // submitted to the background executor.
    enum class RequestLane : std::uint8_t {
      runtime, // handled on the runtime's thread
      worker,  // submitted to the background executor
      service, // run by the background service
      history, // reads or writes the command history
    };

    // `Role` is the role a client takes when this is its first request: it classifies an undecided
    // client and authorizes nothing. A window sends requests listed as control, such as the
    // monitor's, and the services that need a role check it themselves (ClientControl::requireRole).
    template <typename Message, ClientRole Role = ClientRole::interactive, RequestLane Lane = RequestLane::runtime>
    struct ClientRequest {
      using Type = Message;
      static constexpr ClientTag tag = MessageSchema<Message>::tag;
      static constexpr ClientRole role = Role;
      static constexpr RequestLane lane = Lane;
    };

    // Every request a client may send, with what the runtime does with it; dispatch, roles and
    // lanes all derive from this one list.
    // Kept whole: generic over the requests and the caller's consumer, and read on every decoded request.
    template <typename... Requests>
    struct TBC_GENERIC ClientRequestList {
      // Calls `consume.template operator()<Message>()` for the request `tag` names, when its lane is at
      // least `Lane`; false when no such request has that tag. Takes the consumer itself, as the lambdas
      // callers pass build it in place.
      template <RequestLane Lane = RequestLane::runtime, typename Consumer>
      inline static bool dispatch(ClientTag tag, Consumer consume) {
        return (dispatchOne<Lane, Requests>(tag, consume) || ...);
      }

      inline static ClientRole role(ClientTag tag) noexcept {
        return roles[std::to_underlying(tag)];
      }

      inline static RequestLane lane(ClientTag tag) noexcept {
        return lanes[std::to_underlying(tag)];
      }

    private:
      // A request's tag is one byte: one entry for each value it can take.
      static constexpr std::size_t tag_values = 256;

      // Inlined into dispatch, so the compiler sees one chain of tag comparisons and lowers it to a
      // jump table, as the switch it replaces was.
      template <RequestLane Lane, typename Request, typename Consumer>
      [[gnu::always_inline]] inline static bool dispatchOne(ClientTag tag, Consumer& consume) {
        if constexpr (Request::lane < Lane) {
          return false;
        } else {
          if (tag != Request::tag) {
            return false;
          }

          consume.template operator()<typename Request::Type>();
          return true;
        }
      }

      static constexpr auto roles = [] {
        ds::Array<ClientRole, tag_values> result{};

        result.fill(ClientRole::interactive);
        ((result.atMut(std::to_underlying(Requests::tag)) = Requests::role), ...);
        return result;
      }();
      static constexpr auto lanes = [] {
        ds::Array<RequestLane, tag_values> result{};

        result.fill(RequestLane::runtime);
        ((result.atMut(std::to_underlying(Requests::tag)) = Requests::lane), ...);
        return result;
      }();
      static_assert([] {
        ds::Array<bool, tag_values> seen{};

        return ((!std::exchange(seen.atMut(std::to_underlying(Requests::tag)), true)) && ...);
      }(),
          "Two requests share a tag");
      // The wire names every request (clientTagName). One added to ClientTag without joining this
      // list does not compile, where it used to be refused as an unknown tag once a client sent it.
      static_assert([] {
        ds::Array<bool, tag_values> listed{};

        ((listed.atMut(std::to_underlying(Requests::tag)) = true), ...);
        for (std::size_t value = 0; value < tag_values; ++value) {
          if (!clientTagName(static_cast<ClientTag>(value)).empty() && !listed.at(value)) {
            return false;
          }
        }

        return true;
      }(),
          "A request of ClientTag has no entry in the list of requests");
    };

    using ClientRequests = ClientRequestList<
        ClientRequest<ConfigureGraphics>,
        ClientRequest<GraphicsCredit>,
        ClientRequest<RequestGraphicsSnapshot>,
        ClientRequest<OpenPane>,
        ClientRequest<CreatePane>,
        ClientRequest<CreateNvimPane>,
        ClientRequest<NvimInput>,
        ClientRequest<NvimPaste>,
        ClientRequest<NvimMouse>,
        ClientRequest<NvimFocus>,
        ClientRequest<NvimPromptReply>,
        ClientRequest<NvimOpen>,
        ClientRequest<NvimNavigate>,
        ClientRequest<NvimMenuSelect>,
        ClientRequest<NvimBuffers>,
        ClientRequest<NvimPreview>,
        ClientRequest<NvimList>,
        ClientRequest<NvimConfiguration>,
        ClientRequest<ClosePane>,
        ClientRequest<PaneInput>,
        ClientRequest<PaneCommand>,
        ClientRequest<ConfigureShellPrompt>,
        ClientRequest<PaneResize>,
        ClientRequest<FrameAck>,
        ClientRequest<RequestSnapshot>,
        ClientRequest<DetachPane>,
        ClientRequest<RuntimeStop, ClientRole::control>,
        ClientRequest<RequestRuntimeState>,
        ClientRequest<RequestTabSnapshot>,
        ClientRequest<RequestWorkspaceSnapshot>,
        ClientRequest<CreateWorkspace>,
        ClientRequest<RenameWorkspace>,
        ClientRequest<CreateTab>,
        ClientRequest<RenameTab>,
        ClientRequest<CloseTab>,
        ClientRequest<HoldTab>,
        ClientRequest<MoveTab>,
        ClientRequest<ConfigureFrameInterval>,
        ClientRequest<CompleteClipboardDesktop>,
        ClientRequest<ReadRuntimeClipboard>,
        ClientRequest<PastePaneClipboard>,
        ClientRequest<ConfigurePaneDesktop>,
        ClientRequest<ConfigureTerminalColors>,
        ClientRequest<ReadPaneTheme, ClientRole::control>,
        ClientRequest<SearchPane, ClientRole::control>,
        ClientRequest<CopySelection>,
        ClientRequest<ReadPane, ClientRole::control>,
        ClientRequest<SendPaneText, ClientRole::control>,
        ClientRequest<SetPaneViewport>,
        ClientRequest<ReadPaneRows>,
        ClientRequest<SearchPaneRows, ClientRole::control>,
        ClientRequest<QueryClients, ClientRole::control>,
        ClientRequest<DetachClient, ClientRole::control>,
        ClientRequest<RequestClientCommand, ClientRole::control>,
        ClientRequest<CompleteClientCommand>,
        ClientRequest<RequestPaneFocus, ClientRole::control>,
        ClientRequest<CompletePaneFocus>,
        ClientRequest<ShowNotification, ClientRole::control>,
        ClientRequest<UpdateClientLayout>,
        ClientRequest<QueryHistory, ClientRole::control, RequestLane::history>,
        ClientRequest<ImportHistory, ClientRole::control, RequestLane::history>,
        ClientRequest<DeleteHistory, ClientRole::control, RequestLane::history>,
        ClientRequest<PruneHistory, ClientRole::control, RequestLane::history>,
        ClientRequest<ReadHistoryOutput, ClientRole::control, RequestLane::history>,
        ClientRequest<HistoryStatsQuery, ClientRole::control, RequestLane::history>,
        ClientRequest<QueryHistoryWorkspaces, ClientRole::control, RequestLane::history>,
        ClientRequest<ReportLimit, ClientRole::control>,
        ClientRequest<QueryLimits, ClientRole::control>,
        ClientRequest<LaunchTab, ClientRole::control>,
        ClientRequest<RegisterWorktree, ClientRole::control>,
        ClientRequest<LaunchWorktree, ClientRole::control>,
        ClientRequest<ForgetWorktree, ClientRole::control>,
        ClientRequest<ExecutionRequest, ClientRole::control>,
        ClientRequest<VerifyPaneDescent, ClientRole::control>,
        ClientRequest<ReportAgent, ClientRole::control>,
        ClientRequest<ReportAgentTitle, ClientRole::control>,
        ClientRequest<ReportAgentSession, ClientRole::control>,
        ClientRequest<ReportAgentProgress, ClientRole::control>,
        ClientRequest<InterruptAgent, ClientRole::control>,
        ClientRequest<AcknowledgeAgent>,
        ClientRequest<QueryAgents, ClientRole::control>,
        ClientRequest<QueryMonitor, ClientRole::control>,
        ClientRequest<RequestProcessSignal, ClientRole::control>,
        ClientRequest<RequestProcessPriority, ClientRole::control>,
        ClientRequest<ReportAgentCommand, ClientRole::control, RequestLane::service>,
        ClientRequest<FindPaths, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<CompleteWords>,
        ClientRequest<RequestCommandSpec>,
        ClientRequest<OpenEditor, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<FindText, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<ListDirectory, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<MeasureDirectory, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<QueryChanges, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<InspectFile, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<ChangeFiles, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<UndoFileChanges, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<CommitChanges, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<LocateHome, ClientRole::interactive, RequestLane::worker>,
        ClientRequest<SuggestCommand, ClientRole::interactive, RequestLane::worker>>;

    ClientRole classifyRequest(ClientTag tag) noexcept;

    struct PendingClientCommand {
      std::uint64_t target;
      std::uint64_t request_id;
      ClientAction action;
      std::uint64_t target_id;
    };

    struct PendingPaneFocus {
      std::uint64_t target;
      std::uint64_t request_id;
      std::uint64_t pane_id;
      std::uint64_t pane_generation;
    };

  }
}

// Interface: model/exited_panes.cppm
export {
  namespace telar::runtime {

    class ExitedPanes {
    public:
      static constexpr std::size_t capacity = 16;
      static constexpr std::size_t maximum_bytes = std::size_t{16} * 1024;
      static constexpr std::uint16_t kept_rows = 200;

      struct Record {
        std::uint64_t pane_id = 0;
        std::uint64_t generation = 0;
        std::int32_t exit_code = 0;
        ds::Array<char, maximum_bytes> bytes{};
        std::size_t length = 0;
        bool truncated = false;

        [[nodiscard]] PaneText response(const ReadPane& request) const noexcept;
      };

      void record(PaneKey pane, const PaneText& text) noexcept;

      [[nodiscard]] const Record* find(std::uint64_t pane_id, std::uint64_t generation) const noexcept;

    private:
      ds::Array<Record, capacity> entries_{};
      std::size_t next_ = 0;
    };

  }
}

// Interface: model/held_tabs.cppm
export {
  namespace telar::runtime {

    class HeldTabs {
    public:
      static constexpr std::size_t capacity = 64;

      [[nodiscard]] bool contains(TabLocation location) const noexcept;

      bool insert(TabLocation location) noexcept;

      bool erase(TabLocation location) noexcept;

      ds::Option<TabLocation> pop() noexcept;

    private:
      [[nodiscard]] ds::Option<std::size_t> find(TabLocation location) const noexcept;

      ds::Array<TabLocation, capacity> locations_;
      std::size_t count_ = 0;
    };

  }
}

// Interface: model/identity_counter.cppm
export {
  namespace telar::runtime {

    void advanceIdentityCounter(std::uint64_t& counter, std::uint64_t next) noexcept;

  }
}

// Interface: model/pane_launch.cppm
export {
  namespace telar::runtime {

    struct PaneLaunch {
      TerminalSize size;
      MediaBudget& media_budget;
      GraphicsLimits graphics;
      // Present when the pane runs a shell telar integrated with.
      ds::Option<ShellLaunch> shell;
    };

  }
}

// Interface: model/slot_store.cppm
export {
  namespace telar::runtime {

    // Kept whole: a container over the caller's value, from modules that import this one (Pane, Execution...).
    template <typename Value, std::size_t Capacity, Allocator Memory>
    class TBC_GENERIC SlotStore {
      static_assert(Capacity > 0 && Capacity <= std::numeric_limits<std::uint16_t>::max());

    public:
      static constexpr std::size_t capacity = Capacity;

      inline explicit SlotStore(Memory& memory) noexcept
          : memory_(memory) {}

      inline ~SlotStore() {
        for (auto* value : items_) {
          if (value != nullptr) {
            ds::Box<Value, Memory>::fromRaw(value, memory_).reset();
          }
        }
      }

      SlotStore(const SlotStore&) = delete;
      SlotStore& operator=(const SlotStore&) = delete;
      SlotStore(SlotStore&&) = delete;
      SlotStore& operator=(SlotStore&&) = delete;

      [[nodiscard]] inline std::uint64_t nextId() const {
        if (count_ == Capacity || next_id_ == 0) {
          throw std::bad_alloc{};
        }

        return next_id_;
      }

      inline std::uint64_t insert(std::uint64_t id, ds::Box<Value, Memory> value) {
        const auto handle = insertProvisional(id, std::move(value));

        advanceCounter(id + 1);
        return handle;
      }

      inline std::uint64_t insertProvisional(std::uint64_t id, ds::Box<Value, Memory> value) {
        if (id == 0 || count_ == Capacity || find(id) != nullptr) {
          throw std::bad_alloc{};
        }

        std::size_t slot = 0;

        while (items_[slot] != nullptr) {
          ++slot;
        }

        if (generations_[slot] == (std::numeric_limits<std::uint64_t>::max() / Capacity) - 1) {
          throw std::bad_alloc{};
        }

        ++generations_.atMut(slot);
        identities_.atMut(slot) = id;
        lookup_.atMut(bucket(id)) = static_cast<std::uint16_t>(slot + 1);
        items_.atMut(slot) = value.intoRaw();
        ++count_;
        return (generations_[slot] * Capacity) + slot;
      }

      inline Value* findHandle(std::uint64_t handle) const noexcept {
        const auto slot = handle % Capacity;

        return generations_[slot] == handle / Capacity ? items_[slot] : nullptr;
      }

      inline Value* find(std::uint64_t id) const noexcept {
        const auto slot = slotOf(id);

        return slot ? items_[*slot] : nullptr;
      }

      inline void erase(std::uint64_t id) noexcept {
        auto* value = find(id);
        if (value == nullptr) {
          return;
        }

        const auto position = bucket(id);
        const auto slot = lookup_[position] - 1;

        removeBucket(position);
        identities_.atMut(slot) = 0;
        items_.atMut(slot) = nullptr;
        --count_;
        ds::Box<Value, Memory>::fromRaw(value, memory_).reset();
      }

      [[nodiscard]] inline std::size_t size() const noexcept {
        return count_;
      }

      inline void advanceCounter(std::uint64_t next) noexcept {
        advanceIdentityCounter(next_id_, next);
      }

      [[nodiscard]] inline std::uint64_t nextCounter() const noexcept {
        return next_id_;
      }

      inline std::span<Value* const> items() const noexcept {
        return items_;
      }

      [[nodiscard]] inline ds::Option<std::size_t> slotOf(std::uint64_t id) const noexcept {
        const auto stored = id == 0 ? 0 : lookup_[bucket(id)];

        return stored == 0 ? ds::none : ds::Option<std::size_t>{stored - 1};
      }

    private:
      static constexpr std::size_t lookup_capacity = 2 * Capacity;

      inline static std::size_t hash(std::uint64_t identity) noexcept {
        return static_cast<std::size_t>(identity % lookup_capacity);
      }

      [[nodiscard]] inline std::size_t bucket(std::uint64_t identity) const noexcept {
        auto position = hash(identity);

        while (lookup_[position] != 0 && identities_[lookup_[position] - 1] != identity) {
          position = (position + 1) % lookup_capacity;
        }

        return position;
      }

      inline void removeBucket(std::size_t hole) noexcept {
        auto position = (hole + 1) % lookup_capacity;

        while (lookup_[position] != 0) {
          const auto origin = hash(identities_[lookup_[position] - 1]);
          const auto distance = (position + lookup_capacity - origin) % lookup_capacity;
          const auto hole_distance = (hole + lookup_capacity - origin) % lookup_capacity;
          if (hole_distance < distance) {
            lookup_.atMut(hole) = lookup_[position];
            hole = position;
          }

          position = (position + 1) % lookup_capacity;
        }

        lookup_.atMut(hole) = 0;
      }

      Memory& memory_;
      ds::Array<Value*, Capacity> items_{};
      ds::Array<std::uint64_t, Capacity> identities_{};
      ds::Array<std::uint64_t, Capacity> generations_{};
      ds::Array<std::uint16_t, lookup_capacity> lookup_{};
      std::uint64_t next_id_ = 1;
      std::size_t count_ = 0;
    };

  }
}
