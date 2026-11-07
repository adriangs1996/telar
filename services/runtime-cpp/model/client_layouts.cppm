module;
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <type_traits>
#include <ghostty/vt.h>
#include <source_location>
#include <sys/stat.h>
#include <stdlib.h>
#include <zlib.h>

#include <array>
#include <span>
#include <sys/types.h>
#include <chrono>
#include <cstdint>
#include <bit>
#include <concepts>
#include <stdexcept>
#include <variant>
#include <cassert>
#include <cstring>
#include <exception>
#include <cstddef>
#include <cerrno>
#include <algorithm>
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include <utility>
#include <charconv>
#include <limits>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include <unistd.h>
#include "cell_layout.hpp"
#include <tuple>

#include <memory>
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>

export module telar.runtime.model.client_layouts;

export import telar.runtime.agents.description_generator;
export import telar.runtime.graphics.synchronizer;
export import telar.runtime.platform.process_probe;
export import telar.runtime.terminal.osc_scanner;
export import telar.runtime.terminal.text_reader;
export import telar.runtime.transport.connection;
export import telar.runtime.model.slot_store;


export import telar.runtime.agents.screen_inference;
export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.graphics.pane_media;
export import telar.runtime.observation.processor;
export import telar.runtime.persistence.launch_record;
export import telar.base.memory;
export import telar.platform;


export import telar.base.diagnostics;


export import telar.client;


export import telar.config;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: model/pending_clipboard.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class PendingClipboard {
public:
  static constexpr std::size_t capacity = 1024 * 1024;

  inline explicit PendingClipboard(Memory &memory) : bytes_(AllocatorRef<Byte, Memory>{memory}) {}

  inline void replace(std::uint64_t pane, std::span<const Byte> bytes) {
    if (bytes.size() > capacity) {
      throw EncodingError{"Selection exceeds the clipboard limit"};
    }

    Vector<Byte, Memory> replacement{bytes.begin(), bytes.end(), bytes_.get_allocator()};
    bytes_.swap(replacement);
    pane_ = pane;
    pending_ = true;
  }

  inline bool pending() const noexcept { return pending_; }
  inline PaneClipboard message() const noexcept { return {.pane_id = pane_, .bytes = bytes_}; }
  inline void delivered() noexcept { pending_ = false; }

private:
  Vector<Byte, Memory> bytes_;
  std::uint64_t pane_ = 0;
  bool pending_ = false;
};

}
}

// Interface: model/client.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
struct Attachment {
  inline explicit Attachment(Memory &memory, GraphicsCreditBudget &budget, std::uint64_t pane, std::shared_ptr<PaneMedia<Memory>> media)
      : pane_id(pane),
        frames(memory, pane),
        graphics(budget, pane, std::move(media)) {}

  std::uint64_t pane_id;
  std::size_t slot = 0;
  FrameSync<Memory> frames;
  GraphicsSynchronizer<Memory> graphics;
  std::optional<std::uint32_t> viewport;
  std::optional<ConfigurePaneDesktop> desktop;
  bool exit_sent = false;
  std::uint64_t title_revision = 1;
  std::uint64_t cwd_revision = 0;
  std::uint64_t clipboard_revision = 0;
  std::uint64_t foreground_revision = 0;
  std::uint64_t progress_revision = 1;
  FramePacer pacer;
};

template <Allocator Memory>
class ClientSession {
public:
  static constexpr std::size_t attachment_capacity = 64;

  struct ForegroundStamp {
    std::uint64_t pane = 0;
    std::uint64_t revision = 0;
  };

  inline explicit ClientSession(Memory &memory, std::uint64_t identity, FileDescriptor descriptor)
      : id(identity),
        generation(identity),
        connection(memory, std::move(descriptor)),
        attachments(AllocatorRef<Owned<Attachment<Memory>, Memory>, Memory>{memory}),
        clipboard(memory),
        deferred_report(memory) {
    attachments.reserve(attachment_capacity);
  }

