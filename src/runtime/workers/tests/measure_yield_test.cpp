#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <poll.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.workers.background_executor;
import telar.runtime.workers.request_worker;
import telar.wire.files;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.runtime.transport.connection;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Answers listings and measures one at a time, each when the test lets it, and keeps whether
  // each was told to end: before it began, and by the time it ended.
  class FilesService {
  public:
    struct Seen {
      std::uint64_t request = 0;
      bool hurried = false;
      bool ended = false;
    };

    template <Allocator Memory>
    void process(std::span<const Byte> payload, EncodedReply<Memory>& reply, const RequestContext& context = {}) {
      ds::Array<Byte, 512> bytes;
      DecodeStorage storage{bytes.viewMut()};
      const auto request = payload.front() == static_cast<Byte>(ClientTag::list_directory)
                               ? Codec::decode<ListDirectory>(payload, storage).request_id
                               : Codec::decode<MeasureDirectory>(payload, storage).request_id;

      {
        std::unique_lock lock{mutex_};

        seen_.push_back({.request = request, .hurried = context.cancelled->load(std::memory_order_relaxed)});

        const auto position = seen_.size();

        changed_.notify_all();
        changed_.wait(lock, [&] {
          return allowed_ >= position || context.cancelled->load(std::memory_order_relaxed);
        });

        seen_[position - 1].ended = context.cancelled->load(std::memory_order_relaxed);
      }

      reply.send(RequestCompleted{.request_id = request});
    }

    bool waitStarted(std::size_t count, std::chrono::milliseconds timeout = std::chrono::seconds{2}) {
      std::unique_lock lock{mutex_};

      return changed_.wait_for(lock, timeout, [&] {
        return seen_.size() >= count;
      });
    }

    // A request told to end is woken by nothing: the service looks again when the test says so.
    void look() {
      const std::lock_guard lock{mutex_};

      changed_.notify_all();
    }

    void stop() noexcept {
      const std::lock_guard lock{mutex_};

      allowed_ = std::numeric_limits<std::size_t>::max();
      changed_.notify_all();
    }

    [[nodiscard]] Seen of(std::uint64_t request) const {
      const std::lock_guard lock{mutex_};

      for (const auto& seen : seen_) {
        if (seen.request == request) {
          return seen;
        }
      }

      return {};
    }

  private:
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::size_t allowed_ = 0;
    std::vector<Seen> seen_;
  };

  // A directory newly asked for waits behind no sizes of its client: the measure that runs ends
  // with what it has, the ones queued answer at once, and another client's are left alone.
  void testAListingNewlyAskedHurriesTheSizesOfItsClient() {
    SystemAllocator memory;
    FilesService service;
    RequestWorker worker{memory, service};
    constexpr std::uint16_t page = 512;

    worker.submit(1, MeasureDirectory{.request_id = 1, .path = "/a", .skip = 0, .limit = page});
    check(service.waitStarted(1));
    worker.submit(1, MeasureDirectory{.request_id = 2, .path = "/b", .skip = 0, .limit = page});
    worker.submit(2, MeasureDirectory{.request_id = 3, .path = "/c", .skip = 0, .limit = page});

    // The next page of a directory the window already shows hurries nothing.
    worker.submit(1, ListDirectory{.request_id = 4, .path = "/a", .skip = page, .limit = page});
    service.look();
    check(!service.waitStarted(2, std::chrono::milliseconds{50}), "the measure goes on");

    worker.submit(1, ListDirectory{.request_id = 5, .path = "/d", .skip = 0, .limit = page});
    service.look();
    check(service.waitStarted(2), "the measure that ran ended, and the next request began");
    check(service.of(1).ended && !service.of(1).hurried, "it was told to end while it ran");
    service.stop();

    std::vector<std::uint64_t> answered;

    while (answered.size() < 5) {
      pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};

      check(::poll(&ready, 1, 2000) == 1);
      worker.collect([&](std::uint64_t, ClientTag, std::span<const Byte> payload) {
        ds::Array<Byte, 256> bytes;
        DecodeStorage storage{bytes.viewMut()};

        answered.push_back(Codec::decode<RequestCompleted>(payload, storage).request_id);
      });
    }

    check(answered == std::vector<std::uint64_t>({1, 2, 3, 4, 5}), "every request is answered, in its turn");
    check(service.of(2).hurried, "the sizes its client still had queued answer at once");
    check(!service.of(3).hurried && !service.of(3).ended, "another client's are measured as they were");
    check(!service.of(4).hurried && !service.of(5).hurried, "and a listing is told nothing");
  }

  const telar::testing::Case case_hurry{"measure_yield.a_listing_newly_asked_hurries_the_sizes_of_its_client", testAListingNewlyAskedHurriesTheSizesOfItsClient};

}
