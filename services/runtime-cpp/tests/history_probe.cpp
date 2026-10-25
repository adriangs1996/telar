#include "protocol_peer.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/telar_client.hpp"
#include <chrono>
#include <cstdio>
#include <fstream>
#include <vector>

using namespace telar;

class HistoryProbe {
public:
  explicit HistoryProbe(const char *socket_path, const char *output_path)
      : socket_path_(socket_path),
        output_(output_path, std::ios::binary),
        outgoing_(max_payload_size + frame_prefix_size),
        incoming_(max_payload_size),
        scratch_(128 * 1024) {}

  template <typename Reply, typename Request>
  Reply exchange(const Request &request) {
    auto client = Client::init(socket_path_);
    try {
      client.handshake();
      const timeval timeout{.tv_sec = 5,
                            .tv_usec = 0};
      ::setsockopt(client.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
      client.send(request, outgoing_);
      const auto payload = client.receiveFrame(incoming_);
      DecodeStorage storage{scratch_};
      if (payload.front() == static_cast<Byte>(ServerTag::request_failed)) {
        const auto failure = Codec::decode<RequestFailed>(payload, storage);
        std::fprintf(stderr, "request %llu: %.*s\n", static_cast<unsigned long long>(failure.request_id), static_cast<int>(failure.message.size()), failure.message.data());
      }

      const auto reply = Codec::decode<Reply>(payload, storage);
      output_.write(reinterpret_cast<const char *>(payload.data()), static_cast<std::streamsize>(payload.size()));
      client.deinit();
      return reply;
    } catch (...) {
      client.deinit();
      throw;
    }
  }

private:
  const char *socket_path_;
  std::ofstream output_;
  std::vector<Byte> outgoing_;
  std::vector<Byte> incoming_;
  std::vector<Byte> scratch_;
};

template <typename Request>
static void checkUnavailable(HistoryProbe &probe, const Request &request) {
  const auto reply = probe.exchange<RequestFailed>(request);
  if (reply.request_id != request.request_id || reply.code != FailureCode::internal || reply.message != "history database is unavailable") {
    throw std::runtime_error{"Unavailable history returned an unexpected failure"};
  }
}

static void checkDegradedHistory(HistoryProbe &probe) {
  checkUnavailable(probe, QueryHistory{.request_id = 1, .limit = 10});
  checkUnavailable(probe, ReadHistoryOutput{.request_id = 2, .id = 1});
  checkUnavailable(probe, HistoryStatsQuery{.request_id = 3});
  const auto removed = probe.exchange<HistoryPruned>(DeleteHistory{.request_id = 4, .id = 1}).removed;
  const auto pruned = probe.exchange<HistoryPruned>(PruneHistory{.request_id = 5}).removed;
  if (removed != 0 || pruned != 0) {
    throw std::runtime_error{"Unavailable history removed entries"};
  }

  const std::array<ImportHistoryEntry, 1> entries{{{100, "echo unavailable"}}};
  const auto imported = probe.exchange<RequestCompleted>(ImportHistory{.request_id = 6, .source = "unavailable-history", .entries = entries});
  if (imported.request_id != 6) {
    throw std::runtime_error{"Unavailable history rejected an import"};
  }
  checkUnavailable(probe, QueryHistory{.request_id = 7, .limit = 10});
}

static void disconnectWithQueuedImports(const char *socket) {
  ProtocolPeer peer{socket};
  peer.send(RequestRuntimeState{.client_identity = 851, .interactive = false});
  peer.receive<WorkspaceList>();
  for (std::uint64_t sequence = 1; sequence <= 3; ++sequence) {
    const std::array<ImportHistoryEntry, 1> entries{{{100, "retained import"}}};
    peer.send(ImportHistory{.request_id = sequence, .source = "disconnected-client", .base_sequence = sequence, .entries = entries});
  }

  peer.exchange<ClientList>(QueryClients{.request_id = 4});
}

int main(int argc, char **argv) {
  if (argc != 5) {
    std::fputs("usage: history-probe SOCKET history ITERATIONS DUMP\n", stderr);
    return 2;
  }

  try {
    if (std::string_view{argv[2]} == "history-disconnect") {
      disconnectWithQueuedImports(argv[1]);
      return 0;
    }
    HistoryProbe probe{argv[1], argv[4]};
    const auto started = std::chrono::steady_clock::now();
    if (std::string_view{argv[2]} == "history-unavailable") {
      checkDegradedHistory(probe);
      std::puts("{\"requests\":7,\"passed\":true}");
      return 0;
    }
    if (std::string_view{argv[2]} == "history-retained") {
      const auto result = probe.exchange<HistoryResults>(QueryHistory{.request_id = 4, .limit = 10});
      if (result.entries.size() != 3) {
        throw std::runtime_error{"Imports were lost after disconnect: " + std::to_string(result.entries.size()) + " retained"};
      }
      return 0;
    }
    const std::array<ImportHistoryEntry, 6> entries{{
        {100, "git status"},
        {200, "git status"},
        {300, "git status"},
        {400, "cargo build"},
        {500, "cargo build"},
        {600, "printf 'café'"},
    }};
    const ImportHistory import{.request_id = 1,
                               .source = "history-probe-source-longer-than-forty-eight-bytes-for-identity-compatibility",
                               .base_sequence = 10,
                               .entries = entries};
    probe.exchange<RequestCompleted>(import);
    probe.exchange<RequestCompleted>(import);
    const auto first = probe.exchange<HistoryResults>(QueryHistory{.request_id = 2,
                                                                   .limit = 2});
    const auto snapshot = first.snapshot_id;
    const auto newest = first.entries.front().id;
    probe.exchange<HistoryResults>(QueryHistory{.request_id = 3,
                                                .limit = 2,
                                                .offset = 2,
                                                .snapshot_id = snapshot});
    probe.exchange<HistoryResults>(QueryHistory{.request_id = 4,
                                                .query = "GST",
                                                .match = HistoryMatch::fuzzy,
                                                .distinct = true,
                                                .limit = 10});
    probe.exchange<HistoryResults>(QueryHistory{.request_id = 5,
                                                .query = "café",
                                                .limit = 10});
    probe.exchange<HistoryResults>(QueryHistory{.request_id = 6,
                                                .scope = HistoryScope::cwd,
                                                .scope_value = std::string_view{"/missing"},
                                                .limit = 10});
    probe.exchange<HistoryStatsResult>(HistoryStatsQuery{.request_id = 7});
    probe.exchange<HistoryOutput>(ReadHistoryOutput{.request_id = 8,
                                                    .id = newest});
    probe.exchange<HistoryPruned>(DeleteHistory{.request_id = 9,
                                                .id = newest});
    probe.exchange<HistoryPruned>(PruneHistory{.request_id = 10,
                                               .before_ms = 400,
                                               .match = "git"});
    probe.exchange<HistoryResults>(QueryHistory{.request_id = 11,
                                                .limit = 10});
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"iterations\":1,\"elapsed_ns\":%lld,\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed), static_cast<long long>(elapsed));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "history-probe: %s\n", error.what());
    return 1;
  }
}