  inline std::size_t availableAttachmentSlot() const {
    std::uint64_t occupied = 0;
    for (const auto &entry : attachments) {
      occupied |= std::uint64_t{1} << entry->slot;
    }

    if (occupied == UINT64_MAX) {
      throw std::bad_alloc{};
    }
    return std::countr_zero(~occupied);
  }

  inline Attachment<Memory> *attachment(std::uint64_t pane_id) const noexcept {
    for (const auto &entry : attachments) {
      if (entry->pane_id == pane_id) {
        return entry.get();
      }
    }

    return nullptr;
  }

  std::uint64_t id;
  std::uint64_t generation;
  std::uint64_t event_identity = 0;
  std::uint64_t identity = 0;
  GraphicsCreditBudget graphics_credit;
  ClientRole role = ClientRole::undecided;
  std::uint64_t last_input_pane = 0;
  std::uint64_t last_input_sequence = 0;
  std::optional<PendingClientCommand> pending_command;
  std::optional<PendingPaneFocus> pending_focus;
  Connection<Memory> connection;
  Vector<Owned<Attachment<Memory>, Memory>, Memory> attachments;
  PendingClipboard<Memory> clipboard;
  std::size_t next_attachment = 0;
  std::optional<std::uint64_t> completing_exit;
  bool layout_sent = false;
  bool proxy_status_sent = false;
  bool agent_snapshot_requested = false;
  bool subscribed = false;
  bool interactive = false;
  bool shared_graphics = false;
  std::uint64_t editor_source = 0;
  std::uint64_t editor_generation = 0;
  std::optional<ProcessIdentity> peer_identity;
  std::uint64_t agent_revision = 0;
  std::uint64_t metrics_revision = 0;
  std::uint64_t verified_pane = 0;
  std::uint64_t verified_generation = 0;
  ProcessLineage verified_lineage;
  std::optional<DescentCheck> pending_descent;
  bool descent_running = false;
  DeferredReport<Memory> deferred_report;
  unsigned limit_reports = 0;
  std::chrono::steady_clock::time_point limit_report_window{};
  std::optional<std::uint64_t> workspace;
  std::chrono::nanoseconds frame_interval{1'000'000'000 / 60};
  std::uint64_t workspace_revision = 0;
  std::uint64_t agent_workspace_revision = 0;
  std::optional<ResyncRequired> workspace_resync;
  std::array<ForegroundStamp, 256> foregrounds;
  std::optional<TextSearch> search;
  ConfigureTerminalColors colors{};
  HeldTabs held_tabs;
};

}
}

// Interface: model/pane.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class Pane {
  struct ResponseWriter {
    inline ssize_t operator()(int descriptor, std::span<const iovec> vectors) const {
      return ::writev(descriptor, vectors.data(), static_cast<int>(vectors.size()));
    }
  };

