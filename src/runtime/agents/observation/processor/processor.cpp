module telar.runtime.agents.observation.processor;
import telar.base.ds;

namespace telar::runtime {

  void ObservationBatch::clear() noexcept {
    byte_count = 0;
    event_count = 0;
    reset_before = false;
    resynced = false;
  }

  std::span<const Byte> ObservationBatch::bytesOf(const ObservationEvent& event) const noexcept {
    return std::span{bytes}.subspan(event.offset, event.length);
  }

  PaneObserver::PaneObserver(tbc::mut_a<ConcurrentMemory> memory, TerminalSize size, std::string_view directory, bool capture_output, ds::Option<ShellToken> shell_token)
      : terminal_(memory, size, TerminalPurpose::observation),
        tracker_(memory, terminal_, directory, capture_output, shell_token),
        workspace_path_(memory),
        shell_(memory),
        initial_size_(size) {}

  void PaneObserver::configureHistory(const HistorySession& session, bool capture_output) {
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

  void PaneObserver::updateDirectory(std::string_view directory) {
    tracker_.updateDirectory(directory);
  }

  std::string_view PaneObserver::observedDirectory() const noexcept {
    return tracker_.directory();
  }

  void PaneObserver::noteInjectedSubmission() noexcept {
    injected_submissions_.fetch_add(1, std::memory_order_relaxed);
  }

  void PaneObserver::bytes(ObservationKind kind, std::span<const Byte> bytes, ds::Option<bool> shell_foreground) noexcept {
    auto& batch = batches_.atMut(active_);
    if (batch.event_count == ObservationBatch::event_capacity || bytes.size() > ObservationBatch::byte_capacity - batch.byte_count) {
      drop(bytes.size());
    }

    if (bytes.size() > ObservationBatch::byte_capacity) {
      return;
    }

    const auto offset = batch.byte_count;

    std::ranges::copy(bytes, batch.bytes.viewMut().subspan(offset).begin());
    batch.byte_count += bytes.size();
    batch.events.atMut(batch.event_count++) = {.kind = kind, .time = ObservationTime::now(), .offset = static_cast<std::uint32_t>(offset), .length = static_cast<std::uint32_t>(bytes.size()), .shell_foreground = shell_foreground};
  }

  bool PaneObserver::overflows(std::size_t incoming) const noexcept {
    const auto& batch = batches_[active_];

    return batch.event_count == ObservationBatch::event_capacity || incoming > ObservationBatch::byte_capacity - batch.byte_count;
  }

  std::span<Byte> PaneObserver::resyncRoom(std::size_t incoming) noexcept {
    drop(incoming);
    // Room for the picture and the bytes after it, and an event for each.
    return incoming >= ObservationBatch::byte_capacity ? std::span<Byte>{} : batches_.atMut(active_).bytes.viewMut().first(ObservationBatch::byte_capacity - incoming);
  }

  void PaneObserver::resynced(std::size_t length) noexcept {
    if (length == 0) {
      return;
    }

    auto& batch = batches_.atMut(active_);

    batch.events.atMut(batch.event_count++) = {.kind = ObservationKind::resync, .time = ObservationTime::now(), .offset = 0, .length = static_cast<std::uint32_t>(length)};
    batch.byte_count = length;
    batch.resynced = true;
  }

  void PaneObserver::resize(TerminalSize size) noexcept {
    control(ObservationEvent{.kind = ObservationKind::resize, .time = ObservationTime::now(), .size = size});
  }

  void PaneObserver::shellExit(int code) noexcept {
    control(ObservationEvent{.kind = ObservationKind::shell_exit, .time = ObservationTime::now(), .exit_code = code});
  }

  void PaneObserver::finishSession() noexcept {
    control(ObservationEvent{.kind = ObservationKind::session_end, .time = ObservationTime::now()});
  }

  bool PaneObserver::idle() const noexcept {
    return !sealed_ && batches_[active_].event_count == 0;
  }

  bool PaneObserver::seal(bool allow_empty) noexcept {
    if (sealed_ || (!allow_empty && batches_[active_].event_count == 0)) {
      return false;
    }

    sealed_ = active_;
    active_ ^= 1U;
    return true;
  }

  void PaneObserver::complete() noexcept {
    batches_.atMut(*sealed_).clear();
    sealed_.reset();
  }

  ds::Option<LimitReach> PaneObserver::takeDrop() noexcept {
    return std::exchange(drop_, ds::none);
  }

  ScreenObservationResult PaneObserver::observe(const AgentManifests& manifests, AgentProvider provider, bool inspect_screen) noexcept {
    DiscardedHistory history;

    return observe(manifests, provider, history, inspect_screen);
  }

  void PaneObserver::control(const ObservationEvent& event) noexcept {
    auto& batch = batches_.atMut(active_);
    if (batch.event_count == ObservationBatch::event_capacity) {
      drop(0);
    }

    batch.events.atMut(batch.event_count++) = event;
  }

  void PaneObserver::drop(std::size_t incoming) noexcept {
    auto& batch = batches_.atMut(active_);
    if (batch.event_count == ObservationBatch::event_capacity) {
      drop_ = LimitReach{.name = "history.observer_batch_events", .noun = "events", .value = ObservationBatch::event_capacity, .requested = batch.event_count + 1};
    } else {
      drop_ = LimitReach{.name = "history.observer_batch_bytes", .noun = "bytes", .value = ObservationBatch::byte_capacity, .requested = batch.byte_count + incoming};
    }

    batch.clear();
    batch.reset_before = true;
  }

}
