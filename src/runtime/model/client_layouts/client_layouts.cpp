module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.model.client_layouts;

import telar.sys.process;

namespace telar::runtime {

  template <Allocator Memory>
  PendingClipboard<Memory>::PendingClipboard(Memory& memory)
      : bytes_(AllocatorRef<Byte, Memory>{memory}) {}

  template <Allocator Memory>
  void PendingClipboard<Memory>::replace(std::uint64_t pane, std::span<const Byte> bytes) {
    if (bytes.size() > capacity) {
      throw EncodingError{"Selection exceeds the clipboard limit"};
    }

    Vector<Byte, Memory> replacement{bytes.begin(), bytes.end(), bytes_.get_allocator()};

    bytes_.swap(replacement);
    pane_ = pane;
    pending_ = true;
  }

  template <Allocator Memory>
  bool PendingClipboard<Memory>::pending() const noexcept {
    return pending_;
  }

  template <Allocator Memory>
  PaneClipboard PendingClipboard<Memory>::message() const noexcept {
    return {.pane_id = pane_, .bytes = bytes_};
  }

  template <Allocator Memory>
  void PendingClipboard<Memory>::delivered() noexcept {
    pending_ = false;
  }

  template class PendingClipboard<ConcurrentMemory>;

  SentDocuments::Item* SentDocuments::find(std::uint64_t id) noexcept {
    const auto kept = std::span{items}.first(count);
    const auto found = std::ranges::find(kept, id, &Item::id);

    return found == kept.end() ? nullptr : &*found;
  }

  SentDocuments::Item* SentDocuments::add(std::uint64_t id) noexcept {
    if (count == items.size()) {
      return nullptr;
    }

    items[count] = Item{.id = id};
    return &items[count++];
  }

  void SentDocuments::erase(std::size_t index) noexcept {
    std::move(items.begin() + static_cast<std::ptrdiff_t>(index) + 1, items.begin() + static_cast<std::ptrdiff_t>(count), items.begin() + static_cast<std::ptrdiff_t>(index));
    --count;
  }

  bool SentDocuments::settled(std::uint64_t at_revision, std::uint64_t at_generation, std::uint64_t at_trimmed) const noexcept {
    return revision == at_revision && generation == at_generation && trimmed == at_trimmed;
  }

  void SentDocuments::settle(std::uint64_t at_revision, std::uint64_t at_generation, std::uint64_t at_trimmed) noexcept {
    revision = at_revision;
    generation = at_generation;
    trimmed = at_trimmed;
  }

  template <Allocator Memory>
  Attachment<Memory>::Attachment(Memory& memory, GraphicsCreditBudget& budget, std::uint64_t pane, std::shared_ptr<PaneMedia<Memory>> media)
      : pane_id(pane),
        frames(memory, pane),
        graphics(budget, pane, std::move(media)) {}

  template Attachment<ConcurrentMemory>::Attachment(ConcurrentMemory& memory, GraphicsCreditBudget& budget, std::uint64_t pane, std::shared_ptr<PaneMedia<ConcurrentMemory>> media);

  template <Allocator Memory>
  ClientSession<Memory>::ClientSession(Memory& memory, std::uint64_t identity, FileDescriptor descriptor)
      : id(identity),
        generation(identity),
        connection(memory, std::move(descriptor)),
        attachments(AllocatorRef<Owned<Attachment<Memory>, Memory>, Memory>{memory}),
        clipboard(memory),
        deferred_report(memory) {
    attachments.reserve(attachment_capacity);
  }

  template <Allocator Memory>
  std::size_t ClientSession<Memory>::availableAttachmentSlot() const {
    std::uint64_t occupied = 0;

    for (const auto& entry : attachments) {
      occupied |= std::uint64_t{1} << entry->slot;
    }

    if (occupied == std::numeric_limits<std::uint64_t>::max()) {
      throw std::bad_alloc{};
    }

    return std::countr_zero(~occupied);
  }

  template <Allocator Memory>
  std::uint32_t ClientSession<Memory>::observerBit() const noexcept {
    return event_identity == 0 ? 0 : std::uint32_t{1} << (event_identity % client_capacity);
  }

  template <Allocator Memory>
  Attachment<Memory>* ClientSession<Memory>::attachment(std::uint64_t pane_id) const noexcept {
    for (const auto& entry : attachments) {
      if (entry->pane_id == pane_id) {
        return entry.get();
      }
    }

    return nullptr;
  }