public:
  enum class ReadMode {
    once,
    burst
  };

  inline explicit Pane(Memory &memory, std::uint64_t identity, TabLocation location, Command<Memory> &command, PaneLaunch settings)
      : id(identity),
        location(location),
        launch(memory),
        pty_responses(std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        observer(std::allocate_shared<PaneObserver<Memory>>(AllocatorRef<PaneObserver<Memory>, Memory>{memory}, memory, settings.size, command.cwd())),
        media(std::allocate_shared<PaneMedia<Memory>>(AllocatorRef<PaneMedia<Memory>, Memory>{memory}, memory, settings.media_budget, settings.graphics, settings.size, pty_responses)),
        terminal(memory, settings.size, TerminalPurpose::separate_media, pty_responses, GraphicsQueryResources{settings.graphics, settings.media_budget, &media->queryUsage()}),
        input(memory, input_limit),
        cwd(command.cwd(), AllocatorRef<char, Memory>{memory}) {
    randomBytes(history_session.data(), history_session.size());
    input.reserve(input_limit);
    launch.capture(command.arguments(), command.restorable());
    const auto executable = std::string_view{command.arguments().front()};
    foreground.assign(utf8Prefix(executable.substr(executable.rfind('/') + 1), 48));
    process.emplace(command.specification(settings.size));
    terminal.attachMedia(*media);
  }

  inline bool read(ReadMode mode = ReadMode::once) {
    constexpr std::size_t batch_byte_limit = 64 * 1024;
    constexpr unsigned batch_read_limit = 8;
    std::array<Byte, read_buffer_size> buffer;
    std::size_t batch_bytes = 0;
    const unsigned read_limit = mode == ReadMode::burst ? batch_read_limit : 1;
    for (unsigned attempt = 0; attempt < read_limit && batch_bytes < batch_byte_limit; ++attempt) {
      const auto capacity = std::min(buffer.size(), batch_byte_limit - batch_bytes);
      if (terminal.hasPendingControl() || media->holdsRead(capacity)) {
        TELAR_DIAGNOSTIC(media->noteHeldRead());
        return true;
      }

      const auto count = ::read(process->descriptor(), buffer.data(), capacity);
      if (count > 0) {
        const auto bytes = std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count));
        TELAR_DIAGNOSTIC(recordRead(bytes.size(), batch_bytes != 0));
        const auto foreground = needs_foreground_observation ? shellForeground() : std::nullopt;
        expireProgress(foreground);
        observer->bytes(ObservationKind::output, bytes, foreground);
        {
          TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters == nullptr ? nullptr : &counters->ingest});
          terminal.feed(bytes);
        }
        batch_bytes += bytes.size();
        continue;
      }

      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        return true;
      }

      output_closed = true;
      terminal.abortControl();
      return false;
    }

    return true;
  }

  // The response writer borrows vectors only for this call. Only a positive
  // syscall result consumes the admitted prefix; EINTR/EAGAIN retain it.
  template <typename WriteResponses = ResponseWriter>
  inline void write(WriteResponses write_responses = {}) {
    const auto batch = pty_responses->peekBatch();
    const bool response = batch.count != 0;
    const auto bytes = input.readable();
    if (response && batch.bytes == 0) {
      pty_responses->consumeBytes(0);
      terminal.resumeControl();
      return;
    }
    if (!response && bytes.empty()) {
      return;
    }

    const auto count = [&] {
      TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters == nullptr ? nullptr : &counters->input_write});
      if (response) {
        std::array<iovec, PtyResponseQueue::message_capacity> vectors;
        for (std::size_t index = 0; index < batch.count; ++index) {
          const auto message = batch.message(index);
          vectors[index] = {const_cast<Byte *>(message.data()), message.size()};
        }
        return write_responses(process->descriptor(), std::span<const iovec>{vectors}.first(batch.count));
      }
      return ::write(process->descriptor(), bytes.data(), bytes.size());
    }();
    if (count > 0) {
      if (response) {
        pty_responses->consumeBytes(static_cast<std::size_t>(count));
        terminal.resumeControl();
      } else {
        input.consume(static_cast<std::size_t>(count));
      }

      return;
    }

    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return;
    }

    input.clear();
    pty_responses->clear();
    throw std::system_error{count < 0 ? errno : EIO, std::generic_category(), "PTY write failed"};
  }

  inline bool hasInput() const noexcept {
    return !input.empty() || !pty_responses->empty();
  }

  inline void requestClose() noexcept {
    if (close_requested) {
      return;
    }

    close_requested = true;
    process->shutdown();
  }

  inline void enqueueInput(std::span<const Byte> bytes) {
    input.append(bytes);
    TELAR_DIAGNOSTIC(if (counters != nullptr) {
      diagnostics::accumulate(counters->input_events);
      diagnostics::accumulate(counters->input_bytes, bytes.size());
    });
    observer->bytes(ObservationKind::input, bytes, shellForeground());
    ++input_revision;
    needs_foreground_observation = true;
  }

  inline void resize(TerminalSize size) {
    if (terminal.hasSize(size)) {
      return;
    }

    terminal.resize(size);
    process->resize(size);
    observer->resize(size);
    media->resize(size);
  }

  inline std::optional<bool> shellForeground() const noexcept {
    if (shell_markers) {
      return std::nullopt;
    }

    const auto foreground = process->foregroundProcessGroup();
    return foreground ? std::optional<bool>{*foreground == process->processId()} : std::nullopt;
  }

  inline std::optional<std::int32_t> exitCode() const noexcept {
    if (!exit_status) {
      return std::nullopt;
    }

    if (WIFEXITED(*exit_status)) {
      return WEXITSTATUS(*exit_status);
    }

    constexpr int signal_exit_offset = 128;
    return signal_exit_offset + WTERMSIG(*exit_status);
  }

  static constexpr std::size_t input_limit = 128 * 1024;
  static constexpr std::size_t read_buffer_size = 16 * 1024;
