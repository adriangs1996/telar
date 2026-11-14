module;
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

module telar.runtime.runtime.execution_service;

import telar.sys.process;

namespace telar::runtime {

  void LimitService::receive(RuntimeLimits& limits, ClientSession& client, const ReportLimit& message) {
    if (!admit(limits, client)) {
      return;
    }

    const auto recorded = limits.clients.record(message.reach, message.hits);
    if (recorded.show && client.role == ClientRole::control) {
      queueShow(Ledger::clients, recorded.slot);
    }
  }

  void LimitService::report(const LimitReach& reach) noexcept {
    if (reports_ == reached_.size()) {
      dropped_ = saturatedAdd(dropped_, 1);
      return;
    }

    auto& copy = reached_[reports_++];

    copy.name.assign(reach.name);
    copy.noun.assign(reach.noun);
    copy.route.assign(reach.route);
    copy.value = reach.value;
    copy.requested = reach.requested;
  }

  void LimitService::query(ClientSession& client, const QueryLimits& request) {
    client.connection.defer(request);
  }

  void LimitService::deliver(RuntimeModel& model, ClientStore& clients) noexcept {
    for (const auto& reached : std::span{reached_}.first(reports_)) {
      const auto recorded = model.limits.runtime.record({reached.name.view(), reached.noun.view(), reached.value, reached.requested, reached.route.view()}, 1);
      if (recorded.show) {
        queueShow(Ledger::runtime, recorded.slot);
      }
    }

    reports_ = 0;
    if (dropped_ != 0) {
      model.limits.refused_reports = saturatedAdd(model.limits.refused_reports, dropped_);
      dropped_ = 0;
    }

    for (const auto& [ledger, slot] : std::span{shown_}.first(shows_)) {
      const auto rows = (ledger == Ledger::clients ? model.limits.clients : model.limits.runtime).rows();
      if (slot < rows.size()) {
        show(clients, rows[slot]);
      }
    }

    shows_ = 0;
  }

  void LimitService::queueShow(Ledger ledger, std::size_t slot) noexcept {
    if (shows_ < shown_.size()) {
      shown_[shows_++] = {ledger, slot};
    }
  }

  bool LimitService::admit(RuntimeLimits& limits, ClientSession& client) noexcept {
    const auto now = std::chrono::steady_clock::now();
    if (now - client.limit_report_window >= std::chrono::seconds{1}) {
      client.limit_report_window = now;
      client.limit_reports = 0;
    }

    if (client.limit_reports == reports_per_second) {
      limits.refused_reports = saturatedAdd(limits.refused_reports, 1);
      return false;
    }

    ++client.limit_reports;
    return true;
  }

  void LimitService::show(ClientStore& clients, const LimitLedger::Row& row) noexcept {
    std::array<char, 256> text{};
    const auto reach = row.reach();
    const char* separator = reach.noun.empty() ? "" : " ";
    int length = 0;

    if (reach.requested) {
      length = std::snprintf(text.data(), text.size(), "%.*s: %llu%s%.*s; limit %llu", static_cast<int>(reach.name.size()), reach.name.data(), static_cast<unsigned long long>(*reach.requested), separator, static_cast<int>(reach.noun.size()), reach.noun.data(), static_cast<unsigned long long>(reach.value));
    } else if (reach.value == 0) {
      length = std::snprintf(text.data(), text.size(), "%.*s: limit reached", static_cast<int>(reach.name.size()), reach.name.data());
    } else {
      length = std::snprintf(text.data(), text.size(), "%.*s: limit %llu%s%.*s reached", static_cast<int>(reach.name.size()), reach.name.data(), static_cast<unsigned long long>(reach.value), separator, static_cast<int>(reach.noun.size()), reach.noun.data());
    }

    if (row.hits > 1) {
      length += std::snprintf(text.data() + length, text.size() - length, " (%llu times)", static_cast<unsigned long long>(row.hits));
    }

    const Notification notification{NotificationBody{.level = NotificationLevel::warning, .duration_ms = 8000, .title = "Limit reached", .message = {text.data(), static_cast<std::size_t>(length)}}};

    broadcast(clients, [](const ClientSession& client) {
      return client.role == ClientRole::interactive;
    },
        notification);
  }

  template <EventLoop Poller>
  ClientAdmission<Poller>::ClientAdmission(Poller& poller, LimitService& limits)
      : poller_(poller),
        limits_(limits) {}

  template <EventLoop Poller>
  ClientAdmission<Poller>::~ClientAdmission() {
    clear();
  }

