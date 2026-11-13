#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>
#include <cerrno>
#include <cassert>
#include "telar_base/diagnostics/config.hpp"
#include <pthread.h>
#include <poll.h>

import std;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.platform.request_worker;

using namespace telar;
using namespace telar::runtime;

class HistoryQueueGate {
public:
  explicit HistoryQueueGate(std::uint64_t blocked_request) : blocked_request_(blocked_request) {}

  template <Allocator Memory>
  void process(std::span<const Byte> payload, EncodedReply<Memory> &reply) {
    std::array<Byte, 256> bytes;
    DecodeStorage storage{bytes};
    const auto request = payload.front() == static_cast<Byte>(ClientTag::query_history)
                             ? Codec::decode<QueryHistory>(payload, storage).request_id
                             : Codec::decode<QueryClients>(payload, storage).request_id;
    if (request == blocked_request_) {
      std::unique_lock lock{mutex_};
      entered_ = true;
      ready_.notify_one();
      ready_.wait(lock, [&] { return released_; });
    }

    reply.send(RequestCompleted{.request_id = request});
  }

  void wait() {
    std::unique_lock lock{mutex_};
    check(ready_.wait_for(lock, std::chrono::seconds{2}, [&] { return entered_; }));
  }

  void release() {
    const std::lock_guard lock{mutex_};
    released_ = true;
    ready_.notify_one();
  }

private:
  std::uint64_t blocked_request_;
  std::mutex mutex_;
  std::condition_variable ready_;
  bool entered_ = false;
  bool released_ = false;
};

struct HistoryQueueCase {
  QueryHistory first{.request_id = 1, .limit = 10};
  QueryHistory second{.request_id = 2, .limit = 10};
  bool first_persistent = true;
  bool second_persistent = true;
  bool same_client = true;
  bool barrier = false;
  bool superseded = false;
};

template <typename Worker>
static void collectHistoryQueue(Worker &worker, std::size_t expected, bool superseded) {
  std::size_t completed = 0;
  std::size_t failures = 0;
  while (completed != expected) {
    pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};
    check(::poll(&ready, 1, 2000) == 1);
    worker.collect([&](std::uint64_t client, ClientTag, std::span<const Byte> payload) {
      ++completed;
      if (payload.front() != static_cast<Byte>(ServerTag::request_failed)) {
        return;
      }

      std::array<Byte, 256> bytes;
      DecodeStorage storage{bytes};
      const auto failure = Codec::decode<RequestFailed>(payload, storage);
      check(client == 1 && failure.request_id == 1 && failure.code == FailureCode::internal && failure.message == "History query superseded");
      ++failures;
    });
  }

  check(failures == static_cast<std::size_t>(superseded));
  check(!worker.pending());
}

static void checkHistoryQueue(SystemAllocator &memory, const HistoryQueueCase &scenario) {
  HistoryQueueGate service{100};
  RequestWorker worker{memory, service};
  worker.submit(1, QueryClients{.request_id = 100});
  service.wait();
  worker.submit(1, scenario.first, RequestContext{.persistent_client = scenario.first_persistent});
  if (scenario.barrier) {
    worker.submit(1, QueryClients{.request_id = 200});
  }

  worker.submit(scenario.same_client ? 1 : 2, scenario.second, RequestContext{.persistent_client = scenario.second_persistent});
  service.release();
  collectHistoryQueue(worker, scenario.barrier ? 4 : 3, scenario.superseded);
}

void testHistoryQueue() {
  SystemAllocator memory;
  checkHistoryQueue(memory, HistoryQueueCase{.superseded = true});
  checkHistoryQueue(memory, HistoryQueueCase{.first_persistent = false});
  checkHistoryQueue(memory, HistoryQueueCase{.second_persistent = false});
  checkHistoryQueue(memory, HistoryQueueCase{.same_client = false});
  checkHistoryQueue(memory, HistoryQueueCase{.barrier = true});
  auto same_request = HistoryQueueCase{};
  same_request.second.request_id = same_request.first.request_id;
  checkHistoryQueue(memory, same_request);

  enum class QueryField { offset,
                          snapshot,
                          entry,
                          distinct };
  for (const auto field : {QueryField::offset, QueryField::snapshot, QueryField::entry, QueryField::distinct}) {
    for (bool first : {false, true}) {
      HistoryQueueCase scenario;
      auto &query = first ? scenario.first : scenario.second;
      switch (field) {
      case QueryField::offset:
        query.offset = 1;
        break;
      case QueryField::snapshot:
        query.snapshot_id = 1;
        break;
      case QueryField::entry:
        query.entry_id = 1;
        break;
      case QueryField::distinct:
        query.distinct = true;
        break;
      }

      checkHistoryQueue(memory, scenario);
    }
  }

  HistoryQueueGate service{1};
  RequestWorker worker{memory, service};
  worker.submit(1, QueryHistory{.request_id = 1, .limit = 10}, RequestContext{.persistent_client = true});
  service.wait();
  worker.submit(1, QueryHistory{.request_id = 2, .limit = 10}, RequestContext{.persistent_client = true});
  service.release();
  collectHistoryQueue(worker, 2, false);
}