#if TELAR_DIAGNOSTICS
  diagnostics::PaneCounters *counters = nullptr;
  std::uint64_t input_dropped_bytes = 0;
#endif
  std::uint64_t id;
  std::uint64_t event_identity = 0;
  std::optional<ConfigurePaneDesktop> desktop_theme;
  std::uint64_t generation = 1;
  std::array<Byte, 16> history_session;
  TabLocation location;
  LaunchRecord<Memory> launch;
  std::optional<AgentResume> restored_agent;
  std::shared_ptr<PtyResponseQueue> pty_responses;
  std::shared_ptr<PaneObserver<Memory>> observer;
  std::shared_ptr<PaneMedia<Memory>> media;
  Terminal<Memory> terminal;
  ByteQueue<Memory> input;
  String<Memory> cwd;
  std::optional<PtyProcess> process;
  std::uint32_t observers = 0;
  std::uint64_t cwd_revision = 0;
  std::optional<std::uint64_t> worktree_checked_cwd;
  std::uint64_t input_revision = 0;
  FixedText<48> foreground;
  std::uint64_t foreground_revision = 1;
  bool output_closed = false;
  bool exit_published = false;
  bool exit_observed = false;
  bool shell_markers = false;
  bool needs_foreground_observation = false;
  bool write_interest = false;
  bool read_paused = false;
  std::optional<int> exit_status;
  std::chrono::steady_clock::time_point sync_started{};
  std::optional<std::chrono::steady_clock::time_point> last_input;
  bool close_requested = false;
  ProcessCache process_cache;
  std::uint32_t process_rechecks = 0;
  bool process_recheck_requested = false;
  bool process_recheck_running = false;
  std::optional<RejectedReporter> rejected_reporter;

private:
  inline void expireProgress(std::optional<bool> shell_foreground) noexcept {
    if (terminal.effects.progress_state == PaneProgressState::remove) {
      return;
    }

    if (!shell_foreground) {
      const auto group = process->foregroundProcessGroup();
      shell_foreground = group && *group == process->processId();
    }
    if (*shell_foreground) {
      terminal.effects.setProgress(PaneProgressState::remove, std::nullopt);
    }
  }

#if TELAR_DIAGNOSTICS
  inline void recordRead(std::size_t size, bool folded) noexcept {
    if (counters == nullptr) {
      return;
    }

    diagnostics::accumulate(counters->pty_events);
    diagnostics::accumulate(counters->pty_bytes, size);
    diagnostics::accumulate(counters->folded_pty_events, folded);
  }
#endif
};

}
}

// Interface: model/runtime_limits.cppm
export {
namespace telar::runtime {

struct RuntimeLimits {
  LimitLedger runtime;
  LimitLedger clients;
  std::uint64_t refused_reports = 0;
};

}
}