  template <Allocator Memory>
  bool ClientSession<Memory>::verifiedFor(const Pane<Memory>& pane) const noexcept {
    return verified_pane == pane.id && verified_generation == pane.generation;
  }

  template class ClientSession<ConcurrentMemory>;

  template <Allocator Memory>
  Pane<Memory>::Pane(Memory& memory, std::uint64_t identity, TabLocation location, Command<Memory>& command, PaneLaunch settings)
      : id(identity),
        location(location),
        launch(memory),
        pty_responses(std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        observer(std::allocate_shared<PaneObserver<Memory>>(AllocatorRef<PaneObserver<Memory>, Memory>{memory}, memory, settings.size, command.cwd(), false, settings.shell ? std::optional{settings.shell->token} : std::nullopt)),
        media(std::allocate_shared<PaneMedia<Memory>>(AllocatorRef<PaneMedia<Memory>, Memory>{memory}, memory, settings.media_budget, settings.graphics, settings.size, pty_responses)),
        terminal(memory, settings.size, TerminalPurpose::separate_media, pty_responses, GraphicsQueryResources{settings.graphics, settings.media_budget, &media->queryUsage()}),
        input(memory, input_limit),
        scrollback_rows(memory),
        cwd(command.cwd(), AllocatorRef<char, Memory>{memory}) {
    randomBytes(history_session.data(), history_session.size());
    input.reserve(input_limit);
    launch.capture(command.arguments(), command.restorable());
    const auto executable = std::string_view{command.arguments().front()};

    foreground.assign(utf8Prefix(executable.substr(executable.rfind('/') + 1), 48));
    process.emplace(command.specification(settings.size));
    terminal.attachMedia(*media);
    shell_state.pane_id = identity;
    if (settings.shell) {
      shell_zones.emplace(command.cwd(), settings.shell->token);
      blocks.emplace(memory, terminal);
      shell_state.shell = settings.shell->shell;
      local_shell = settings.shell->shell;
      shell_revision = 1;
      observeShell();
    }
  }

  template <Allocator Memory>
  bool Pane<Memory>::read(ReadMode mode) {
    constexpr std::size_t batch_byte_limit = 64 * 1024;
    constexpr unsigned batch_read_limit = 8;
    std::array<Byte, read_buffer_size> buffer;
    std::size_t batch_bytes = 0;
    const unsigned read_limit = mode == ReadMode::burst ? batch_read_limit : 1;
    // Read the shell's state once per call, after the output that may have changed it.
    const auto observed = [&](bool result) {
      if (batch_bytes != 0) {
        observeShell();
        terminal.followScrollback();
        if (blocks) {
          blocks->follow();
        }
      }

      return result;
    };

    for (unsigned attempt = 0; attempt < read_limit && batch_bytes < batch_byte_limit; ++attempt) {
      const auto capacity = std::min(buffer.size(), batch_byte_limit - batch_bytes);
      if (terminal.hasPendingControl() || media->holdsRead(capacity)) {
        TELAR_DIAGNOSTIC(media->noteHeldRead());
        return observed(true);
      }

      const auto count = ::read(process->descriptor(), buffer.data(), capacity);
      if (count > 0 && echo_sent) {
        timeLink(std::chrono::steady_clock::now() - *std::exchange(echo_sent, std::nullopt));
      }

      if (count > 0) {
        const auto bytes = std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count));

        TELAR_DIAGNOSTIC(recordRead(bytes.size(), batch_bytes != 0));
        const auto foreground = needs_foreground_observation ? shellForeground() : std::nullopt;

        expireProgress(foreground);
        observer->bytes(ObservationKind::output, bytes, foreground);
        ShellCompletions completions{shell_state};

        if (shell_zones) {
          const auto before = shell_state.commands;

          shell_zones->feed(bytes, ObservationTime{}, completions);
          shell_revision += shell_state.commands != before;
        }

        {
          TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters == nullptr ? nullptr : &counters->ingest});
          // Up to each signed mark, so a command's block anchors where its mark was printed.
          std::size_t fed = 0;
          const auto now = std::chrono::steady_clock::now();

          for (const auto& mark : completions.marks()) {
            if (mark.end > fed) {
              terminal.feed(bytes.subspan(fed, mark.end - fed), *media);
              fed = mark.end;
            }

            if (mark.action == 'D') {
              blocks->finished(mark.status, now);
            } else {
              blocks->mark(mark.action, now);
            }
          }

          if (fed < bytes.size()) {
            terminal.feed(bytes.subspan(fed), *media);
          }
        }

