#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <poll.h>

import std;
import telar.testing;
import telar.runtime.workers.request_worker;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  // Answers a request with the request itself, at once.
  class Echo {
  public:
    using Request = int;
    using Result = int;

    static Result observe(const Request& request) noexcept {
      return request;
    }

    void stop() noexcept {}
  };

  // The worker's signal says a result is there to take: one collect after the wake takes it, and
  // leaves no signal behind. A test or a loop that collects once per wake depends on both.
  void testCollectAfterTheWake() {
    constexpr int rounds = 20'000;
    ObservationWorker<Echo> worker{std::in_place};

    for (int round = 0; round < rounds; ++round) {
      check(worker.submit(round));
      pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};

      check(::poll(&ready, 1, 2000) == 1);
      int collected = -1;

      worker.collect([&](const int& result) {
        collected = result;
      });

      check(collected == round);
      ready.revents = 0;
      check(::poll(&ready, 1, 0) == 0);
    }
  }

  const telar::testing::Case case_collect_after_the_wake{"observation_worker.collect_after_the_wake", testCollectAfterTheWake};

}