// Interface: model/workspace.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
struct Tab {
  inline explicit Tab(Memory &memory, std::uint64_t identity, std::string_view name)
      : id(identity),
        label(name, AllocatorRef<char, Memory>{memory}),
        panes(AllocatorRef<std::uint64_t, Memory>{memory}) {
    panes.reserve(64);
  }

  std::uint64_t id;
  String<Memory> label;
  Vector<std::uint64_t, Memory> panes;
};

template <Allocator Memory>
class Workspace {
public:
  inline explicit Workspace(Memory &memory, std::uint64_t identity, std::string_view directory, std::string_view label)
      : id(identity),
        path(directory, AllocatorRef<char, Memory>{memory}),
        name(label, AllocatorRef<char, Memory>{memory}),
        tabs(AllocatorRef<Tab<Memory>, Memory>{memory}) {
    tabs.reserve(64);
  }

  inline Tab<Memory> *tab(std::uint64_t tab_id) noexcept {
    for (auto &entry : tabs) {
      if (entry.id == tab_id) {
        return &entry;
      }
    }

    return nullptr;
  }

  inline const Tab<Memory> *tab(std::uint64_t tab_id) const noexcept {
    return const_cast<Workspace *>(this)->tab(tab_id);
  }

  inline std::string_view displayName() const noexcept {
    if (!name.empty()) {
      return name;
    }

    std::string_view directory = path;
    while (directory.size() > 1 && directory.back() == '/') {
      directory.remove_suffix(1);
    }
    const auto basename = directory.substr(directory.rfind('/') + 1);
    return utf8Prefix(basename.empty() ? directory : basename, 256);
  }

  std::uint64_t id;
  String<Memory> path;
  String<Memory> name;
  Vector<Tab<Memory>, Memory> tabs;
  std::optional<std::uint64_t> geometry_client;
  FixedText<200> git_branch;
  std::chrono::steady_clock::time_point git_checked_at{};
  bool git_dirty = false;
  bool git_timed_out = false;
};

}
}

// Interface: model/worktrees.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
struct Worktree {
  inline explicit Worktree(Memory &memory, std::uint64_t identity, const RegisterWorktree &request)
      : id(identity),
        source(request.source),
        created_by(request.created_by),
        coordinator(request.coordinator),
        origin(request.origin),
        path(request.path, AllocatorRef<char, Memory>{memory}) {
    branch.assign(request.branch);
    base.assign(request.base);
    title.assign(request.title);
    brief.assign(request.brief);
    dispatched_from.assign(request.dispatched_from);
  }

  inline WorktreeListEntry entry() const noexcept {
    return {.worktree = id,
            .source = source,
            .workspace = workspace,
            .created_by = created_by,
            .origin = origin,
            .state = state,
            .path = path,
            .branch = branch.view(),
            .base = base.view(),
            .title = title.view(),
            .brief = brief.view(),
            .dispatched_from = dispatched_from.view(),
            .coordinator = coordinator,
            .diff_added = diff_added,
            .diff_removed = diff_removed,
            .diff_files = diff_files,
            .commits_ahead = commits_ahead,
            .command_label = command_label.view(),
            .command_state = command_state,
            .command_exit = command_exit};
  }

  std::uint64_t id;
  std::uint64_t source;
  std::optional<std::uint64_t> workspace;
  std::optional<std::uint64_t> created_by;
  std::optional<CoordinatorReference> coordinator;
  WorktreeOrigin origin;
  WorktreeState state = WorktreeState::active;
  String<Memory> path;
  FixedText<200> branch;
  FixedText<200> base;
  FixedText<96> title;
  FixedText<512> brief;
  FixedText<32> dispatched_from;
  FixedText<48> command_label;
  std::uint32_t diff_added = 0;
  std::uint32_t diff_removed = 0;
  std::uint32_t diff_files = 0;
  std::uint32_t commits_ahead = 0;
  unsigned probe_failures = 0;
  bool had_changes = false;
  std::chrono::steady_clock::time_point checked_at{};
  CommandState command_state = CommandState::none;
  std::int32_t command_exit = 0;
  std::optional<std::uint64_t> command_pane;
};

