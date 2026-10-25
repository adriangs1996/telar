#pragma once

#include "../execution/execution.hpp"
#include "pane_service.hpp"
#include <csignal>

namespace telar::runtime {

template <Allocator Memory, EventLoop Poller>
class ExecutionService {
public:
  explicit ExecutionService(Memory &memory, RuntimeModel<Memory> &model, Poller &poller)
      : memory_(memory),
        model_(model),
        poller_(poller),
        executions_(memory) {}

  ~ExecutionService() {
    for (auto *execution : executions_.items()) {
      if (execution != nullptr) {
        unwatch(*execution);
      }
    }
  }

  void request(ClientSession<Memory> &client, const ExecutionRequest &request) {
    TELAR_TRACE("execution.request");
    if (request.action == ExecutionAction::list) {
      list(client, request);
      return;
    }

    auto *execution = find(request.execution_id);
    if (execution == nullptr) {
      if (request.action != ExecutionAction::start) {
        throw RequestError{FailureCode::invalid_request, "ExecutionNotFound"};
      }

      execution = &start(client.id, request);
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

    flushInput(*execution);
    send(client, *execution, request);
    if (request.action == ExecutionAction::forget) {
      unwatch(*execution);
      executions_.erase(execution->token);
    }
  }

  void event(const Event &event) {
    auto *execution = executions_.find(eventIdentity(event.token));
    if (execution == nullptr || !execution->process) {
      return;
    }

    auto &process = *execution->process;
    if (eventSource(event.token) == EventSource::execution_input) {
      if (event.descriptor == process.input()) {
        flushInput(*execution);
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

    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return;
    }

    poller_.remove(descriptor);
    if (standard_output) {
      process.closeOutput();
    } else {
      process.closeError();
    }
  }

  bool refresh() noexcept {
    bool running = false;
    for (auto *execution : executions_.items()) {
      if (execution == nullptr || execution->state != ExecutionState::running) {
        continue;
      }

      auto &process = *execution->process;
      if (process.output() >= 0 || process.error() >= 0) {
        running = true;
        continue;
      }

      const auto status = process.reap();
      if (!status) {
        running = true;
        continue;
      }

      execution->exit_code = WIFEXITED(*status) ? WEXITSTATUS(*status) : 128 + WTERMSIG(*status);
      execution->state = ExecutionState::exited;
      execution->eof = true;
      execution->input_owner.reset();
      closeInput(*execution);
    }

    releaseAdministration();
    return running;
  }

  void disconnect(std::uint64_t client_id) {
    for (auto *execution : executions_.items()) {
      if (execution != nullptr && execution->input_owner == client_id) {
        execution->input_owner.reset();
        execution->eof = true;
        flushInput(*execution);
      }
    }
  }

private:
  Execution<Memory> *find(std::uint64_t identity) const noexcept {
    for (auto *execution : executions_.items()) {
      if (execution != nullptr && execution->id == identity) {
        return execution;
      }
    }

    return nullptr;
  }

  Execution<Memory> &start(std::uint64_t client_id, const ExecutionRequest &request) {
    if (executions_.size() == capacity) {
      throw RequestError{FailureCode::resource_limit, "ExecutionLimitReached"};
    }

    const auto token = executions_.nextId();
    const auto workspace_id = request.workspace_id == 0 ? administration() : request.workspace_id;
    const auto *workspace = model_.workspaces.find(workspace_id);
    if (workspace == nullptr) {
      throw RequestError{FailureCode::invalid_request, "WorkspaceNotFound"};
    }

    const std::string_view cwd = request.cwd.empty() ? std::string_view{workspace->path} : request.cwd;
    auto execution = makeOwned<Execution<Memory>>(memory_, memory_, token, request, workspace_id, cwd);
    execution->input_owner = request.stdin_open ? std::optional{client_id} : std::nullopt;
    try {
      if (execution->process) {
        poller_.watch(execution->process->output(), eventToken(EventSource::execution_output, token));
        poller_.watch(execution->process->error(), eventToken(EventSource::execution_error, token));
      }
    } catch (...) {
      unwatch(*execution);
      throw;
    }

    auto *result = execution.get();
    executions_.insert(token, std::move(execution));
    return *result;
  }

  std::uint64_t administration() {
    if (model_.workspaces.find(administration_) != nullptr) {
      return administration_;
    }

    const char *home = std::getenv("HOME");
    if (home == nullptr || home[0] != '/') {
      throw RequestError{FailureCode::invalid_request, "DestinationHomeUnavailable"};
    }

    const auto identity = model_.workspaces.nextId();
    auto workspace = makeOwned<Workspace<Memory>>(memory_, memory_, identity, home, "Administration");
    model_.workspaces.insert(identity, std::move(workspace));
    administration_ = identity;
    ++model_.workspace_revision;
    return identity;
  }

  void releaseAdministration() noexcept {
    if (administration_ == 0) {
      return;
    }

    for (const auto *execution : executions_.items()) {
      if (execution != nullptr && execution->workspace == administration_ && execution->state == ExecutionState::running) {
        return;
      }
    }

    const auto *workspace = model_.workspaces.find(administration_);
    if (workspace != nullptr && workspace->tabs.empty()) {
      model_.workspaces.erase(administration_);
      ++model_.workspace_revision;
    }

    administration_ = 0;
  }

  void receiveInput(Execution<Memory> &execution, std::uint64_t client_id, const ExecutionRequest &request) {
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

    if (request.bytes.size() > Execution<Memory>::input_capacity - execution.input.size()) {
      throw RequestError{FailureCode::invalid_request, "ExecutionBusy"};
    }

    execution.input.append(request.bytes);
    execution.input_written += request.bytes.size();
  }

  void flushInput(Execution<Memory> &execution) {
    if (!execution.process || execution.process->input() < 0) {
      return;
    }

    if (!execution.input.empty()) {
      const auto bytes = execution.input.readable();
      const auto count = ::write(execution.process->input(), bytes.data(), bytes.size());
      if (count > 0) {
        execution.input.consume(static_cast<std::size_t>(count));
      } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        execution.eof = true;
        execution.input.clear();
      }
    }

    if (execution.eof && execution.input.empty()) {
      closeInput(execution);
      return;
    }

    const bool needed = !execution.input.empty();
    if (needed != execution.write_interest) {
      poller_.writeInterest(execution.process->input(), eventToken(EventSource::execution_input, execution.token), needed);
      execution.write_interest = needed;
    }
  }

  void closeInput(Execution<Memory> &execution) noexcept {
    if (execution.process && execution.process->input() >= 0) {
      poller_.remove(execution.process->input());
      execution.process->closeInput();
      execution.write_interest = false;
    }
  }

  void unwatch(Execution<Memory> &execution) noexcept {
    if (!execution.process) {
      return;
    }

    for (const int descriptor : {execution.process->input(), execution.process->output(), execution.process->error()}) {
      if (descriptor >= 0) {
        poller_.remove(descriptor);
      }
    }
  }

  void send(ClientSession<Memory> &client, const Execution<Memory> &execution, const ExecutionRequest &request) {
    std::array<Byte, 4096> output;
    std::array<Byte, 4096> error;
    const auto output_offset = std::max(request.stdout_offset, execution.output.retainedOffset());
    const auto error_offset = std::max(request.stderr_offset, execution.error.retainedOffset());
    client.connection.send(ExecutionReply{
        .request_id = request.request_id,
        .execution_id = execution.id,
        .workspace_id = execution.workspace,
        .stdout_offset = output_offset,
        .stderr_offset = error_offset,
        .stdout_total = execution.output.total(),
        .stderr_total = execution.error.total(),
        .input_offset = execution.input_written,
        .input_available = Execution<Memory>::input_capacity - execution.input.size(),
        .state = execution.state,
        .exit_code = execution.exit_code,
        .stdin_open = !execution.eof,
        .failure = {reinterpret_cast<const Byte *>(execution.failure_name.data()), execution.failure_name.size()},
        .stdout_bytes = execution.output.read(output_offset, output),
        .stderr_bytes = execution.error.read(error_offset, error),
    });
  }

  void list(ClientSession<Memory> &client, const ExecutionRequest &request) {
    const Execution<Memory> *selected = nullptr;
    for (const auto *execution : executions_.items()) {
      if (execution != nullptr && execution->id > request.execution_id && (selected == nullptr || execution->id < selected->id)) {
        selected = execution;
      }
    }

    ExecutionReply reply{.request_id = request.request_id,
                         .state = ExecutionState::exited};
    if (selected != nullptr) {
      reply.execution_id = selected->id;
      reply.workspace_id = selected->workspace;
      reply.state = selected->state;
      reply.exit_code = selected->exit_code;
    }

    client.connection.send(reply);
  }

  static constexpr std::size_t capacity = 32;
  Memory &memory_;
  RuntimeModel<Memory> &model_;
  Poller &poller_;
  SlotStore<Execution<Memory>, capacity, Memory> executions_;
  std::uint64_t administration_ = 0;
};

}
