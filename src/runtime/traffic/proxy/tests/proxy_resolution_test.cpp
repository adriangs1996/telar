#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>

import std;
import telar.platform.primitives;
import telar.testing;
import telar.platform.net;
import telar.runtime.host.name_resolutions;
import telar.runtime.host.signals;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct BlockingNameResolver {
    inline static std::counting_semaphore<64> permits{0};
    inline static std::atomic<unsigned> calls{0};

    static ResolutionSummary resolve(const char*, std::span<NetworkAddress> addresses) noexcept {
      calls.fetch_add(1);
      permits.acquire();
      sockaddr_in address{};

#if defined(__APPLE__)
      address.sin_len = sizeof(address);
#endif
      address.sin_family = AF_INET;
      address.sin_port = htons(443);
      address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      for (auto& destination : addresses) {
        destination = *NetworkAddress::copy(reinterpret_cast<const sockaddr*>(&address), sizeof(address));
      }

      return {.found = 40};
    }
  };

  template <typename Condition>
  void waitFor(const Condition& ready) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    while (!ready()) {
      check(std::chrono::steady_clock::now() < deadline);
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }

  void waitSignal(CompletionSignal& signal) {
    pollfd pending{.fd = signal.descriptor(), .events = POLLIN, .revents = 0};

    check(::poll(&pending, 1, 5000) == 1);
    signal.drain();
  }

  void testSharedResolution() {
    using Resolutions = NameResolutions<BlockingNameResolver>;
    CompletionSignal first_signal;
    CompletionSignal second_signal;
    Resolutions::Notifications first_notifications{first_signal};
    Resolutions::Notifications second_notifications{second_signal};
    auto first = Resolutions::request("shared.example");
    auto second = Resolutions::request("SHARED.EXAMPLE");

    check(first && second && Resolutions::pending() == 1);
    check(!Resolutions::request("invalid..example"));
    waitFor([] {
      return BlockingNameResolver::calls.load() == 1;
    });

    Resolutions::Result result;

    check(!first->collect(result));
    first.reset();
    BlockingNameResolver::permits.release();
    waitSignal(first_signal);
    waitSignal(second_signal);
    check(second->collect(result) && result.summary.found == 40 && result.summary.error == 0);
    for (const auto& address : result.addresses) {
      check(address.storage.ss_family == AF_INET && address.length == sizeof(sockaddr_in));
      check(reinterpret_cast<const sockaddr_in*>(&address.storage)->sin_port == 0);
    }

    auto moved = std::move(second.getMut());

    check(!second->collect(result) && moved.collect(result));
    moved.reset();
    check(Resolutions::pending() == 0);
  }

  void testResolutionSaturation() {
    using Resolutions = NameResolutions<BlockingNameResolver>;

    {
      CompletionSignal signal;
      Resolutions::Notifications notifications{signal};
      ds::Array<ds::Option<Resolutions::Ticket>, Resolutions::capacity> tickets;

      for (std::size_t index = 0; index < tickets.size(); ++index) {
        tickets.atMut(index) = Resolutions::request("host" + std::to_string(index) + ".example");
        check(tickets[index].hasValue());
      }

      check(Resolutions::pending() == Resolutions::capacity && !Resolutions::request("overflow.example"));
      auto shared = Resolutions::request("HOST0.EXAMPLE");

      check(shared.hasValue());
      shared.reset();
    }

    check(Resolutions::pending() == Resolutions::capacity);
    BlockingNameResolver::permits.release(Resolutions::capacity);
    waitFor([] {
      return Resolutions::pending() == 0;
    });

    CompletionSignal signal;
    Resolutions::Notifications notifications{signal};
    auto next = Resolutions::request("reused.example");

    check(next.hasValue());
    BlockingNameResolver::permits.release();
    waitSignal(signal);
    Resolutions::Result result;

    check(next->collect(result) && result.summary.found == 40);
  }

  void testSystemResolution() {
    using Resolutions = NameResolutions<SystemNameResolver>;
    CompletionSignal signal;
    Resolutions::Notifications notifications{signal};
    auto local = Resolutions::request("localhost");

    check(local.hasValue());
    waitSignal(signal);
    Resolutions::Result result;

    check(local->collect(result) && result.summary.error == 0 && result.summary.found > 0);
  }

  const telar::testing::Case case_shared_resolution{"proxy_resolution.shared_resolution", testSharedResolution};
  const telar::testing::Case case_resolution_saturation{"proxy_resolution.resolution_saturation", testResolutionSaturation};
  const telar::testing::Case case_system_resolution{"proxy_resolution.system_resolution", testSystemResolution};

}
