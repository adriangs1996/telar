#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <csignal>
#include <cstdlib>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.platform.process;
import telar.runtime.platform.process_probe;
import telar.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A pane's process reports the terminal it runs on, which is how an editor request finds the pane;
  // a process with no terminal reports none.
  void testControllingTerminal() {
    SystemAllocator memory;
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    PtyProcess pane{command.specification(TerminalSize{80, 24, 0, 0})};
    const char* name = ::ptsname(pane.descriptor());
    const ProcessInspector inspector;

    check(name != nullptr && inspector.terminal(pane.processId()).view() == name);

    int ready[2];
    int input[2];

    check(::pipe(ready) == 0 && ::pipe(input) == 0);
    const auto detached = ::fork();

    check(detached >= 0);
    if (detached == 0) {
      const char byte = 1;

      if (::setsid() < 0 || ::dup2(input[0], STDIN_FILENO) < 0 || ::write(ready[1], &byte, 1) != 1) {
        ::_exit(1);
      }

      ::pause();
      ::_exit(0);
    }

    ::close(ready[1]);
    char byte = 0;

    check(::read(ready[0], &byte, 1) == 1);
    check(inspector.terminal(detached).view().empty());
    ::kill(detached, SIGKILL);
    ::waitpid(detached, nullptr, 0);
    ::close(ready[0]);
    ::close(input[0]);
    ::close(input[1]);
  }

  const telar::testing::Case case_controlling_terminal{"process_probe.controlling_terminal", testControllingTerminal};

}
