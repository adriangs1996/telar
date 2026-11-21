#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.cli.commands.machine_ssh;
import telar.machines;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using telar::testing::expect;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli;

  // The words /bin/sh splits `command` into, one per line.
  std::vector<std::string> shellWords(const std::string& command) {
    const auto script = "set -- " + command + "; for word; do printf '%s\\n' \"$word\"; done";
    FILE* pipe = ::popen(script.c_str(), "r");

    check(pipe != nullptr, script);
    std::string output;
    ds::Array<char, 256> buffer;

    while (const auto count = std::fread(buffer.dataMut(), 1, buffer.size(), pipe)) {
      output.append(buffer.data(), count);
    }

    check(::pclose(pipe) == 0, script);
    std::vector<std::string> words;

    for (std::size_t start = 0; start < output.size();) {
      const auto end = output.find('\n', start);

      words.emplace_back(output.substr(start, end - start));
      start = end + 1;
    }

    return words;
  }

  template <typename Run>
  std::string failure(Run run) {
    try {
      run();
    } catch (const std::exception& error) {
      return error.what();
    }

    return {};
  }

  // A remote command that hangs ends at its deadline instead of holding setup or check.
  void captureTimeoutThrows() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;

    check(failure([&] {
      launch::capture(memory, launch::words(memory, {"/bin/sleep", "5"}).view(), {}, std::chrono::seconds{1});
    }) == "Timeout");
  }

  // Output past the limit keeps its tail and says how much was dropped, so a truncated
  // listing is never read as complete. Input and output are pumped together: a large input
  // to a program that echoes it does not deadlock.
  void captureKeepsTailAndCountsDropped() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    std::string input(launch::output_limit + 44 * 1024, '\0');

    for (std::size_t index = 0; index < input.size(); ++index) {
      input[index] = static_cast<char>('a' + index * 7 % 26);
    }

    const auto result = launch::capture(memory, launch::words(memory, {"/bin/cat"}).view(), input, std::chrono::seconds{10});

    check(result.status == 0);
    check(result.dropped == input.size() - launch::output_limit);
    check(result.out == std::string_view{input}.substr(result.dropped));
  }

  // A program killed by a signal is a failure: `telar --machine X cmd` does not exit 0 when
  // the gateway program was killed.
  void inheritSignalIsFailure() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;

    check(launch::inherit(launch::words(memory, {"/bin/sh", "-c", "kill -9 $$"}).view()) == launch::unreachable_status);
    check(launch::inherit(launch::words(memory, {"/bin/sh", "-c", "exit 3"}).view()) == 3);
  }

  // Git reaches a machine through the gateway program the dispatch uses, with the machine's
  // address as one word to the shell Git runs it with; a program the quoting cannot hold is
  // refused.
  void gitGatewayCommandNamesTheMachine() {
    check(::setenv("TELAR_GATEWAY_PROGRAM", "/opt/telar bin/telar-gateway", 1) == 0);
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    const std::string_view address = "telar://box.example:8352#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const auto words = shellWords(std::string{machine::gitGatewayCommand(memory, address).view()});
    const auto dispatch = machine::gateway(memory, address, "x");

    expect(words == std::vector<std::string>{"/opt/telar bin/telar-gateway", "run", "--to", std::string{address}});
    expect(dispatch.size() == 4 && dispatch.view()[0] == "/opt/telar bin/telar-gateway" && dispatch.view()[1] == "run" && dispatch.view()[2] == address && dispatch.view()[3] == "x");
    expect(machine::gateway(memory, address, "x", {.terminal = true, .share = true}).view()[2] == "-t");
    expect(machine::gateway(memory, address, "x", {.terminal = true, .share = true}).view()[3] == "--share");

    check(::setenv("TELAR_GATEWAY_PROGRAM", "/opt/it's/telar-gateway", 1) == 0);
    expect(failure([&] {
      machine::gitGatewayCommand(memory, address);
    }) == "UnquotableGatewayCommand");

    check(::unsetenv("TELAR_GATEWAY_PROGRAM") == 0);
  }

  // A machine is named by its gateway's address, and one that still carries its pairing code is
  // told apart from the address a profile saves.
  void gatewayAddressesAreToldApart() {
    expect(machine::gatewayAddress("telar://box:8352#00ff") && !machine::pairingAddress("telar://box:8352#00ff"));
    expect(machine::pairingAddress("telar://box.example:8352#00ff.1234"));
    expect(!machine::gatewayAddress("dev@box") && !machine::gatewayAddress("telar://box:8352") && !machine::pairingAddress("ssh://dev@box.example"));
  }

  // A remote command that fails, or whose output overflows what is kept, is the caller's
  // failure, never its output.
  void remoteCaptureFailsOnStatusOrOverflow() {
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-remote-capture-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root = directory.data();
    const auto program = root + "/gateway";

    // A stand-in plays the gateway program: whatever it prints is what the machine answered.
    check(::setenv("TELAR_GATEWAY_PROGRAM", program.c_str(), 1) == 0);
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    const auto profiles = machines::MachineProfileCodec::parse(memory, R"({"version":2,"local_label":"local","machines":[{"id":"m-0123456789ab","label":"box","destination":"telar://host:8352#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff","enabled":true}]})");
    const auto& profile = profiles.rows().front();
    const ds::Array<std::string_view, 2> words{"worktree", "list"};

    const auto capture = [&](std::string_view body) {
      FILE* script = std::fopen(program.c_str(), "w");

      check(script != nullptr);
      std::fprintf(script, "#!/bin/sh\n%.*s\n", static_cast<int>(body.size()), body.data());
      std::fclose(script);
      check(::chmod(program.c_str(), 0700) == 0);
      return failure([&] {
        check(machine::capture(memory, profile, std::span<const std::string_view>{words.view()}, "RemoteFailed") == "listed\n");
      });
    };

    check(capture("echo listed") == "");
    check(capture("echo listed; exit 1") == "RemoteFailed");
    check(capture("head -c 300000 /dev/zero") == "RemoteFailed");
    check(::unsetenv("TELAR_GATEWAY_PROGRAM") == 0);
    std::filesystem::remove_all(root);
  }

  // Parses `words` as the command line; the options view them, so the caller keeps them.
  WindowOptions windowOptions(std::vector<std::string>& words, bool gui = false) {
    std::vector<char*> pointers;

    for (auto& word : words) {
      pointers.push_back(word.data());
    }

    return WindowOptions::parse(pointers, gui);
  }

  // The words after `--` are the command the window runs, options and all; --login-shell
  // belongs to `telar gui` alone, and a window command has at most 64 words.
  void windowOptionsCommandAfterSeparator() {
    std::vector<std::string> fresh_words{"--fresh", "--", "htop", "-d"};
    const auto fresh = windowOptions(fresh_words);

    check(fresh.fresh && std::ranges::equal(fresh.command(), ds::Array<std::string_view, 2>{"htop", "-d"}));

    std::vector<std::string> gui_words{"--login-shell", "--theme", "Mocha"};
    const auto gui = windowOptions(gui_words, true);

    check(gui.login_shell && gui.theme == ds::Option<std::string_view>{"catppuccin"} && gui.command().empty(), "a theme alias is its canonical name, whatever its case");

    std::vector<std::string> long_command{"--"};

    for (int index = 0; index < 65; ++index) {
      long_command.emplace_back("word");
    }

    check(!failure([&] {
      windowOptions(long_command);
    }).empty());

    long_command.pop_back();
    check(windowOptions(long_command).command().size() == 64);
  }

  const telar::testing::Case case_capture_timeout{"launch.capture_timeout_throws", captureTimeoutThrows};
  const telar::testing::Case case_capture_tail{"launch.capture_keeps_tail_and_counts_dropped", captureKeepsTailAndCountsDropped};
  const telar::testing::Case case_inherit_signal{"launch.inherit_signal_is_failure", inheritSignalIsFailure};
  const telar::testing::Case case_git_gateway{"launch.git_gateway_command_names_the_machine", gitGatewayCommandNamesTheMachine};
  const telar::testing::Case case_gateway_addresses{"launch.gateway_addresses_are_told_apart", gatewayAddressesAreToldApart};
  const telar::testing::Case case_remote_capture{"launch.remote_capture_fails_on_status_or_overflow", remoteCaptureFailsOnStatusOrOverflow};
  const telar::testing::Case case_window_options{"launch.window_options_command_after_separator", windowOptionsCommandAfterSeparator};

}