template <Allocator Memory>
class Worktrees {
public:
  inline explicit Worktrees(Memory &memory)
      : memory_(memory),
        entries_(memory) {}

  inline WorktreeRegistered registerEntry(const RegisterWorktree &request, std::uint64_t restored_identity = 0) {
    for (auto *entry : entries_.items()) {
      if (entry == nullptr || entry->path != request.path) {
        continue;
      }

      if (!request.title.empty()) {
        entry->title.assign(request.title);
      }

      if (!request.brief.empty()) {
        entry->brief.assign(request.brief);
      }

      if (request.coordinator) {
        entry->coordinator = request.coordinator;
      }

      return {request.request_id, entry->id, false};
    }

    if (request.origin == WorktreeOrigin::external && entries_.size() >= capacity - reserved_for_telar) {
      throw RequestError{FailureCode::resource_limit, "Worktree limit reached"};
    }

    const auto identity = restored_identity == 0 ? entries_.nextId() : restored_identity;
    auto entry = makeOwned<Worktree<Memory>>(memory_, memory_, identity, request);
    entries_.insert(identity, std::move(entry));
    return {request.request_id, identity, true};
  }

  inline Worktree<Memory> *find(std::uint64_t identity) noexcept {
    return entries_.find(identity);
  }

  inline auto items() noexcept {
    return entries_.items();
  }

  inline void remove(std::uint64_t identity) noexcept {
    entries_.erase(identity);
  }

  inline Worktree<Memory> *containing(std::string_view path) noexcept {
    Worktree<Memory> *selected = nullptr;
    for (auto *entry : entries_.items()) {
      if (entry == nullptr || !path.starts_with(entry->path)) {
        continue;
      }

      const auto length = entry->path.size();
      if (path.size() != length && path[length] != '/' && entry->path.back() != '/') {
        continue;
      }

      if (selected == nullptr || length > selected->path.size()) {
        selected = entry;
      }
    }

    return selected;
  }

  inline std::uint64_t sourceFor(std::uint64_t workspace) const noexcept {
    for (const auto *entry : entries_.items()) {
      if (entry != nullptr && entry->workspace == workspace) {
        return entry->source;
      }
    }

    return workspace;
  }

  static constexpr std::size_t capacity = 64;

private:
  static constexpr std::size_t reserved_for_telar = 16;
  Memory &memory_;
  SlotStore<Worktree<Memory>, capacity, Memory> entries_;
};

}
}

// Interface: model/runtime_model.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
struct RuntimeModel {
  inline explicit RuntimeModel(Memory &memory, GraphicsLimits graphics = {})
      : graphics_limits(graphics),
        media_budget(graphics.global_bytes),
        panes(memory),
        clients(memory),
        workspaces(memory),
        worktrees(memory) {}

  inline std::uint32_t clientBit(std::uint64_t identity) const noexcept {
    const auto slot = clients.slotOf(identity);
    return slot ? std::uint32_t{1} << *slot : 0;
  }

  inline bool tabHeld(TabLocation location) const noexcept {
    for (const auto *client : clients.items()) {
      if (client != nullptr && !client->connection.closing && client->held_tabs.contains(location)) {
        return true;
      }
    }

    return false;
  }

  GraphicsLimits graphics_limits;
  RuntimeLimits limits;
  [[no_unique_address]] diagnostics::RuntimeCounters metrics;
  MediaBudget media_budget;
  AgentManifests manifests = builtin_manifests;
  std::string_view cli_executable;
  bool capture_output = false;
  SlotStore<Pane<Memory>, 256, Memory> panes;
  SlotStore<ClientSession<Memory>, 32, Memory> clients;
  SlotStore<Workspace<Memory>, 64, Memory> workspaces;
  Worktrees<Memory> worktrees;
  ExitedPanes exited_panes;
  std::shared_ptr<PaneObserver<Memory>> retired_observers;
  std::size_t retired_observer_count = 0;
  std::shared_ptr<PaneMedia<Memory>> retired_media;
  std::size_t retired_media_count = 0;
  std::uint64_t next_tab_id = 1;
  std::uint64_t workspace_revision = 1;
  std::uint64_t next_pane_generation = 1;
  std::uint64_t input_sequence = 0;
  bool stopping = false;
};

}
}

