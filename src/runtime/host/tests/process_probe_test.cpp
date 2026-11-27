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
import telar.runtime.host.process_probe;
import telar.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A pane's process reports the terminal it runs on, which is how an editor request finds the pane;
  // a process with no terminal reports none.
  void testControllingTerminal() {
    SystemAllocator memory;
    const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
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

  // Quoted arguments paste back as the same arguments: only those that need it are in single quotes,
  // a quote in one as '\'', and what does not fit leaves out whole arguments.
  void testQuotedArguments() {
    using namespace std::string_view_literals;

    const auto arguments = "claude\0--name=Fix Monitor UI\0it's\0-I/usr/include\0a$b\0"sv;
    const ProcessArguments parsed{arguments};
    ds::Array<char, 128> output{};

    check(parsed.joined(output.viewMut()) == "claude --name=Fix Monitor UI it's -I/usr/include a$b");
    check(parsed.quoted(output.viewMut()) == R"(claude '--name=Fix Monitor UI' 'it'\''s' -I/usr/include 'a$b')", std::string{parsed.quoted(output.viewMut())});
    check(ProcessArguments{"ls\0-la\0"sv}.quoted(output.viewMut()) == "ls -la");
    check(parsed.quoted(output.viewMut().first(30)) == "claude '--name=Fix Monitor UI'", std::string{parsed.quoted(output.viewMut().first(30))});
    check(parsed.quoted(output.viewMut().first(29)) == "claude");
    check(parsed.quoted(output.viewMut().first(3)).empty());
  }

  const telar::testing::Case case_controlling_terminal{"process_probe.controlling_terminal", testControllingTerminal};
  const telar::testing::Case case_quoted_arguments{"process_probe.quoted_arguments", testQuotedArguments};

}
