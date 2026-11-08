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

static constexpr std::array<ImportHistoryEntry, 1> history_entries{{{1, "queued import"}}};

class ControlledHistoryService {
public:
  struct InternalRequest {
    template <Allocator Memory>
    explicit InternalRequest(Memory &, std::uint64_t value) : identity(value) {}

    std::uint64_t identity;
  };

  template <Allocator Memory>
  void process(std::span<const Byte> payload, EncodedReply<Memory> &reply, const RequestContext &context = {}) {
    std::array<Byte, 256> bytes;
    DecodeStorage storage{bytes};
    const auto identity = payload.front() == static_cast<Byte>(ClientTag::import_history)
                              ? Codec::decode<ImportHistory>(payload, storage).request_id
                              : Codec::decode<QueryClients>(payload, storage).request_id;
    observe(identity, context.cancelled);
    reply.send(RequestCompleted{.request_id = identity});
  }

  void processInternal(const InternalRequest &event) {
    observe(event.identity, nullptr);
  }

  bool waitStarted(std::size_t count, std::chrono::milliseconds timeout = std::chrono::seconds{2}) {
    std::unique_lock lock{mutex_};
    return changed_.wait_for(lock, timeout, [&] { return started_.size() >= count; });
  }

  void allow(std::size_t count) {
    const std::lock_guard lock{mutex_};
    allowed_ = count;
    changed_.notify_all();
  }

  void stop() noexcept {
    allow(std::numeric_limits<std::size_t>::max());
  }

  std::vector<std::uint64_t> finished() const {
    const std::lock_guard lock{mutex_};
    return finished_;
  }

  bool cancelled(std::uint64_t identity) const {
    const std::lock_guard lock{mutex_};
    return std::find(cancelled_.begin(), cancelled_.end(), identity) != cancelled_.end();
  }

private:
  void observe(std::uint64_t identity, const std::atomic<bool> *cancelled) {
    std::unique_lock lock{mutex_};
    started_.push_back(identity);
    const auto position = started_.size();
    changed_.notify_all();
    changed_.wait(lock, [&] { return allowed_ >= position; });
    finished_.push_back(identity);
    if (cancelled != nullptr && cancelled->load(std::memory_order_relaxed)) {
      cancelled_.push_back(identity);
    }
  }

  mutable std::mutex mutex_;
  std::condition_variable changed_;
  std::size_t allowed_ = 0;
  std::vector<std::uint64_t> started_;
  std::vector<std::uint64_t> finished_;
  std::vector<std::uint64_t> cancelled_;
};

template <typename Worker, typename Message>
static void expectHistoryRefusal(Worker &worker, const Message &message, std::string_view explanation) {
  bool refused = false;
  try {
    worker.submit(1, message);
  } catch (const RequestError &error) {
    refused = error.code() == FailureCode::resource_limit && error.what() == explanation;
  }
  check(refused);
}

template <typename Worker>
static void drainHistoryResponses(Worker &worker, std::vector<std::uint64_t> &identities, std::size_t expected) {
  while (identities.size() < expected) {
    pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};
    check(::poll(&ready, 1, 2000) == 1);
    worker.collect([&](std::uint64_t, ClientTag, std::span<const Byte> payload) {
      std::array<Byte, 256> bytes;
      DecodeStorage storage{bytes};
      identities.push_back(Codec::decode<RequestCompleted>(payload, storage).request_id);
    });
  }
}

static void checkHistoryCapacity(SystemAllocator &memory) {
  ControlledHistoryService service;
  RequestWorker worker{memory, service};
  worker.submit(1, QueryClients{.request_id = 1});
  check(service.waitStarted(1));
  for (std::uint64_t identity = 2; identity <= 65; ++identity) {
    worker.submit(1, QueryClients{.request_id = identity});
  }
  expectHistoryRefusal(worker, QueryClients{.request_id = 66}, "history queue is full");
  expectHistoryRefusal(worker, ImportHistory{.request_id = 66, .source = "fixture", .entries = history_entries}, "history import was not accepted");

  service.allow(1);
  check(service.waitStarted(2));
  for (std::uint64_t identity = 66; identity <= 129; ++identity) {
    worker.submit(1, QueryClients{.request_id = identity});
  }
  expectHistoryRefusal(worker, QueryClients{.request_id = 130}, "history queue is full");
#if TELAR_DIAGNOSTICS
  const auto metrics = worker.queueMetrics();
  check(metrics.depth == 64 && metrics.high_water == 64 && metrics.dropped == 3);
#endif

  service.allow(6);
  check(service.waitStarted(5));
  check(!service.waitStarted(6, std::chrono::milliseconds{20}));
  std::vector<std::uint64_t> identities;
  drainHistoryResponses(worker, identities, 4);
  check(service.waitStarted(6));
  service.stop();
  drainHistoryResponses(worker, identities, 129);
  for (std::size_t index = 0; index < identities.size(); ++index) {
    check(identities[index] == index + 1);
  }
  check(!worker.pending());
}

static void checkHistoryBatchCancellation(SystemAllocator &memory) {
  ControlledHistoryService service;
  RequestWorker worker{memory, service};
  worker.submit(1, QueryClients{.request_id = 1});
  check(service.waitStarted(1));
  worker.submit(2, QueryClients{.request_id = 2});
  worker.submit(2, QueryClients{.request_id = 3});
  worker.submit(3, QueryClients{.request_id = 4});
  service.allow(1);
  check(service.waitStarted(2));
  worker.submit(2, QueryClients{.request_id = 5});
  worker.submit(3, QueryClients{.request_id = 6});
  worker.submit(2, ImportHistory{.request_id = 7, .source = "fixture", .entries = history_entries});
  worker.submitInternal(std::uint64_t{8});
  worker.cancel(2);
  service.stop();

  std::vector<std::uint64_t> identities;
  drainHistoryResponses(worker, identities, 4);
  check(identities == std::vector<std::uint64_t>({1, 2, 4, 6}));
  check(service.waitStarted(6));
  check(service.cancelled(2));
}

static void checkHistoryShutdown(SystemAllocator &memory) {
  ControlledHistoryService service;
  auto worker = makeOwned<RequestWorker<SystemAllocator, ControlledHistoryService>>(memory, memory, service);
  worker->submit(1, QueryClients{.request_id = 1});
  check(service.waitStarted(1));
  for (std::uint64_t identity = 2; identity <= 6; ++identity) {
    worker->submit(1, QueryClients{.request_id = identity});
  }
  service.allow(6);
  check(service.waitStarted(5));
  check(!service.waitStarted(6, std::chrono::milliseconds{20}));
  for (std::uint64_t identity = 7; identity <= 70; ++identity) {
    worker->submit(1, ImportHistory{.request_id = identity, .source = "fixture", .entries = history_entries});
  }

  auto shutdown = std::async(std::launch::async, [owned = std::move(worker)]() mutable { owned.reset(); });
  check(shutdown.wait_for(std::chrono::seconds{2}) == std::future_status::ready);
  shutdown.get();
  const auto finished = service.finished();
  check(finished.size() == 69);
  check(std::find(finished.begin(), finished.end(), 6) == finished.end());
  for (std::uint64_t identity = 7; identity <= 70; ++identity) {
    check(std::find(finished.begin(), finished.end(), identity) != finished.end());
  }
}

void testHistoryCapacity() {
  SystemAllocator memory;
  checkHistoryCapacity(memory);
  checkHistoryBatchCancellation(memory);
  checkHistoryShutdown(memory);
}