// Interface: model/client_layouts.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class ClientLayouts {
public:
  inline explicit ClientLayouts(Memory &memory, const RuntimeModel<Memory> &model)
      : model_(model),
        records_(AllocatorRef<Record, Memory>{memory}) {
    records_.reserve(maximum_identities);
  }

  inline void retain(std::uint64_t identity, const UpdateClientLayout &update) {
    if (identity == 0) {
      throw RequestError{FailureCode::invalid_request, "Client layout requires a subscribed identity"};
    }

    bool active_valid = false;
    for (const auto &tab : update.tabs) {
      if (sameLocation(tab.location, update.active_tab)) {
        active_valid = current(tab);
      }
    }

    if (!active_valid) {
      return;
    }

    auto *existing = find(identity);
    Record replacement;
    replacement.identity = identity;
    replacement.last_used = clock_ + 1;
    replacement.sidebar_visible = update.sidebar_visible;
    replacement.sidebar_width = update.sidebar_width;
    replacement.workspace_list_collapsed = update.workspace_list_collapsed;
    replacement.active_tab = update.active_tab;

    if (existing != nullptr) {
      for (std::size_t index = 0; index < existing->tab_count; ++index) {
        auto tab = existing->tabAt(index);
        if (!current(tab) || std::ranges::any_of(update.tabs, [&](const auto &incoming) { return current(incoming) && sameLocation(incoming.location, tab.location); })) {
          continue;
        }

        if (std::ranges::any_of(update.tabs, [&](const auto &incoming) { return incoming.workspace_active && sameWorkspace(incoming.location.workspace, tab.location.workspace) && current(incoming); })) {
          tab.workspace_active = false;
        }

        replacement.append(tab);
      }
    }

    for (const auto &tab : update.tabs) {
      if (current(tab)) {
        replacement.append(tab);
      }
    }

    if (existing == nullptr) {
      if (records_.size() < maximum_identities) {
        records_.emplace_back();
        existing = &records_.back();
      } else {
        existing = &*std::ranges::min_element(records_, {}, &Record::last_used);
      }
    }

    *existing = replacement;
    ++clock_;
  }

  inline void publish(ClientSession<Memory> &client) {
    auto *record = find(client.identity);
    if (record == nullptr) {
      client.connection.send(ClientLayoutSnapshot{});
      return;
    }

    std::array<ClientTabLayout, maximum_tabs> tabs;
    std::size_t count = 0;
    std::optional<TabLocation> active;
    for (std::size_t index = 0; index < record->tab_count; ++index) {
      const auto tab = record->tabAt(index);
      if (!current(tab)) {
        continue;
      }

      tabs[count++] = tab;
      if (sameLocation(tab.location, record->active_tab)) {
        active = tab.location;
      }
    }

    record->last_used = ++clock_;
    client.connection.send(ClientLayoutSnapshot{
        .restored = true,
        .sidebar_visible = record->sidebar_visible,
        .sidebar_width = record->sidebar_width,
        .workspace_list_collapsed = record->workspace_list_collapsed,
        .active_tab = active,
        .tabs = std::span{tabs}.first(count),
    });
  }

  inline std::optional<std::uint64_t> focusedPane(std::uint64_t identity) const noexcept {
    for (const auto &record : records_) {
      if (record.identity != identity) {
        continue;
      }

      for (std::size_t index = 0; index < record.tab_count; ++index) {
        const auto &tab = record.tabs[index];
        if (sameLocation(tab.location, record.active_tab)) {
          return tab.focused_pane;
        }
      }
    }

    return std::nullopt;
  }

  inline std::uint64_t revision() const noexcept {
    return clock_;
  }

  template <typename Consumer>
  inline void exportRecords(Consumer &&consume) const {
    std::array<ClientTabLayout, maximum_tabs> tabs;
    for (const auto &record : records_) {
      std::size_t count = 0;
      bool active_valid = false;
      for (std::size_t index = 0; index < record.tab_count; ++index) {
        const auto tab = record.tabAt(index);
        if (!current(tab)) {
          continue;
        }

        tabs[count++] = tab;
        active_valid |= sameLocation(tab.location, record.active_tab);
      }
      if (!active_valid) {
        continue;
      }

      consume(record.identity, record.last_used, UpdateClientLayout{record.sidebar_visible, record.sidebar_width, record.workspace_list_collapsed, record.active_tab, std::span{tabs}.first(count)});
    }
  }

