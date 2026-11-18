#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <csignal>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.ds;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;
  using telar::testing::TestMemory;

  // It counts what is held and what was given, and has nothing held once all of it is freed.
  void countsWhatIsHeld() {
    TestMemory memory;

    {
      telar::ds::String<telar::Memory> text{memory, "a text long enough to leave the inline storage"};
      telar::ds::Vec<int, telar::Memory> values{memory};

      values.push(1);
      check(memory.liveBytes() >= text.size() + sizeof(int), "what the containers hold is counted");
      check(memory.allocations() >= 2, "each allocation is counted");
    }

    check(memory.liveBytes() == 0, "nothing is held once the containers are gone");
  }

  // A test whose code leaks fails: the memory going while bytes are held aborts the process.
  void failsOnALeak() {
    const auto child = ::fork();
    check(child >= 0, "fork");
    if (child == 0) {
      {
        TestMemory memory;

        static_cast<void>(memory.allocate(16, alignof(std::max_align_t)));
      }

      ::_exit(0);
    }

    int status = 0;

    check(::waitpid(child, &status, 0) == child, "wait for the child");
    check(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT, "a leak fails the test");
  }

  const telar::testing::Case case_counts_what_is_held{"test_memory.counts_what_is_held", countsWhatIsHeld};
  const telar::testing::Case case_fails_on_a_leak{"test_memory.fails_on_a_leak", failsOnALeak};

}