        batch_bytes += bytes.size();
        continue;
      }

      if (count < 0 && socketWouldBlock(sys::lastError())) {
        return observed(true);
      }

      output_closed = true;
      terminal.abortControl();
      return observed(false);
    }

    return observed(true);
  }

  template <Allocator Memory>
  void Pane<Memory>::observeShell() noexcept {
    if (!shell_zones) {
      return;
    }

    auto next = shell_state;

    next.phase = shell_zones->editing() ? ShellPhase::prompt : shell_zones->running() ? ShellPhase::running
                                                                                      : ShellPhase::unknown;
    next.remote = shell_zones->remote();
    next.host = shell_zones->remoteHost();
    next.directory = shell_zones->remoteDirectory();
    if (!next.remote) {
      next.link_ms = 0;
      link_average_ms = 0;
      echo_sent.reset();
    }

    next.shell = next.remote && shell_zones->remoteShell() != IntegratedShell::none ? shell_zones->remoteShell() : local_shell;
    const auto group = process->foregroundProcessGroup();

    next.shell_foreground = group && *group == process->processId();
    termios settings{};
    if (::tcgetattr(process->descriptor(), &settings) == 0) {
      const auto character = [&](int index) {
        return settings.c_cc[index] == _POSIX_VDISABLE ? Byte{0} : static_cast<Byte>(settings.c_cc[index]);
      };

      next.canonical = (settings.c_lflag & ICANON) != 0;
      next.echo = (settings.c_lflag & ECHO) != 0;
      next.signal_keys = (settings.c_lflag & ISIG) != 0;
      next.interrupt = character(VINTR);
      next.quit = character(VQUIT);
      next.suspend = character(VSUSP);
      next.end_of_file = character(VEOF);
    }

    if (next != shell_state) {
      shell_state = next;
      ++shell_revision;
    }
  }

  template <Allocator Memory>
  bool Pane<Memory>::hasInput() const noexcept {
    return !input.empty() || !pty_responses->empty();
  }

  template <Allocator Memory>
  void Pane<Memory>::requestClose() noexcept {
    if (close_requested) {
      return;
    }

    close_requested = true;
    process->shutdown();
  }

  template <Allocator Memory>
  void Pane<Memory>::enqueueInput(std::span<const Byte> bytes) {
    input.append(bytes);
    TELAR_DIAGNOSTIC(if (counters != nullptr) {
      diagnostics::accumulate(counters->input_events);
      diagnostics::accumulate(counters->input_bytes, bytes.size());
    });
    observer->bytes(ObservationKind::input, bytes, shellForeground());
    if (shell_zones) {
      shell_zones->input(bytes);
    }

    ++input_revision;
    needs_foreground_observation = true;
  }

  template <Allocator Memory>
  void Pane<Memory>::submitCommand(std::span<const Byte> text) {
    observer->bytes(ObservationKind::command, text, shellForeground());
  }

  template <Allocator Memory>
  void Pane<Memory>::resumeControl() {
    terminal.resumeControl(*media);
  }

  template <Allocator Memory>
  void Pane<Memory>::resize(TerminalSize size) {
    if (terminal.hasSize(size)) {
      return;
    }

    terminal.resize(size, *media);
    if (blocks) {
      blocks->follow(true);
    }

    process->resize(size);
    observer->resize(size);
    media->resize(size);
  }

  template <Allocator Memory>
  std::optional<bool> Pane<Memory>::shellForeground() const noexcept {
    if (shell_markers) {
      return std::nullopt;
    }

    const auto foreground = process->foregroundProcessGroup();

    return foreground ? std::optional<bool>{*foreground == process->processId()} : std::nullopt;
  }

  template <Allocator Memory>
  std::optional<std::int32_t> Pane<Memory>::exitCode() const noexcept {
    return exit_status ? std::optional{shellExitCode(*exit_status)} : std::nullopt;
  }

  template <Allocator Memory>
  void Pane<Memory>::ShellCompletions::complete(CommandCompletion completion) noexcept {
    ++state.commands;
    state.status = completion.exit_code.value_or(0);
    if (count != 0 && kept[count - 1].action == 'D') {
      kept[count - 1].status = completion.exit_code;
    }
  }

  template <Allocator Memory>
  void Pane<Memory>::ShellCompletions::mark(CommandMark mark) noexcept {
    if (count < kept.size()) {
      kept[count++] = Mark{.action = mark.action, .end = mark.end, .status = std::nullopt};
    }
  }

  template <Allocator Memory>
  auto Pane<Memory>::ShellCompletions::marks() const noexcept -> std::span<const Mark> {
    return std::span<const Mark>{kept}.first(count);
  }

  template <Allocator Memory>
  void Pane<Memory>::timeLink(std::chrono::steady_clock::duration elapsed) noexcept {
    constexpr double longest_ms = 5000;
    const auto sample = std::chrono::duration<double, std::milli>(elapsed).count();
    if (!shell_state.remote || sample > longest_ms) {
      return;
    }

    link_average_ms = link_average_ms == 0 ? sample : link_average_ms * 0.7 + sample * 0.3;
    const auto shown = static_cast<std::uint32_t>(std::max(1.0, std::round(link_average_ms)));
    const auto published = shell_state.link_ms;
    if (published == 0 || std::max(shown, published) - std::min(shown, published) >= std::max<std::uint32_t>(2, published / 10)) {
      shell_state.link_ms = shown;
      ++shell_revision;
    }
  }

  template <Allocator Memory>
  void Pane<Memory>::expireProgress(std::optional<bool> shell_foreground) noexcept {
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
  template <Allocator Memory>
  void Pane<Memory>::recordRead(std::size_t size, bool folded) noexcept {
    if (counters == nullptr) {
      return;
    }

    diagnostics::accumulate(counters->pty_events);
    diagnostics::accumulate(counters->pty_bytes, size);
    diagnostics::accumulate(counters->folded_pty_events, folded);
  }
#endif

  template class Pane<ConcurrentMemory>;

  template <Allocator Memory>
  Tab<Memory>::Tab(Memory& memory, std::uint64_t identity, std::string_view name)
      : id(identity),
        label(name, AllocatorRef<char, Memory>{memory}),
        panes(AllocatorRef<std::uint64_t, Memory>{memory}) {
    panes.reserve(64);
  }

  template struct Tab<ConcurrentMemory>;

  template <Allocator Memory>
  Workspace<Memory>::Workspace(Memory& memory, std::uint64_t identity, std::string_view directory, std::string_view label)
      : id(identity),
        path(directory, AllocatorRef<char, Memory>{memory}),
        name(label, AllocatorRef<char, Memory>{memory}),
        tabs(AllocatorRef<Tab<Memory>, Memory>{memory}) {
    tabs.reserve(64);
  }

  template <Allocator Memory>
  Tab<Memory>* Workspace<Memory>::tab(std::uint64_t tab_id) noexcept {
    for (auto& entry : tabs) {
      if (entry.id == tab_id) {
        return &entry;
      }
    }

    return nullptr;
  }

  template <Allocator Memory>
  const Tab<Memory>* Workspace<Memory>::tab(std::uint64_t tab_id) const noexcept {
    return const_cast<Workspace*>(this)->tab(tab_id);
  }

  template <Allocator Memory>
  std::string_view Workspace<Memory>::displayName() const noexcept {
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

  template class Workspace<ConcurrentMemory>;

  template <Allocator Memory>
  Worktree<Memory>::Worktree(Memory& memory, std::uint64_t identity, const RegisterWorktree& request)
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

  template <Allocator Memory>
  WorktreeListEntry Worktree<Memory>::entry() const noexcept {
    return {.worktree = id, .source = source, .workspace = workspace, .created_by = created_by, .origin = origin, .state = state, .path = path, .branch = branch.view(), .base = base.view(), .title = title.view(), .brief = brief.view(), .dispatched_from = dispatched_from.view(), .coordinator = coordinator, .diff_added = diff_added, .diff_removed = diff_removed, .diff_files = diff_files, .commits_ahead = commits_ahead, .command_label = command_label.view(), .command_state = command_state, .command_exit = command_exit};
  }

  template struct Worktree<ConcurrentMemory>;

  template <Allocator Memory>
  Worktrees<Memory>::Worktrees(Memory& memory)
      : memory_(memory),
        entries_(memory) {}

  template <Allocator Memory>
  WorktreeRegistered Worktrees<Memory>::registerEntry(const RegisterWorktree& request, std::uint64_t restored_identity) {
    for (auto* entry : entries_.items()) {
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

  template <Allocator Memory>
  Worktree<Memory>* Worktrees<Memory>::find(std::uint64_t identity) noexcept {
    return entries_.find(identity);
  }

  template <Allocator Memory>
  std::span<Worktree<Memory>* const> Worktrees<Memory>::items() const noexcept {
    return entries_.items();
  }

  template <Allocator Memory>
  void Worktrees<Memory>::remove(std::uint64_t identity) noexcept {
    entries_.erase(identity);
  }

  template <Allocator Memory>
  Worktree<Memory>* Worktrees<Memory>::containing(std::string_view path) noexcept {
    Worktree<Memory>* selected = nullptr;

    for (auto* entry : entries_.items()) {
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

  template <Allocator Memory>
  std::uint64_t Worktrees<Memory>::sourceFor(std::uint64_t workspace) const noexcept {
    for (const auto* entry : entries_.items()) {
      if (entry != nullptr && entry->workspace == workspace) {
        return entry->source;
      }
    }

    return workspace;
  }

  template class Worktrees<ConcurrentMemory>;

  template <Allocator Memory>
  bool tabHeld(const ClientStore<Memory>& clients, TabLocation location) noexcept {
    for (const auto* client : clients.items()) {
      if (client != nullptr && !client->connection.closing && client->held_tabs.contains(location)) {
        return true;
      }
    }

    return false;
  }

  template <Allocator Memory>
  ClientSession<Memory>& requireClient(ClientStore<Memory>& clients, std::uint64_t identity) {
    auto* client = clients.find(identity);
    if (client == nullptr) {
      throw RequestError{FailureCode::invalid_request, "Client does not exist"};
    }

    return *client;
  }

  template <Allocator Memory>
  tbc::view<Pane<Memory>*, tbc::lt::a> findPane(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept {
    auto* pane = panes.find(identity);

    return pane != nullptr && pane->generation == generation ? pane : nullptr;
  }

  template <Allocator Memory>
  tbc::view<const Pane<Memory>*, tbc::lt::a> findPane(tbc::view<const PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept {
    const auto* pane = panes.find(identity);

    return pane != nullptr && pane->generation == generation ? pane : nullptr;
  }

  template <Allocator Memory>
  tbc::view<Pane<Memory>*, tbc::lt::a> livePane(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept {
    auto* pane = findPane(panes, identity, generation);

    return pane != nullptr && !pane->exit_status && !pane->close_requested ? pane : nullptr;
  }

  template <Allocator Memory>
  tbc::view<const Pane<Memory>*, tbc::lt::a> livePane(tbc::view<const PaneStore<Memory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept {
    const auto* pane = findPane(panes, identity, generation);

    return pane != nullptr && !pane->exit_status && !pane->close_requested ? pane : nullptr;
  }

  template <Allocator Memory>
  tbc::view<Pane<Memory>&, tbc::lt::a> requireReporterPane(tbc::view<PaneStore<Memory>&, tbc::lt::a> panes, const ClientSession<Memory>& client, std::uint64_t identity, std::uint64_t generation) {
    auto* pane = findPane(panes, identity, generation);
    if (pane == nullptr || pane->exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }

    if (!client.verifiedFor(*pane)) {
      throw RequestError{FailureCode::foreign_process, "The report does not come from this pane's agent"};
    }

    return *pane;
  }

  template bool tabHeld<ConcurrentMemory>(const ClientStore<ConcurrentMemory>& clients, TabLocation location) noexcept;
  template ClientSession<ConcurrentMemory>& requireClient<ConcurrentMemory>(ClientStore<ConcurrentMemory>& clients, std::uint64_t identity);
  template tbc::view<Pane<ConcurrentMemory>*, tbc::lt::a> findPane<ConcurrentMemory>(tbc::view<PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
  template tbc::view<const Pane<ConcurrentMemory>*, tbc::lt::a> findPane<ConcurrentMemory>(tbc::view<const PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
  template tbc::view<Pane<ConcurrentMemory>*, tbc::lt::a> livePane<ConcurrentMemory>(tbc::view<PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
  template tbc::view<const Pane<ConcurrentMemory>*, tbc::lt::a> livePane<ConcurrentMemory>(tbc::view<const PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, std::uint64_t identity, std::uint64_t generation) noexcept;
  template tbc::view<Pane<ConcurrentMemory>&, tbc::lt::a> requireReporterPane<ConcurrentMemory>(tbc::view<PaneStore<ConcurrentMemory>&, tbc::lt::a> panes, const ClientSession<ConcurrentMemory>& client, std::uint64_t identity, std::uint64_t generation);

  template <Allocator Memory>
  RuntimeModel<Memory>::RuntimeModel(Memory& memory, GraphicsLimits graphics)
      : graphics_limits(graphics),
        media_budget(graphics.global_bytes),
        panes(memory),
        workspaces(memory),
        worktrees(memory) {}

  template struct RuntimeModel<ConcurrentMemory>;

  template <Allocator Memory>
  ClientLayouts<Memory>::ClientLayouts(Memory& memory)
      : records_(AllocatorRef<Record, Memory>{memory}) {
    records_.reserve(maximum_identities);
  }

  template <Allocator Memory>
  void ClientLayouts<Memory>::retain(const RuntimeModel<Memory>& model, std::uint64_t identity, const UpdateClientLayout& update) {
    if (identity == 0) {
      throw RequestError{FailureCode::invalid_request, "Client layout requires a subscribed identity"};
    }

    bool active_valid = false;

    for (const auto& tab : update.tabs) {
      if (sameLocation(tab.location, update.active_tab)) {
        active_valid = current(model, tab);
      }
    }

    if (!active_valid) {
      return;
    }

    auto* existing = find(identity);
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
        if (!current(model, tab) || std::ranges::any_of(update.tabs, [&](const auto& incoming) {
              return current(model, incoming) && sameLocation(incoming.location, tab.location);
            })) {
          continue;
        }

        if (std::ranges::any_of(update.tabs, [&](const auto& incoming) {
              return incoming.workspace_active && sameWorkspace(incoming.location.workspace, tab.location.workspace) && current(model, incoming);
            })) {
          tab.workspace_active = false;
        }

        replacement.append(tab);
      }
    }

    for (const auto& tab : update.tabs) {
      if (current(model, tab)) {
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

  template <Allocator Memory>
  std::optional<std::uint64_t> ClientLayouts<Memory>::focusedPane(std::uint64_t identity) const noexcept {
    for (const auto& record : records_) {
      if (record.identity != identity) {
        continue;
      }

      for (std::size_t index = 0; index < record.tab_count; ++index) {
        const auto& tab = record.tabs[index];
        if (sameLocation(tab.location, record.active_tab)) {
          return tab.focused_pane;
        }
      }
    }

    return std::nullopt;
  }

  template <Allocator Memory>
  std::uint64_t ClientLayouts<Memory>::revision() const noexcept {
    return clock_;
  }

  template <Allocator Memory>
  ClientTabLayout ClientLayouts<Memory>::Record::tabAt(std::size_t index) const noexcept {
    const auto& tab = tabs[index];

    return ClientTabLayout{tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, std::span{nodes}.subspan(tab.node_start, tab.node_count)};
  }

  template <Allocator Memory>
  void ClientLayouts<Memory>::Record::append(const ClientTabLayout& tab) {
    if (tab_count == maximum_tabs || tab.nodes.size() > maximum_nodes - node_count) {
      throw std::bad_alloc{};
    }

    tabs[tab_count++] = StoredTab{tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, static_cast<std::uint16_t>(node_count), static_cast<std::uint16_t>(tab.nodes.size())};
    std::copy(tab.nodes.begin(), tab.nodes.end(), nodes.begin() + node_count);
    node_count += tab.nodes.size();
  }

  template <Allocator Memory>
  bool ClientLayouts<Memory>::sameWorkspace(WorkspaceLocation left, WorkspaceLocation right) noexcept {
    return left.kind == right.kind && left.id == right.id;
  }

  template <Allocator Memory>
  bool ClientLayouts<Memory>::sameLocation(TabLocation left, TabLocation right) noexcept {
    return sameWorkspace(left.workspace, right.workspace) && left.tab_id == right.tab_id;
  }

  template <Allocator Memory>
  bool ClientLayouts<Memory>::current(const RuntimeModel<Memory>& model, const ClientTabLayout& layout) noexcept {
    auto* workspace = model.workspaces.find(layout.location.workspace.id);
    auto* tab = workspace == nullptr ? nullptr : workspace->tab(layout.location.tab_id);
    if (layout.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      return false;
    }

    std::size_t pane_count = 0;

    for (const auto& node : layout.nodes) {
      const auto* leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf == nullptr) {
        continue;
      }

      if (model.panes.find(leaf->pane_id) == nullptr || std::ranges::find(tab->panes, leaf->pane_id) == tab->panes.end()) {
        return false;
      }

      ++pane_count;
    }

    return pane_count == tab->panes.size();
  }

  template <Allocator Memory>
  typename ClientLayouts<Memory>::Record* ClientLayouts<Memory>::find(std::uint64_t identity) noexcept {
    for (auto& record : records_) {
      if (record.identity == identity) {
        return &record;
      }
    }

    return nullptr;
  }

  template class ClientLayouts<ConcurrentMemory>;

}
