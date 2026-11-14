module telar.runtime.observation.processor;

namespace telar::runtime {

  void ObservationBatch::clear() noexcept {
    byte_count = 0;
    event_count = 0;
    reset_before = false;
  }

  std::span<const Byte> ObservationBatch::bytesOf(const ObservationEvent& event) const noexcept {
    return std::span{bytes}.subspan(event.offset, event.length);
  }

  template <Allocator Memory>
  PaneObserver<Memory>::PaneObserver(Memory& memory, TerminalSize size, std::string_view directory, bool capture_output, std::optional<ShellToken> shell_token)
      : terminal_(memory, size, TerminalPurpose::observation),
        tracker_(memory, terminal_, directory, capture_output, shell_token),
        workspace_path_(AllocatorRef<char, Memory>{memory}),
        shell_(AllocatorRef<char, Memory>{memory}),
        initial_size_(size) {}

  template <Allocator Memory>
  void PaneObserver<Memory>::configureHistory(const HistorySession& session, bool capture_output) {
    workspace_path_.assign(session.workspace_path);
    shell_.assign(session.shell);
    // The session kept views the observer's own copies of its texts.
    auto kept = session;

    kept.workspace_path = workspace_path_;
    kept.shell = shell_;
    session_ = kept;
    if (capture_output) {
      tracker_.enableOutputCapture();
    }
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::updateDirectory(std::string_view directory) {
    tracker_.updateDirectory(directory);
  }

  template <Allocator Memory>
  std::string_view PaneObserver<Memory>::observedDirectory() const noexcept {
    return tracker_.directory();
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::noteInjectedSubmission() noexcept {
    injected_submissions_.fetch_add(1, std::memory_order_relaxed);
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::bytes(ObservationKind kind, std::span<const Byte> bytes, std::optional<bool> shell_foreground) noexcept {
    auto& batch = batches_[active_];
    if (batch.event_count == ObservationBatch::event_capacity || bytes.size() > ObservationBatch::byte_capacity - batch.byte_count) {
      drop(bytes.size());
    }

    if (bytes.size() > ObservationBatch::byte_capacity) {
      return;
    }

    const auto offset = batch.byte_count;

    std::copy(bytes.begin(), bytes.end(), batch.bytes.begin() + offset);
    batch.byte_count += bytes.size();
    batch.events[batch.event_count++] = {kind, ObservationTime::now(), static_cast<std::uint32_t>(offset), static_cast<std::uint32_t>(bytes.size()), shell_foreground};
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::resize(TerminalSize size) noexcept {
    control(ObservationEvent{.kind = ObservationKind::resize, .time = ObservationTime::now(), .size = size});
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::shellExit(int code) noexcept {
    control(ObservationEvent{.kind = ObservationKind::shell_exit, .time = ObservationTime::now(), .exit_code = code});
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::finishSession() noexcept {
    control(ObservationEvent{.kind = ObservationKind::session_end, .time = ObservationTime::now()});
  }

  template <Allocator Memory>
  bool PaneObserver<Memory>::idle() const noexcept {
    return !sealed_ && batches_[active_].event_count == 0;
  }

  template <Allocator Memory>
  bool PaneObserver<Memory>::seal(bool allow_empty) noexcept {
    if (sealed_ || (!allow_empty && batches_[active_].event_count == 0)) {
      return false;
    }

    sealed_ = active_;
    active_ ^= 1;
    return true;
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::complete() noexcept {
    batches_[*sealed_].clear();
    sealed_.reset();
  }

  template <Allocator Memory>
  std::optional<LimitReach> PaneObserver<Memory>::takeDrop() noexcept {
    return std::exchange(drop_, std::nullopt);
  }

  template <Allocator Memory>
  ScreenObservationResult PaneObserver<Memory>::observe(const AgentManifests& manifests, AgentProvider provider, bool inspect_screen) noexcept {
    DiscardedHistory history;

    return observe(manifests, provider, history, inspect_screen);
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::control(const ObservationEvent& event) noexcept {
    auto& batch = batches_[active_];
    if (batch.event_count == ObservationBatch::event_capacity) {
      drop(0);
    }

    batch.events[batch.event_count++] = event;
  }

  template <Allocator Memory>
  void PaneObserver<Memory>::drop(std::size_t incoming) noexcept {
    auto& batch = batches_[active_];
    if (batch.event_count == ObservationBatch::event_capacity) {
      drop_ = LimitReach{.name = "history.observer_batch_events", .noun = "events", .value = ObservationBatch::event_capacity, .requested = batch.event_count + 1};
    } else {
      drop_ = LimitReach{.name = "history.observer_batch_bytes", .noun = "bytes", .value = ObservationBatch::byte_capacity, .requested = batch.byte_count + incoming};
    }

    batch.clear();
    batch.reset_before = true;
  }

  template class PaneObserver<telar::ConcurrentMemory>;

}
