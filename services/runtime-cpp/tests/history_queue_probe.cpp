#include <cstdio>

import std;
import telar.runtime.tests.protocol_peer;

using namespace telar;

static void waitForRelease() {
  std::puts("queued");
  std::fflush(stdout);
  if (std::getchar() != '\n') {
    throw std::runtime_error{"History queue fixture lost its release signal"};
  }
}

static void checkAdmission(const char *socket, const char *path) {
  ProtocolPeer peer{socket};
  const std::array<ImportHistoryEntry, 1> entries{{{10000, "retained"}}};
  peer.exchange<RequestCompleted>(ImportHistory{.request_id = 1, .source = "admission-fixture", .entries = entries});
  waitForRelease();

  ProtocolPeer query{socket};
  const auto result = query.exchange<HistoryResults>(QueryHistory{.request_id = 2, .limit = 10});
  if (result.entries.size() != 1 || result.entries.front().command != "retained") {
    throw std::runtime_error{"An acknowledged import was not persisted"};
  }

  std::ofstream output{path, std::ios::binary};
  query.record(output, result);
}

static void checkCapacity(const char *socket, const char *path) {
  ProtocolPeer peer{socket};
  peer.send(RequestRuntimeState{.client_identity = 852, .interactive = true});
  peer.receive<WorkspaceList>();
  const std::array<ImportHistoryEntry, 1> entries{{{10000, "retained"}}};
  peer.exchange<RequestCompleted>(ImportHistory{.request_id = 1, .source = "capacity-fixture", .entries = entries});

  // The initial write must enter SQLite's busy wait before the pending queue fills.
  std::this_thread::sleep_for(std::chrono::milliseconds{100});
  std::ofstream output{path, std::ios::binary};
  for (std::uint64_t sequence = 1; sequence <= 65; ++sequence) {
    peer.send(ImportHistory{.request_id = sequence + 1, .source = "capacity-fixture", .base_sequence = sequence, .entries = entries});
    const auto reply = peer.receiveAny<RequestCompleted, RequestFailed>();
    std::visit([&](const auto &message) { peer.record(output, message); }, reply);
  }

  const auto rejected = [&](const auto &request) {
    peer.send(request);
    const auto failure = peer.receive<RequestFailed>();
    if (failure.request_id != request.request_id || failure.code != FailureCode::resource_limit) {
      throw std::runtime_error{"A saturated history queue returned an unexpected failure"};
    }
    peer.record(output, failure);
  };
  rejected(QueryHistory{.request_id = 100, .limit = 10});
  rejected(HistoryStatsQuery{.request_id = 101});
  rejected(DeleteHistory{.request_id = 102, .id = 1});
  rejected(PruneHistory{.request_id = 103});
  rejected(ReadHistoryOutput{.request_id = 104, .id = 1});
  waitForRelease();

  // Admission can resume as soon as the worker drains the pending batch.
  for (unsigned attempt = 0; attempt < 100; ++attempt) {
    peer.send(QueryHistory{.request_id = 200, .limit = 100});
    const auto reply = peer.receiveAny<HistoryResults, RequestFailed>();
    if (const auto *result = std::get_if<HistoryResults>(&reply)) {
      peer.record(output, *result);
      return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
  throw std::runtime_error{"History admission did not resume after SQLite was released"};
}

int main(int count, char **arguments) {
  if (count != 3 && count != 4) {
    return 2;
  }

  try {
    if (count == 4 && std::string_view{arguments[3]} == "admission") {
      checkAdmission(arguments[1], arguments[2]);
      return 0;
    }

    if (count == 4 && std::string_view{arguments[3]} == "capacity") {
      checkCapacity(arguments[1], arguments[2]);
      return 0;
    }

    ProtocolPeer peer{arguments[1]};
    peer.send(RequestRuntimeState{.client_identity = 852, .interactive = true});
    peer.receive<WorkspaceList>();
    const std::array<ImportHistoryEntry, 1> entries{{{10000, "retained"}}};
    peer.send(ImportHistory{.request_id = 1, .source = "queue-fixture", .entries = entries});
    peer.send(QueryHistory{.request_id = 10, .query = "outdated", .limit = 10});
    peer.send(QueryHistory{.request_id = 11, .query = "retained", .limit = 10});
    peer.send(HistoryStatsQuery{.request_id = 20});
    peer.send(QueryHistory{.request_id = 12, .limit = 10, .offset = 1});
    peer.send(QueryHistory{.request_id = 13, .limit = 10, .snapshot_id = 1});
    peer.send(QueryHistory{.request_id = 14, .limit = 10, .entry_id = 1});
    peer.send(QueryHistory{.request_id = 15, .distinct = true, .limit = 10});
    peer.send(QueryHistory{.request_id = 16, .limit = 10});
    peer.send(QueryHistory{.request_id = 17, .distinct = true, .limit = 10});
    peer.send(ImportHistory{.request_id = 30, .source = "queue-fixture", .base_sequence = 1, .entries = entries});
    peer.send(QueryHistory{.request_id = 18, .limit = 10});
    peer.exchange<ClientList>(QueryClients{.request_id = 100});
    waitForRelease();

    std::ofstream output{arguments[2], std::ios::binary};
    for (unsigned response = 0; response < 9; ++response) {
      const auto reply = peer.receiveAny<HistoryResults, RequestFailed>();
      std::visit([&](const auto &message) { peer.record(output, message); }, reply);
    }

    if (!output.good()) {
      throw std::runtime_error{"Could not save queued history responses"};
    }
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