private:
  static constexpr std::size_t maximum_identities = 16;
  static constexpr std::size_t maximum_tabs = 256;
  static constexpr std::size_t maximum_nodes = 511;

  struct StoredTab {
    TabLocation location;
    std::uint64_t focused_pane;
    bool fullscreen;
    bool workspace_active;
    std::uint16_t node_start;
    std::uint16_t node_count;
  };

  struct Record {
    std::uint64_t identity = 0;
    std::uint64_t last_used = 0;
    bool sidebar_visible = true;
    std::uint16_t sidebar_width = 0;
    bool workspace_list_collapsed = false;
    TabLocation active_tab{};
    std::array<StoredTab, maximum_tabs> tabs{};
    std::array<ClientLayoutNode, maximum_nodes> nodes{};
    std::size_t tab_count = 0;
    std::size_t node_count = 0;

    inline ClientTabLayout tabAt(std::size_t index) const noexcept {
      const auto &tab = tabs[index];
      return ClientTabLayout{tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, std::span{nodes}.subspan(tab.node_start, tab.node_count)};
    }

    inline void append(const ClientTabLayout &tab) {
      if (tab_count == maximum_tabs || tab.nodes.size() > maximum_nodes - node_count) {
        throw std::bad_alloc{};
      }

      tabs[tab_count++] = StoredTab{tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, static_cast<std::uint16_t>(node_count), static_cast<std::uint16_t>(tab.nodes.size())};
      std::copy(tab.nodes.begin(), tab.nodes.end(), nodes.begin() + node_count);
      node_count += tab.nodes.size();
    }
  };

  inline static bool sameWorkspace(WorkspaceLocation left, WorkspaceLocation right) noexcept {
    return left.kind == right.kind && left.id == right.id;
  }

  inline static bool sameLocation(TabLocation left, TabLocation right) noexcept {
    return sameWorkspace(left.workspace, right.workspace) && left.tab_id == right.tab_id;
  }

  inline bool current(const ClientTabLayout &layout) const noexcept {
    auto *workspace = model_.workspaces.find(layout.location.workspace.id);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(layout.location.tab_id);
    if (layout.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      return false;
    }

    std::size_t pane_count = 0;
    for (const auto &node : layout.nodes) {
      const auto *leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf == nullptr) {
        continue;
      }

      if (model_.panes.find(leaf->pane_id) == nullptr || std::ranges::find(tab->panes, leaf->pane_id) == tab->panes.end()) {
        return false;
      }

      ++pane_count;
    }

    return pane_count == tab->panes.size();
  }

  inline Record *find(std::uint64_t identity) noexcept {
    for (auto &record : records_) {
      if (record.identity == identity) {
        return &record;
      }
    }

    return nullptr;
  }

  const RuntimeModel<Memory> &model_;
  Vector<Record, Memory> records_;
  std::uint64_t clock_ = 0;
};

}
}