  template <EventLoop Poller>
  void ClientAdmission<Poller>::begin(std::size_t clients, FileDescriptor descriptor) {
    constexpr std::size_t maximum_clients = client_capacity;
    std::size_t reserved = 0;

    for (const auto& pending : pending_) {
      reserved += pending && pending->reservesClient();
    }

    const auto requested = clients + reserved + 1;
    const bool refused = requested > maximum_clients;
    if (refused) {
      limits_.report({"clients.max_clients", "clients", maximum_clients, requested, {}});
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot] || generations_[slot] >= maximum_event_identity / capacity - 1) {
        continue;
      }

      ++generations_[slot];
      pending_[slot].emplace(std::move(descriptor), refused);
      ++count_;
      try {
        poller_.watch(pending_[slot]->descriptor(), token(slot));
      } catch (...) {
        drop(slot);
        throw;
      }

      return;
    }

    limits_.report({"clients.max_pending_handshakes", "handshakes", capacity, {}, {}});
  }

  template <EventLoop Poller>
  void ClientAdmission<Poller>::expire(std::chrono::steady_clock::time_point now) noexcept {
    if (count_ == 0) {
      return;
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot] && pending_[slot]->expired(now)) {
        drop(slot);
      }
    }
  }

  template <EventLoop Poller>
  void ClientAdmission<Poller>::clear() noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot]) {
        drop(slot);
      }
    }
  }

  template <EventLoop Poller>
  std::optional<FileDescriptor> ClientAdmission<Poller>::advance(const Event& event) {
    const auto slot = eventIdentity(event.token) % capacity;
    auto& pending = pending_[slot];
    if (!pending || event.token != token(slot) || event.descriptor != pending->descriptor()) {
      return std::nullopt;
    }

    try {
      if (event.kind == EventKind::readable) {
        pending->read();
      }

      pending->write();
      switch (pending->stage()) {
      case ClientHandshake::Stage::accepted: {
        poller_.remove(pending->descriptor());
        auto descriptor = pending->takeDescriptor();

        pending.reset();
        --count_;
        return descriptor;
      }
      case ClientHandshake::Stage::rejected:
        drop(slot);
        break;
      case ClientHandshake::Stage::reply:
        poller_.readInterest(pending->descriptor(), event.token, false);
        poller_.writeInterest(pending->descriptor(), event.token, true);
        break;
      case ClientHandshake::Stage::prefix:
      case ClientHandshake::Stage::hello:
        break;
      }
    } catch (const std::exception&) {
      if (pending) {
        drop(slot);
      }
    }

    return std::nullopt;
  }

  template <EventLoop Poller>
  std::uint64_t ClientAdmission<Poller>::token(std::size_t slot) const noexcept {
    return eventToken(EventSource::handshake, generations_[slot] * capacity + slot);
  }

  template <EventLoop Poller>
  void ClientAdmission<Poller>::drop(std::size_t slot) noexcept {
    poller_.remove(pending_[slot]->descriptor());
    pending_[slot].reset();
    --count_;
  }

  template class ClientAdmission<NativeEventLoop<ConcurrentMemory>>;

  void notifyWorkspaceObservers(ClientStore& clients, std::uint64_t workspace, std::uint64_t origin, std::optional<std::uint64_t> previous) noexcept {
    for (auto* client : clients.items()) {
      if (client != nullptr && client->id != origin && client->connection.negotiated && !client->connection.closing && client->workspace == workspace) {
        client->workspace_resync = ResyncRequired{.workspace = {.id = workspace}, .previous_workspace = previous};
      }
    }
  }

  std::optional<std::uint64_t> previousWorkspace(const WorkspaceStore& workspaces, std::uint64_t identity) noexcept {
    const auto items = workspaces.items();

    for (std::size_t index = 0; index < items.size(); ++index) {
      if (items[index] == nullptr || items[index]->id != identity) {
        continue;
      }

      for (std::size_t offset = 1; offset < items.size(); ++offset) {
        const auto* previous = items[(index + items.size() - offset) % items.size()];
        if (previous != nullptr) {
          return previous->id;
        }
      }

      break;
    }

    return std::nullopt;
  }

  bool acquireGeometry(PaneStore& panes, [[maybe_unused]] diagnostics::RuntimeCounters& metrics, const ClientSession& client, Workspace& workspace) {
    if (workspace.geometry_client) {
      TELAR_DIAGNOSTIC(if (*workspace.geometry_client != client.id) { diagnostics::accumulate(metrics.geometry_rejections); });
      return *workspace.geometry_client == client.id;
    }

    workspace.geometry_client = client.id;
    for (auto* pane : panes.items()) {
      if (pane != nullptr && pane->location.workspace.id == workspace.id) {
        if (!pane->desktop_theme) {
          pane->terminal.configureColors(client.colors);
          pane->resumeControl();
        }
      }
    }

    return true;
  }

  void releaseGeometry(ClientStore& clients, std::uint64_t client, Workspace& workspace) noexcept {
    if (workspace.geometry_client == client) {
      workspace.geometry_client.reset();
      notifyWorkspaceObservers(clients, workspace.id, client);
    }
  }

  void releaseAllGeometry(WorkspaceStore& workspaces, ClientStore& clients, std::uint64_t client) noexcept {
    for (auto* workspace : workspaces.items()) {
      if (workspace != nullptr) {
        releaseGeometry(clients, client, *workspace);
      }
    }
  }

  std::string_view launchFailureCause(const std::exception& error) noexcept {
    if (dynamic_cast<const std::bad_alloc*>(&error) != nullptr) {
      return "OutOfMemory";
    }

    if (const auto* request = dynamic_cast<const RequestError*>(&error)) {
      return request->code() == FailureCode::resource_limit ? "PaneLimitReached" : "Unexpected";
    }

    if (const auto* system = dynamic_cast<const SystemError*>(&error)) {
      return sys::errorName(system->code());
    }

    return "Unexpected";
  }

  template <EventLoop Poller>
  ExecutionService<Poller>::ExecutionService(ConcurrentMemory& memory, Poller& poller, LimitService& limits)
      : memory_(memory),
        poller_(poller),
        limits_(limits),
        executions_(memory) {}

  template <EventLoop Poller>
  ExecutionService<Poller>::~ExecutionService() {
    for (auto* execution : executions_.items()) {
      if (execution != nullptr) {
        unwatch(poller_, *execution);
      }
    }
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::request(RuntimeModel& model, ClientSession& client, const ExecutionRequest& request) {
    TELAR_TRACE("execution.request");
    if (request.action == ExecutionAction::list) {
      list(client, request);
      return;
    }

    auto* execution = find(request.execution_id);
    const bool started = execution == nullptr;
    if (started) {
      if (request.action != ExecutionAction::start) {
        throw RequestError{FailureCode::invalid_request, "ExecutionNotFound"};
      }

      execution = &start(model, client.id, request);
    }

    if (request.action == ExecutionAction::start && !execution->matches(request)) {
      throw RequestError{FailureCode::invalid_request, "ExecutionIdentityConflict"};
    }

    switch (request.action) {
    case ExecutionAction::input:
      receiveInput(*execution, client.id, request);
      break;
    case ExecutionAction::eof:
      execution->eof = true;
      break;
    case ExecutionAction::cancel:
      if (execution->process) {
        execution->process->signal(SIGKILL);
      }

      break;
    case ExecutionAction::forget:
      if (execution->state != ExecutionState::exited && execution->state != ExecutionState::failed) {
        throw RequestError{FailureCode::invalid_request, "ExecutionStillRunning"};
      }

      break;
    default:
      break;
    }

    flushInput(poller_, *execution);
    send(client, *execution, request, started);
    if (request.action == ExecutionAction::forget) {
      unwatch(poller_, *execution);
      executions_.erase(execution->token);
    }
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::event(const Event& event) {
    auto* execution = executions_.find(eventIdentity(event.token));
    if (execution == nullptr || !execution->process) {
      return;
    }

    auto& process = *execution->process;

    if (eventSource(event.token) == EventSource::execution_input) {
      if (event.descriptor == process.input()) {
        flushInput(poller_, *execution);
      }

      return;
    }

    const bool standard_output = eventSource(event.token) == EventSource::execution_output;
    const int descriptor = standard_output ? process.output() : process.error();
    if (event.descriptor != descriptor) {
      return;
    }

    std::array<Byte, 16 * 1024> bytes;
    const auto count = ::read(descriptor, bytes.data(), bytes.size());
    if (count > 0) {
      (standard_output ? execution->output : execution->error).append(std::span{bytes}.first(static_cast<std::size_t>(count)));
      return;
    }

    if (count < 0 && socketWouldBlock(sys::lastError())) {
      return;
    }

    poller_.remove(descriptor);
    if (standard_output) {
      process.closeOutput();
    } else {
      process.closeError();
    }
  }

  template <EventLoop Poller>
  bool ExecutionService<Poller>::refresh(RuntimeModel& model) noexcept {
    bool running = false;

    for (auto* execution : executions_.items()) {
      if (execution == nullptr || execution->state != ExecutionState::running) {
        continue;
      }

      auto& process = *execution->process;
      if (process.output() >= 0 || process.error() >= 0) {
        running = true;
        continue;
      }

      const auto status = process.reap();
      if (!status) {
        running = true;
        continue;
      }

      execution->exit_code = shellExitCode(*status);
      execution->state = ExecutionState::exited;
      execution->eof = true;
      execution->input_owner.reset();
      closeInput(poller_, *execution);
    }

    releaseAdministration(model);
    return running;
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::disconnect(std::uint64_t client_id) {
    for (auto* execution : executions_.items()) {
      if (execution != nullptr && execution->input_owner == client_id) {
        execution->input_owner.reset();
        execution->eof = true;
        flushInput(poller_, *execution);
      }
    }
  }

  template <EventLoop Poller>
  Execution<ConcurrentMemory>* ExecutionService<Poller>::find(std::uint64_t identity) const noexcept {
    for (auto* execution : executions_.items()) {
      if (execution != nullptr && execution->id == identity) {
        return execution;
      }
    }

    return nullptr;
  }

  template <EventLoop Poller>
  Execution<ConcurrentMemory>& ExecutionService<Poller>::start(RuntimeModel& model, std::uint64_t client_id, const ExecutionRequest& request) {
    if (executions_.size() == capacity) {
      limits_.report(LimitReach{.name = "executions.capacity", .noun = "retained executions", .value = capacity, .requested = capacity + 1});
      throw RequestError{FailureCode::resource_limit, "ExecutionLimitReached"};
    }

    const auto token = executions_.nextId();
    const auto workspace_id = request.workspace_id == 0 ? administration(model) : request.workspace_id;
    const auto* workspace = model.workspaces.find(workspace_id);
    if (workspace == nullptr) {
      throw RequestError{FailureCode::invalid_request, "WorkspaceNotFound"};
    }

    const std::string_view cwd = request.cwd.empty() ? std::string_view{workspace->path} : request.cwd;
    auto execution = makeOwned<Execution<ConcurrentMemory>>(memory_, memory_, token, request, workspace_id, cwd);

    execution->input_owner = request.stdin_open ? std::optional{client_id} : std::nullopt;
    try {
      if (execution->process) {
        poller_.watch(execution->process->output(), eventToken(EventSource::execution_output, token));
        poller_.watch(execution->process->error(), eventToken(EventSource::execution_error, token));
      }
    } catch (...) {
      unwatch(poller_, *execution);
      throw;
    }

    executions_.insert(token, std::move(execution));
    return *executions_.find(token);
  }

  template <EventLoop Poller>
  std::uint64_t ExecutionService<Poller>::administration(RuntimeModel& model) {
    if (model.workspaces.find(administration_) != nullptr) {
      return administration_;
    }

    const char* home = std::getenv("HOME");
    if (home == nullptr || home[0] != '/') {
      throw RequestError{FailureCode::invalid_request, "DestinationHomeUnavailable"};
    }

    const auto identity = model.workspaces.nextId();
    auto workspace = makeOwned<Workspace>(memory_, memory_, identity, home, "Administration");

    model.workspaces.insert(identity, std::move(workspace));
    administration_ = identity;
    ++model.workspace_revision;
    return identity;
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::releaseAdministration(RuntimeModel& model) noexcept {
    if (administration_ == 0) {
      return;
    }

    for (const auto* execution : executions_.items()) {
      if (execution != nullptr && execution->workspace == administration_ && execution->state == ExecutionState::running) {
        return;
      }
    }

    const auto* workspace = model.workspaces.find(administration_);
    if (workspace != nullptr && workspace->tabs.empty()) {
      model.workspaces.erase(administration_);
      ++model.workspace_revision;
    }

    administration_ = 0;
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::receiveInput(Execution<ConcurrentMemory>& execution, std::uint64_t client_id, const ExecutionRequest& request) {
    if (execution.input_owner != client_id) {
      throw RequestError{FailureCode::invalid_request, "ExecutionInputOwned"};
    }

    if (request.input_offset > execution.input_written) {
      throw RequestError{FailureCode::invalid_request, "ExecutionInputGap"};
    }

    if (request.input_offset < execution.input_written) {
      if (request.bytes.size() > execution.input_written - request.input_offset) {
        throw RequestError{FailureCode::invalid_request, "ExecutionInputOverlap"};
      }

      return;
    }

    if (execution.eof) {
      throw RequestError{FailureCode::invalid_request, "ExecutionInputClosed"};
    }

    if (request.bytes.size() > Execution<ConcurrentMemory>::input_capacity - execution.input.size()) {
      throw RequestError{FailureCode::invalid_request, "ExecutionBusy"};
    }

    execution.input.append(request.bytes);
    execution.input_written += request.bytes.size();
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::flushInput(Poller& poller, Execution<ConcurrentMemory>& execution) {
    if (!execution.process || execution.process->input() < 0) {
      return;
    }

    if (!execution.input.empty()) {
      const auto bytes = execution.input.readable();
      const auto count = ::write(execution.process->input(), bytes.data(), bytes.size());
      if (count > 0) {
        execution.input.consume(static_cast<std::size_t>(count));
      } else if (count < 0 && !socketWouldBlock(sys::lastError())) {
        execution.eof = true;
        execution.input.clear();
      }
    }

    if (execution.eof && execution.input.empty()) {
      closeInput(poller, execution);
      return;
    }

    const bool needed = !execution.input.empty();
    if (needed != execution.write_interest) {
      poller.writeInterest(execution.process->input(), eventToken(EventSource::execution_input, execution.token), needed);
      execution.write_interest = needed;
    }
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::closeInput(Poller& poller, Execution<ConcurrentMemory>& execution) noexcept {
    if (execution.process && execution.process->input() >= 0) {
      poller.remove(execution.process->input());
      execution.process->closeInput();
      execution.write_interest = false;
    }
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::unwatch(Poller& poller, Execution<ConcurrentMemory>& execution) noexcept {
    if (!execution.process) {
      return;
    }

    for (const int descriptor : {execution.process->input(), execution.process->output(), execution.process->error()}) {
      if (descriptor >= 0) {
        poller.remove(descriptor);
      }
    }
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::send(ClientSession& client, const Execution<ConcurrentMemory>& execution, const ExecutionRequest& request, bool started) {
    const auto state = started && execution.state == ExecutionState::running ? ExecutionState::starting : execution.state;
    std::array<Byte, 4096> output;
    std::array<Byte, 4096> error;
    const auto output_offset = std::max(request.stdout_offset, execution.output.retainedOffset());
    const auto error_offset = std::max(request.stderr_offset, execution.error.retainedOffset());
    // Output older than the retained megabyte is gone; report that limit.
    if (output_offset != request.stdout_offset || error_offset != request.stderr_offset) {
      limits_.report(LimitReach{.name = "executions.retained_bytes", .noun = "bytes per stream", .value = Execution<ConcurrentMemory>::retained_capacity, .requested = std::max(execution.output.total(), execution.error.total())});
    }

    client.connection.send(ExecutionReply{
        .request_id = request.request_id,
        .execution_id = execution.id,
        .workspace_id = execution.workspace,
        .stdout_offset = output_offset,
        .stderr_offset = error_offset,
        .stdout_total = execution.output.total(),
        .stderr_total = execution.error.total(),
        .input_offset = execution.input_written,
        .input_available = Execution<ConcurrentMemory>::input_capacity - execution.input.size(),
        .state = state,
        .exit_code = execution.exit_code,
        .stdin_open = !execution.eof,
        .failure = {reinterpret_cast<const Byte*>(execution.failure_name.data()), execution.failure_name.size()},
        .stdout_bytes = execution.output.read(output_offset, output),
        .stderr_bytes = execution.error.read(error_offset, error),
    });
  }

  template <EventLoop Poller>
  void ExecutionService<Poller>::list(ClientSession& client, const ExecutionRequest& request) {
    const Execution<ConcurrentMemory>* selected = nullptr;

    for (const auto* execution : executions_.items()) {
      if (execution != nullptr && execution->id > request.execution_id && (selected == nullptr || execution->id < selected->id)) {
        selected = execution;
      }
    }

    ExecutionReply reply{.request_id = request.request_id, .state = ExecutionState::exited};

    if (selected != nullptr) {
      reply.execution_id = selected->id;
      reply.workspace_id = selected->workspace;
      reply.state = selected->state;
      reply.exit_code = selected->exit_code;
    }

    client.connection.send(reply);
  }

  template class ExecutionService<NativeEventLoop<ConcurrentMemory>>;

}
