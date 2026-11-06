#pragma once

#include "../model/runtime_model.hpp"
#include "../platform/descent_probe.hpp"
#include "../platform/observation_worker.hpp"
#include "telar_client/request_error.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, LineageInspector Inspector>
class DescentService {
public:
  explicit DescentService(RuntimeModel<Memory> &model, const Inspector &inspector)
      : model_(model),
        probe_(inspector),
        worker_(probe_) {}

  void verify(ClientSession<Memory> &client, const VerifyPaneDescent &request) {
    const auto *pane = model_.panes.find(request.pane_id);
    if (pane == nullptr || request.pane_generation == 0 || pane->generation != request.pane_generation || pane->exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }
    if (client.pending_descent) {
      throw RequestError{FailureCode::resource_limit, "A descent verification is already pending"};
    }

    client.verified_pane = 0;
    client.verified_generation = 0;
    client.verified_lineage = {};
    if (!client.peer_identity || pane->process->processId() <= 0) {
      throw RequestError{FailureCode::foreign_process, "The process does not descend from this pane"};
    }

    client.pending_descent = DescentCheck{client.id, client.generation, pane->id, pane->generation, request.request_id, *client.peer_identity, pane->process->processId()};
    client.connection.read_paused = true;
    schedule();
  }

  void collect() {
    if (!pending_) {
      return;
    }

    worker_.collect([this](const typename DescentProbe<Inspector>::Result &result) {
      pending_ = false;
      for (const auto &completed : std::span{result.checks}.first(result.count)) {
        finish(completed);
      }
      schedule();
    });
  }

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  void schedule() {
    if (pending_) {
      return;
    }

    typename DescentProbe<Inspector>::Request request;
    for (auto *client : model_.clients.items()) {
      if (client != nullptr && client->pending_descent && !client->descent_running && !client->connection.closing) {
        request.checks[request.count++] = *client->pending_descent;
      }
    }
    if (request.count == 0 || !worker_.submit(request)) {
      return;
    }

    pending_ = true;
    for (const auto &check : std::span{request.checks}.first(request.count)) {
      model_.clients.find(check.client)->descent_running = true;
    }
  }

  void finish(const typename DescentProbe<Inspector>::Completion &completed) noexcept {
    const auto &check = completed.check;
    auto *client = model_.clients.find(check.client);
    if (client == nullptr || client->generation != check.client_generation) {
      return;
    }

    client->pending_descent.reset();
    client->descent_running = false;
    client->connection.read_paused = false;
    if (client->connection.closing) {
      return;
    }

    try {
      const auto *pane = model_.panes.find(check.pane);
      if (pane == nullptr || pane->generation != check.pane_generation || pane->exit_status) {
        client->connection.send(RequestFailed{.request_id = check.request_id, .code = FailureCode::pane_not_found, .message = "Pane not found"});
      } else if (!completed.lineage.descends) {
        client->connection.send(RequestFailed{.request_id = check.request_id, .code = FailureCode::foreign_process, .message = "The process does not descend from this pane"});
      } else {
        client->verified_pane = pane->id;
        client->verified_generation = pane->generation;
        client->verified_lineage = completed.lineage;
        client->connection.send(RequestCompleted{.request_id = check.request_id});
      }
    } catch (...) {
      client->connection.closing = true;
    }
  }

  RuntimeModel<Memory> &model_;
  DescentProbe<Inspector> probe_;
  ObservationWorker<DescentProbe<Inspector>> worker_;
  bool pending_ = false;
};

}
