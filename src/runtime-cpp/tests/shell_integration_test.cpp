#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>
#include <cstdlib>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

#include "command_specs.hpp"

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.platform;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.ebnf.matcher;
import telar.runtime.command_capture.tracker;
import telar.runtime.shell_integration;
import telar.runtime.runtime.client_control;
import telar.runtime.shell_integration.git_context;
import telar.runtime.shell_integration.words;

using namespace telar;
using namespace telar::runtime;

namespace {

using Arguments = std::vector<std::string_view>;

std::span<const Byte> bytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

void detection() {
  check(integrableShell(Arguments{"/bin/zsh", "-l", "-i"}) == IntegratedShell::zsh);
  check(integrableShell(Arguments{"bash"}) == IntegratedShell::bash);
  check(integrableShell(Arguments{"/opt/homebrew/bin/fish", "--login"}) == IntegratedShell::fish);
  check(!integrableShell(Arguments{"/bin/zsh", "-l", "-i", "-c", "exec -- \"$0\" \"$@\"", "vim"}));
  check(!integrableShell(Arguments{"bash", "script.sh"}));
  check(!integrableShell(Arguments{"bash", "--norc"}));
  check(!integrableShell(Arguments{"/usr/bin/vim"}));
  check(!integrableShell(Arguments{}));
}

std::string text(std::string_view value) {
  return std::string{value};
}

// A program named like the shell, so a command resolves without that shell installed.
std::string stand_in(std::string_view directory, std::string_view name) {
  auto path = text(directory) + "/" + text(name);
  check(::symlink("/bin/sh", path.c_str()) == 0);
  return path;
}

std::vector<std::string> spawnedArguments(Command<SystemAllocator> &command) {
  const auto specification = command.specification(TerminalSize{80, 24, 0, 0});
  std::vector<std::string> arguments;
  for (auto *const *argument = specification.arguments; *argument != nullptr; ++argument) {
    arguments.emplace_back(*argument);
  }
  return arguments;
}

void preparation(SystemAllocator &memory) {
  TemporaryDirectory home{"/tmp/telar-shell-XXXXXX"};
  const auto directory = ShellIntegration<SystemAllocator>::install(memory, home.path());
  check(directory.starts_with(text(home.path()) + "/telar/shell-integration/"));
  struct stat state{};
  check(::stat(directory.c_str(), &state) == 0 && (state.st_mode & 0077) == 0);
  check(::stat((text(directory) + "/zsh/.zshenv").c_str(), &state) == 0 && (state.st_mode & 0777) == 0600);
  check(ShellIntegration<SystemAllocator>::install(memory, home.path()) == directory);

  const ShellIntegration<SystemAllocator> integration{memory, directory};
  {
    const std::array<std::string_view, 3> arguments{"/bin/zsh", "-l", "-i"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    command.setEnvironment("ZDOTDIR", "/custom");
    command.setEnvironment("TELAR_BASH_LOGIN", "1");
    const auto launch = integration.apply(command);
    check(launch && launch->shell == IntegratedShell::zsh && command.environment("TELAR_SHELL_TOKEN") == launch->token.text());
    check(command.environment("TELAR_ZSH_ZDOTDIR") == "/custom");
    check(command.environment("ZDOTDIR") == text(directory) + "/zsh");
    check(!command.environment("TELAR_BASH_LOGIN"));
  }
  {
    const auto bash = stand_in(home.path(), "bash");
    const std::array<std::string_view, 3> arguments{bash, "-l", "-i"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    check(integration.apply(command).has_value());
    check(spawnedArguments(command) == std::vector<std::string>{bash, "--rcfile", text(directory) + "/bash/telar.bash", "-i"});
    check(command.arguments().size() == 3 && command.arguments()[1] == "-l");
    check(command.environment("TELAR_BASH_LOGIN") == "1");
  }
  {
    const auto fish = stand_in(home.path(), "fish");
    const std::array<std::string_view, 1> arguments{fish};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    command.removeEnvironment("XDG_DATA_DIRS");
    check(integration.apply(command).has_value());
    check(command.environment("XDG_DATA_DIRS") == text(directory) + "/fish:/usr/local/share:/usr/share");
    check(!command.environment("TELAR_FISH_XDG_DATA_DIRS"));
    command.setEnvironment("XDG_DATA_DIRS", "/a:/b");
    check(integration.apply(command).has_value());
    check(command.environment("TELAR_FISH_XDG_DATA_DIRS") == "/a:/b");
  }
  {
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    command.setEnvironment("TELAR_SHELL_TOKEN", "inherited");
    check(!integration.apply(command));
    check(!command.environment("TELAR_SHELL_TOKEN"));
    check(spawnedArguments(command) == std::vector<std::string>{"/bin/cat"});
  }
  {
    const std::array<std::string_view, 1> arguments{"/bin/zsh"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    check(!ShellIntegration<SystemAllocator>{memory, ""}.apply(command));
    check(!command.environment("ZDOTDIR") || command.environment("ZDOTDIR") != text(directory) + "/zsh");
  }

  // Scripts removed while the runtime runs are written again before the next shell starts.
  const auto sentinel = text(directory) + "/ssh/remote";
  check(::unlink(sentinel.c_str()) == 0);
  const std::array<std::string_view, 1> arguments{"/bin/zsh"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  check(integration.apply(command).has_value());
  check(::access(sentinel.c_str(), R_OK) == 0);
}

std::optional<std::string> findProgram(std::string_view name) {
  const char *variable = std::getenv("PATH");
  std::string_view path = variable == nullptr ? "/usr/bin:/bin" : variable;
  while (!path.empty()) {
    const auto separator = path.find(':');
    auto candidate = text(path.substr(0, separator)) + "/" + text(name);
    if (::access(candidate.c_str(), X_OK) == 0) {
      return candidate;
    }
    path.remove_prefix(separator == std::string_view::npos ? path.size() : separator + 1);
  }
  return std::nullopt;
}

// Answers the primary device attributes query, as a terminal does: fish 4 waits for it.
void answerTerminal(int descriptor, std::string_view output) {
  if (output.find("\x1b[c") != std::string_view::npos || output.find("\x1b[0c") != std::string_view::npos) {
    constexpr std::string_view answer = "\x1b[?62;22c";
    check(::write(descriptor, answer.data(), answer.size()) == static_cast<ssize_t>(answer.size()));
  }
}

struct Completions {
  std::vector<std::optional<int>> exit_codes;
  std::string marks;

  void complete(CommandCompletion completion) {
    exit_codes.push_back(completion.exit_code);
  }

  void mark(CommandMark mark) {
    marks.push_back(mark.action);
  }
};

// The prompt the user's configuration in the test's home draws.
constexpr std::string_view user_prompt = "telar-user-prompt> ";

// A home whose zsh, bash and fish configurations only set that prompt.
void writeUserPrompt(const std::string &root) {
  const auto prompt = std::string{user_prompt};
  for (const auto name : {"/.zshrc", "/.bashrc", "/.bash_profile"}) {
    std::ofstream{root + name} << "PS1='" << prompt << "'\n";
  }
  check(::mkdir((root + "/.config").c_str(), 0700) == 0 && ::mkdir((root + "/.config/fish").c_str(), 0700) == 0);
  std::ofstream{root + "/.config/fish/config.fish"} << "function fish_prompt; printf '%s' '" << prompt << "'; end\n";
}

// Runs a real shell through the integration, in a home that only sets a prompt, and reads its
// marks the way the runtime does: only signed ones count. With `bare`, telar's editor stands in
// for the prompt, so the shell draws none of the user's.
void signsCommands(SystemAllocator &memory, const ShellIntegration<SystemAllocator> &integration, const std::string &shell, std::string_view home, bool bare = false) {
  const std::array<std::string_view, 3> arguments{shell, "-l", "-i"};
  Command command{memory, Launch{.cwd = home, .arguments = arguments}};
  command.setEnvironment("HOME", home);
  for (const auto name : {"ZDOTDIR", "ENV", "BASH_ENV", "PROMPT_COMMAND", "PS1", "XDG_CONFIG_HOME", "TELAR_PROMPT_MODE"}) {
    command.removeEnvironment(name);
  }
  const auto launch = integration.apply(command, bare);
  check(launch.has_value());
  check(command.environment("TELAR_PROMPT_MODE") == (bare ? std::optional<std::string_view>{"telar"} : std::nullopt));
  std::string drawn;
  PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};
  CommandZones zones{"/", launch->token};
  Completions completions;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  const auto pump = [&](auto ready) {
    while (!ready()) {
      check(std::chrono::steady_clock::now() < deadline);
      pollfd pending{.fd = process.descriptor(), .events = POLLIN, .revents = 0};
      if (::poll(&pending, 1, 50) <= 0) {
        continue;
      }
      std::array<char, 4096> output;
      const auto count = ::read(process.descriptor(), output.data(), output.size());
      check(count > 0);
      answerTerminal(process.descriptor(), {output.data(), static_cast<std::size_t>(count)});
      drawn.append(output.data(), static_cast<std::size_t>(count));
      zones.feed(bytes({output.data(), static_cast<std::size_t>(count)}), {}, completions);
    }
  };
  const auto type = [&](std::string_view line) {
    check(::write(process.descriptor(), line.data(), line.size()) == static_cast<ssize_t>(line.size()));
    zones.input(bytes(line));
  };

  pump([&] { return zones.editing(); });
  type("false\r");
  pump([&] { return completions.exit_codes.size() == 1 && zones.editing(); });
  type("sh -c 'exit 3'\r");
  pump([&] { return completions.exit_codes.size() == 2 && zones.editing(); });
  check(completions.exit_codes == std::vector<std::optional<int>>{1, 3});
  check((drawn.find(user_prompt) == std::string::npos) == bare);
  type("exit\r");
}

std::string readText(const std::string &path) {
  std::ifstream file{path, std::ios::binary};
  return {std::istreambuf_iterator<char>{file}, {}};
}

void writeProgram(const std::string &path, std::string_view content) {
  std::ofstream{path} << content;
  check(::chmod(path.c_str(), 0700) == 0);
}

// Runs `arguments` on a terminal until it exits, feeding its output to `zones`.
void runOnTerminal(SystemAllocator &memory, std::span<const std::string_view> arguments, std::string_view home, std::span<const std::pair<std::string_view, std::string_view>> environment, CommandZones &zones) {
  Command command{memory, Launch{.cwd = home, .arguments = arguments}};
  command.setEnvironment("HOME", home);
  for (const auto &[name, value] : environment) {
    command.setEnvironment(name, value);
  }
  PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};
  Completions completions;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  while (true) {
    check(std::chrono::steady_clock::now() < deadline);
    pollfd pending{.fd = process.descriptor(), .events = POLLIN, .revents = 0};
    if (::poll(&pending, 1, 50) <= 0) {
      continue;
    }
    std::array<char, 4096> output;
    const auto count = ::read(process.descriptor(), output.data(), output.size());
    if (count <= 0) {
      return;
    }
    answerTerminal(process.descriptor(), {output.data(), static_cast<std::size_t>(count)});
    zones.feed(bytes({output.data(), static_cast<std::size_t>(count)}), {}, completions);
  }
}

// The integrated shell's `ssh` brings the integration only to an interactive session. A
// stand-in ssh records what it was asked to run, and prints a configuration for -G.
void sshArguments(SystemAllocator &memory) {
  TemporaryDirectory home{"/tmp/telar-shell-XXXXXX"};
  const auto directory = ShellIntegration<SystemAllocator>::install(memory, home.path());
  const auto programs = text(home.path()) + "/bin";
  check(::mkdir(programs.c_str(), 0700) == 0);
  const auto record = text(home.path()) + "/arguments";
  writeProgram(programs + "/ssh", "#!/bin/sh\nif [ \"$1\" = -G ]; then printf 'host h\\nsessiontype default\\nrequesttty auto\\nstdinnull no\\n%s' \"$TELAR_TEST_CONFIG\"; exit; fi\nprintf '%s\\n' \"$@\" >\"$TELAR_TEST_RECORD\"\n");
  const auto path = programs + ":/usr/bin:/bin";
  const auto token = ShellToken::generate();
  const auto remote = readText(text(directory) + "/ssh/remote");
  check(remote.starts_with("exec /bin/sh -c 'p=") && remote.find_first_of("\\!\n") == std::string::npos && std::ranges::count(remote, '\'') == 2);

  // Whether ssh ran the remote command, and the nonce the pane's shell then signed.
  std::string recorded;
  const auto run = [&](std::vector<std::string_view> options, std::string_view configuration = "", std::string_view mode = "") {
    const auto helper = text(directory) + "/ssh/ssh.sh";
    std::vector<std::string_view> arguments{"/bin/sh", helper};
    arguments.insert(arguments.end(), options.begin(), options.end());
    const std::array<std::pair<std::string_view, std::string_view>, 5> environment{{{"PATH", path}, {"TELAR_SHELL_TOKEN", token.text()}, {"TELAR_TEST_RECORD", record}, {"TELAR_TEST_CONFIG", configuration}, {"TELAR_PROMPT_MODE", mode}}};
    CommandZones zones{"/", token};
    ::unlink(record.c_str());
    runOnTerminal(memory, arguments, home.path(), environment, zones);
    recorded = readText(record);
    const bool nested = recorded.starts_with("-t\n") && recorded.find(remote) != std::string::npos;
    // The token never reaches ssh's arguments, which every user on the host can read.
    check(recorded.find(token.text()) == std::string::npos);
    return nested;
  };
  check(run({"host"}) && !recorded.ends_with(" telar\n"));
  // telar's prompt mode follows the session to the remote shell, after the nonce; nothing else does.
  check(run({"host"}, "", "telar") && recorded.ends_with(" telar\n"));
  check(run({"host"}, "", "telar; rm -rf ~") && !recorded.ends_with(" telar\n") && recorded.find("rm -rf") == std::string::npos);
  check(run({"-p", "2222", "-A", "user@host", "-o", "ForwardX11=no"}));
  check(run({"-luser", "--", "host"}));
  check(!run({"host", "uptime"}));
  check(!run({"-p", "2222", "host", "--", "ls"}));
  check(!run({"-N", "-L", "8080:localhost:80", "host"}, "sessiontype none\n"));
  check(!run({"-W", "host:22", "jump"}));
  check(!run({"-O", "check", "host"}));
  check(!run({"-V"}));
  check(!run({"host"}, "remotecommand tmux attach\n"));
  check(!run({"-T", "host"}, "requesttty false\n"));
  check(!run({}));
}

// What a remote host runs, parsed by its login shell as sshd does: the bootstrap writes the
// scripts under that host's own home and starts the login shell with them, which answers the
// nonce and signs its marks with a token of its own.
// With `bare`, the pane's shell runs in telar's prompt mode, which `ssh` passes on after the nonce.
void remoteShell(SystemAllocator &memory, std::string_view directory, const std::string &shell, bool bare = false) {
  TemporaryDirectory home{"/tmp/telar-remote-XXXXXX"};
  writeUserPrompt(text(home.path()));
  const auto token = ShellToken::generate();
  const auto nonce = ShellToken::generate();
  const auto remote = readText(text(directory) + "/ssh/remote") + " " + text(nonce.text()) + (bare ? " telar" : "");
  const std::array<std::string_view, 3> arguments{shell, "-c", remote};
  Command command{memory, Launch{.cwd = home.path(), .arguments = arguments}};
  command.setEnvironment("HOME", home.path());
  command.setEnvironment("SHELL", shell);
  for (const auto name : {"ZDOTDIR", "ENV", "BASH_ENV", "PROMPT_COMMAND", "PS1", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "TELAR_SHELL_TOKEN", "TELAR_PROMPT_MODE"}) {
    command.removeEnvironment(name);
  }
  PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};
  CommandZones zones{"/", token};
  Completions completions;
  std::string drawn;
  // The pane's shell signed the nonce before ssh connected.
  zones.feed(bytes("\x1b]6973;telar=" + text(token.text()) + ";nest=" + text(nonce.text()) + "\x07"), {}, completions);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  const auto pump = [&](auto ready) {
    while (!ready()) {
      check(std::chrono::steady_clock::now() < deadline);
      pollfd pending{.fd = process.descriptor(), .events = POLLIN, .revents = 0};
      if (::poll(&pending, 1, 50) <= 0) {
        continue;
      }
      std::array<char, 4096> output;
      const auto count = ::read(process.descriptor(), output.data(), output.size());
      check(count > 0);
      answerTerminal(process.descriptor(), {output.data(), static_cast<std::size_t>(count)});
      drawn.append(output.data(), static_cast<std::size_t>(count));
      zones.feed(bytes({output.data(), static_cast<std::size_t>(count)}), {}, completions);
    }
  };
  const auto type = [&](std::string_view line) {
    check(::write(process.descriptor(), line.data(), line.size()) == static_cast<ssize_t>(line.size()));
    zones.input(bytes(line));
  };

  pump([&] { return zones.remote() && zones.editing(); });
  check(zones.remoteShell() == integrableShell(Arguments{shell}));
  // The remote shell took over before it marked anything.
  check(completions.marks.starts_with('N'));
  // Where it works is its host's place; this host's directory stays as it was.
  check(!zones.remoteHost().empty() && std::filesystem::equivalent(zones.remoteDirectory(), home.path()));
  check(zones.directory() == "/");
  type("false\r");
  pump([&] { return completions.exit_codes.size() == 1 && zones.editing(); });
  check(completions.exit_codes.back() == 1);
  struct stat state{};
  const auto installed = text(home.path()) + "/.local/share/telar/shell-integration/" + text(directory.substr(directory.rfind('/') + 1));
  check(::stat(installed.c_str(), &state) == 0 && (state.st_mode & 0077) == 0);
  check((drawn.find(user_prompt) == std::string::npos) == bare);
  type("exit\r");
  // The pane's own shell is back: it says so before its D ends ssh.
  completions.marks.clear();
  zones.feed(bytes("\x1b]133;D;255;telar=" + text(token.text()) + "\x07"), {}, completions);
  check(completions.marks == "UD" && !zones.remote() && zones.remoteDirectory().empty());
}

void shells(SystemAllocator &memory) {
  TemporaryDirectory home{"/tmp/telar-shell-XXXXXX"};
  writeUserPrompt(text(home.path()));
  const ShellIntegration<SystemAllocator> integration{memory, ShellIntegration<SystemAllocator>::install(memory, home.path())};
  if (const auto zsh = findProgram("zsh")) {
    signsCommands(memory, integration, *zsh, home.path());
    signsCommands(memory, integration, *zsh, home.path(), true);
  } else {
    std::puts("shell integration: zsh not installed, skipped");
  }
  if (const auto bash = findProgram("bash")) {
    signsCommands(memory, integration, *bash, home.path());
    signsCommands(memory, integration, *bash, home.path(), true);
  } else {
    std::puts("shell integration: bash not installed, skipped");
  }
  // macOS ships bash 3.2, which has no PS0: its commands are marked by the DEBUG trap.
  if (::access("/bin/bash", X_OK) == 0 && findProgram("bash") != "/bin/bash") {
    signsCommands(memory, integration, "/bin/bash", home.path());
    signsCommands(memory, integration, "/bin/bash", home.path(), true);
  }
  if (const auto fish = findProgram("fish")) {
    signsCommands(memory, integration, *fish, home.path());
    signsCommands(memory, integration, *fish, home.path(), true);
  } else {
    std::puts("shell integration: fish not installed, skipped");
  }

  const auto directory = ShellIntegration<SystemAllocator>::install(memory, home.path());
  for (const auto name : {"zsh", "bash", "fish"}) {
    if (const auto shell = findProgram(name)) {
      remoteShell(memory, directory, *shell);
      remoteShell(memory, directory, *shell, true);
    }
  }
  if (::access("/bin/bash", X_OK) == 0 && findProgram("bash") != "/bin/bash") {
    remoteShell(memory, directory, "/bin/bash");
    remoteShell(memory, directory, "/bin/bash", true);
  }
}

}

// A pane follows its integrated shell from the output it reads: at the prompt, running a
// program, and the line discipline that program sets, as a password prompt does.
void paneState(SystemAllocator &memory) {
  const auto zsh = findProgram("zsh");
  if (!zsh) {
    return;
  }

  TemporaryDirectory home{"/tmp/telar-shell-XXXXXX"};
  const ShellIntegration<SystemAllocator> integration{memory, ShellIntegration<SystemAllocator>::install(memory, home.path())};
  const std::array<std::string_view, 3> arguments{*zsh, "-l", "-i"};
  Command command{memory, Launch{.cwd = home.path(), .arguments = arguments}};
  command.setEnvironment("HOME", home.path());
  command.removeEnvironment("ZDOTDIR");
  RuntimeModel model{memory};
  auto owned = makeOwned<Pane<SystemAllocator>>(memory, memory, 7, TabLocation{}, command, PaneLaunch{TerminalSize{80, 24, 8, 16}, model.media_budget, model.graphics_limits, integration.apply(command)});
  auto &pane = *owned;
  check(pane.shell_state.pane_id == 7 && pane.shell_state.shell == IntegratedShell::zsh);

  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  const auto until = [&](auto ready) {
    while (!ready()) {
      check(std::chrono::steady_clock::now() < deadline);
      pollfd pending{.fd = pane.process->descriptor(), .events = POLLIN, .revents = 0};
      if (::poll(&pending, 1, 20) > 0) {
        check(pane.read());
      } else {
        pane.observeShell();
      }
    }
  };
  const auto type = [&](std::string_view line) {
    pane.enqueueInput(bytes(line));
    pane.write();
  };

  until([&] { return pane.shell_state.phase == ShellPhase::prompt && pane.shell_state.shell_foreground; });
  // The shell's marks reach the terminal too, which flags its prompt row for clients.
  pane.terminal.refresh();
  const auto &screen = pane.terminal.screen;
  check(screen.cursor.y < screen.row_flags.size() && (screen.row_flags[screen.cursor.y] & static_cast<Byte>(RowFlag::prompt)) != 0);
  const auto revision = pane.shell_state == PaneShell{} ? 0 : pane.shell_revision;
  type("read -s secret; sleep 0.3\r");
  until([&] { return pane.shell_state.phase == ShellPhase::running && pane.shell_state.canonical && !pane.shell_state.echo; });
  check(pane.shell_revision > revision && pane.shell_state.signal_keys && pane.shell_state.interrupt == 0x03);
  type("hidden\n");
  until([&] { return pane.shell_state.phase == ShellPhase::running && pane.shell_state.echo && !pane.shell_state.shell_foreground; });
  until([&] { return pane.shell_state.phase == ShellPhase::prompt && pane.shell_state.shell_foreground; });
  check(pane.shell_state.commands == 1 && pane.shell_state.status == 0);
  // The integration reports the working directory, which follows `cd`.
  check(std::filesystem::equivalent(pane.shell_zones->directory(), home.path()));
  // It reports the shell's PATH too, signed, for command completion.
  check(!pane.shell_zones->path().empty() && pane.shell_zones->path().find("/bin") != std::string_view::npos);
  type("cd /\r");
  until([&] { return pane.shell_state.commands == 2 && pane.shell_state.phase == ShellPhase::prompt && pane.shell_zones->directory() == "/"; });
  type("cd -\r");
  until([&] { return pane.shell_state.commands == 3 && pane.shell_state.phase == ShellPhase::prompt; });
  type("false\r");
  until([&] { return pane.shell_state.commands == 4 && pane.shell_state.phase == ShellPhase::prompt; });
  check(pane.shell_state.status == 1);
  // It reports its aliases and functions, the commands no PATH directory holds.
  check(pane.shell_zones->names() != nullptr && pane.shell_zones->names()->find("which-command") != std::string::npos);

  // Each command is a block anchored to its prompt's row, in order, with how it ended.
  std::array<CommandBlock, PaneBlocks::capacity> storage;
  const auto blocks = pane.blocks->message(7, storage).blocks;
  check(blocks.size() == 4);
  check(blocks[0].command.ends_with("read -s secret; sleep 0.3") && blocks[0].state == CommandBlockState::succeeded);
  check(blocks[1].command.ends_with("cd /") && blocks[2].command.ends_with("cd -"));
  check(blocks[3].command.ends_with("false") && blocks[3].state == CommandBlockState::failed && blocks[3].status == 1);
  for (std::size_t index = 0; index < blocks.size(); ++index) {
    check(blocks[index].rows >= 1 && blocks[index].lines == 0);
    check(index == 0 || blocks[index].row >= blocks[index - 1].row + blocks[index - 1].rows);
  }
  // A block's row is where the terminal flagged its prompt.
  pane.terminal.refresh();
  const auto top = pane.terminal.screen.scroll.offset;
  check(blocks[3].row >= top && (screen.row_flags[blocks[3].row - top] & static_cast<Byte>(RowFlag::prompt)) != 0);
  // Output scrolls the rows and the anchors follow them.
  const auto before = blocks[3].row;
  type("seq 1 60\r");
  until([&] { return pane.shell_state.commands == 5 && pane.shell_state.phase == ShellPhase::prompt; });
  const auto moved = pane.blocks->message(7, storage).blocks;
  check(moved.size() == 5 && moved[3].row == before && moved[4].command.ends_with("seq 1 60") && moved[4].duration_ms < 10000);
  // A full-screen program takes the alternate screen and gives it back: the blocks stay.
  type("printf '\\033[?1049h'; sleep 0.3; printf '\\033[?1049l'\r");
  until([&] { return pane.shell_state.commands == 6 && pane.shell_state.phase == ShellPhase::prompt; });
  const auto kept = pane.blocks->message(7, storage).blocks;
  check(kept.size() == 6 && kept[4].row == moved[4].row);
  type("exit\r");
}

// A real `ssh` to the host TELAR_SSH_TEST_HOST names, reached without a password: the pane
// follows the remote shell's prompts and commands, and its own shell's again once ssh exits.
void sshSession(SystemAllocator &memory) {
  const char *host = std::getenv("TELAR_SSH_TEST_HOST");
  const auto zsh = findProgram("zsh");
  if (host == nullptr || !zsh) {
    return;
  }

  TemporaryDirectory home{"/tmp/telar-shell-XXXXXX"};
  const ShellIntegration<SystemAllocator> integration{memory, ShellIntegration<SystemAllocator>::install(memory, home.path()), true};
  const std::array<std::string_view, 3> arguments{*zsh, "-l", "-i"};
  Command command{memory, Launch{.cwd = home.path(), .arguments = arguments}};
  command.setEnvironment("HOME", home.path());
  command.removeEnvironment("ZDOTDIR");
  RuntimeModel model{memory};
  auto owned = makeOwned<Pane<SystemAllocator>>(memory, memory, 7, TabLocation{}, command, PaneLaunch{TerminalSize{80, 24, 8, 16}, model.media_budget, model.graphics_limits, integration.apply(command)});
  auto &pane = *owned;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{30};
  const auto until = [&](auto ready) {
    while (!ready()) {
      check(std::chrono::steady_clock::now() < deadline);
      pollfd pending{.fd = pane.process->descriptor(), .events = POLLIN, .revents = 0};
      if (::poll(&pending, 1, 20) > 0) {
        check(pane.read());
      }
      // The terminal's answers, as fish waits for one to its device attributes query.
      pane.write();
      pane.observeShell();
    }
  };
  const auto type = [&](std::string_view line) {
    pane.enqueueInput(bytes(line));
    pane.write();
  };

  until([&] { return pane.shell_state.phase == ShellPhase::prompt && !pane.shell_state.remote; });
  type("ssh " + text(host) + "\r");
  until([&] { return pane.shell_state.phase == ShellPhase::prompt && pane.shell_state.remote; });
  check(pane.shell_state.shell != IntegratedShell::none && !pane.shell_state.shell_foreground);
  std::array<CommandBlock, PaneBlocks::capacity> storage;
  const auto last = [&] { return pane.blocks->message(7, storage).blocks.back(); };
  // ssh's block stays open while its session lasts.
  check(last().state == CommandBlockState::session && last().nest == CommandBlockNest::opens);
  const auto remote = pane.shell_state.commands;
  type("false\r");
  until([&] { return pane.shell_state.commands == remote + 1 && pane.shell_state.phase == ShellPhase::prompt; });
  check(pane.shell_state.status == 1 && pane.shell_state.remote && !pane.shell_state.host.empty() && !pane.shell_state.directory.empty());
  check(last().state == CommandBlockState::failed && last().nest == CommandBlockNest::inside);
  // The remote line editor's echo timed the link.
  check(pane.shell_state.link_ms > 0);
  type("exit 7\r");
  until([&] { return pane.shell_state.phase == ShellPhase::prompt && !pane.shell_state.remote; });
  // The ssh command finishes with the status the remote shell exited with. fish reports its
  // `exit` as a command too.
  check(pane.shell_state.shell == IntegratedShell::zsh && pane.shell_state.commands >= remote + 2 && pane.shell_state.status == 7);
  const auto blocks = pane.blocks->message(7, storage).blocks;
  const auto opened = std::ranges::find(blocks, CommandBlockNest::opens, &CommandBlock::nest);
  check(opened != blocks.end() && opened->state == CommandBlockState::failed && opened->status == 7);
  type("exit\r");
}

// An ssh whose remote shell takes over keeps its block open, the remote commands after it,
// until the pane's shell is back and ends it with ssh's status.
void sessionBlocks(SystemAllocator &memory) {
  Terminal<SystemAllocator> terminal{memory, TerminalSize{40, 12, 8, 16}};
  CommandBlocks<SystemAllocator> blocks{memory, terminal};
  const auto now = std::chrono::steady_clock::now();
  const auto run = [&](std::string_view line) {
    blocks.mark('A', now);
    terminal.feed(bytes("$ "));
    blocks.mark('B', now);
    terminal.feed(bytes(std::string{line} + "\r\n"));
    blocks.mark('C', now);
  };
  std::array<CommandBlock, PaneBlocks::capacity> storage;
  const auto shown = [&] { return blocks.message(7, storage).blocks; };

  run("ssh box");
  blocks.mark('N', now);
  terminal.feed(bytes("welcome\r\n"));
  // The remote shell's first prompt reports the status of nothing it ran.
  blocks.finished(0, now);
  check(shown().size() == 1 && shown()[0].state == CommandBlockState::session && shown()[0].nest == CommandBlockNest::opens);
  run("ls");
  blocks.finished(0, now);
  run("sleep 9");
  check(shown().size() == 3 && shown()[1].state == CommandBlockState::succeeded && shown()[1].nest == CommandBlockNest::inside);
  check(shown()[0].state == CommandBlockState::session && shown()[2].state == CommandBlockState::running);
  // The link drops mid-command: the remote command is cut, and ssh ends with its own status.
  blocks.mark('U', now);
  blocks.finished(255, now);
  check(shown()[2].state == CommandBlockState::interrupted);
  check(shown()[0].state == CommandBlockState::failed && shown()[0].status == 255);
  run("pwd");
  check(shown().size() == 4 && shown()[3].nest == CommandBlockNest::none);
}

// The repository a shell works in, read on the git worker.
void gitContext() {
  if (!findProgram("git")) {
    std::puts("shell integration: git not installed, skipped");
    return;
  }
  TemporaryDirectory repository{"/tmp/telar-git-XXXXXX"};
  const auto run = [&](std::string_view command) {
    const auto line = "cd " + text(repository.path()) + " && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 " + text(command) + " >/dev/null 2>&1";
    check(std::system(line.c_str()) == 0);
  };
  run("git init -q -b trunk . && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m first && touch new && echo x > tracked && git add tracked");

  ShellGitService service;
  service.request(7, 1, repository.path());
  std::optional<ShellGitResult> result;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  while (!result) {
    check(std::chrono::steady_clock::now() < deadline);
    pollfd ready{.fd = service.descriptor(), .events = POLLIN, .revents = 0};
    ::poll(&ready, 1, 50);
    service.collect([&](const ShellGitResult &value) { result = value; });
  }
  check(result->pane == 7 && result->generation == 1);
  const auto &summary = result->summary;
  check(summary.repository && !summary.detached && summary.branch.view() == "trunk");
  check(summary.changes_known && summary.staged == 1 && summary.unstaged == 0);
  const auto message = summary.message(7);
  check(message.pane_id == 7 && message.branch == "trunk");

  run("git branch feature/x && git branch other");
  WordReader reader;
  WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::branch, .prefix = {}, .directory = {}, .home = {}, .path = {}};
  request.directory.assign(repository.path());
  const auto texts = [&](const WordRequest &query) {
    std::vector<std::string> result;
    for (const auto &word : reader.observe(query).words) {
      result.push_back(word.text);
    }
    return result;
  };
  check(texts(request) == std::vector<std::string>{"feature/x", "other", "trunk"});
  run("git remote add upstream https://example.invalid/r.git && echo a > stashed && git add stashed && git -c user.name=t -c user.email=t@t stash -q && git -c user.name=t -c user.email=t@t stash -q --include-untracked 2>/dev/null; true");
  request.provider = CompletionProvider::remote;
  check(texts(request) == std::vector<std::string>{"upstream"});
  request.provider = CompletionProvider::stash;
  check(texts(request).size() >= 1 && texts(request).front() == "stash@{0}");
}

// The values completion asks the runtime for, read from files the shell's machine holds.
void words() {
  TemporaryDirectory root{"/tmp/telar-words-XXXXXX"};
  const auto base = text(root.path());
  const auto make = [&](std::string_view relative, std::string_view contents, mode_t mode) {
    const auto path = base + "/" + text(relative);
    auto *file = std::fopen(path.c_str(), "w");
    check(file != nullptr);
    std::fputs(text(contents).c_str(), file);
    std::fclose(file);
    check(::chmod(path.c_str(), mode) == 0);
  };
  check(::mkdir((base + "/bin").c_str(), 0700) == 0 && ::mkdir((base + "/.ssh").c_str(), 0700) == 0);
  make("bin/telar-one", "", 0700);
  make("bin/telar-two", "", 0700);
  make("bin/telar-data", "", 0600);
  make(".ssh/config", "Host build-01 build-02\n  HostName x\nhost *.internal\nHost=builder\nMatch all\n", 0600);
  make("Makefile", "all: build\nbuild test: deps\n\tcc\n.PHONY: all\nVAR := 1\n%.o: %.c\ninstall::\n", 0600);

  WordReader reader;
  const auto ask = [&](CompletionProvider provider, std::string_view prefix) {
    WordRequest request{.client = 1, .request = 9, .provider = provider, .prefix = {}, .directory = {}, .home = {}, .path = {}};
    request.prefix.assign(prefix);
    request.directory.assign(root.path());
    request.home.assign(root.path());
    request.path.assign(base + "/bin:relative:/nonexistent");
    const auto result = reader.observe(request);
    check(result.client == 1 && result.request == 9);
    std::vector<std::string> texts;
    for (const auto &word : result.words) {
      texts.push_back(word.text);
    }
    return texts;
  };
  check(ask(CompletionProvider::command, "telar-") == std::vector<std::string>{"telar-one", "telar-two"});
  // A shell's builtins and the names it reported count as commands; until it reports them,
  // the list cannot tell a missing command.
  WordRequest named{.client = 1, .request = 4, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};
  named.prefix.assign("gs");
  named.path.assign(base + "/bin");
  check(reader.observe(named).truncated && reader.observe(named).words.empty());
  named.shell = IntegratedShell::zsh;
  named.names = std::make_shared<const std::string>("gst  ll gsw");
  const auto names = reader.observe(named);
  check(!names.truncated && names.words.size() == 2 && names.words[0].text == "gst" && names.words[1].text == "gsw");
  named.prefix.assign("setop");
  check(reader.observe(named).words.size() == 1 && reader.observe(named).words[0].text == "setopt");
  check(ask(CompletionProvider::ssh_host, "build") == std::vector<std::string>{"build-01", "build-02", "builder"});
  check(ask(CompletionProvider::make_target, "") == std::vector<std::string>{"all", "build", "install", "test"});
  // Files read for values: a justfile's public recipes and aliases, the nearest package.json's
  // scripts and a compose file's services, from the directory or one of its parents.
  make("justfile", "set shell := [\"zsh\", \"-c\"]\nversion := \"1\"\n# Build everything\nbuild target='all':\n    echo {{target}}\n\n[private]\nhidden:\n    true\n_helper:\n    true\n@test *args: build\n    true\nalias b := build\n[doc('Ship it')]\ndeploy-prod:\n    true\n", 0600);
  make("package.json", "{\"name\": \"x\", \"scripts\": {\"dev\": \"vite\", \"test:unit\": \"vitest run\"}}", 0600);
  make("compose.yaml", "name: x\nservices:\n  web:\n    image: nginx\n    ports:\n      - \"80:80\"\n  \"db\":\n    image: postgres\nvolumes:\n  data:\n", 0600);
  check(ask(CompletionProvider::just_recipe, "") == std::vector<std::string>{"b", "build", "deploy-prod", "test"});
  check(ask(CompletionProvider::package_script, "") == std::vector<std::string>{"dev", "test:unit"});
  check(ask(CompletionProvider::compose_service, "") == std::vector<std::string>{"db", "web"});
  check(::mkdir((base + "/nested").c_str(), 0700) == 0);
  WordRequest nested{.client = 1, .request = 9, .provider = CompletionProvider::just_recipe, .prefix = {}, .directory = {}, .home = {}, .path = {}};
  nested.directory.assign(base + "/nested");
  const auto from_child = reader.observe(nested).words;
  check(from_child.size() == 4 && from_child[1].text == "build" && from_child[1].description == "Build everything" && from_child[2].description == "Ship it" && from_child[0].description == "Alias of build");
  check(ask(CompletionProvider::branch, "").empty());

  // Command specs: offered for a command the shell runs, from the user's completions
  // directory when it compiles, else the one telar ships; an unchanged one is not sent again.
  for (const auto &[name, source] : shipped::specs) {
    try {
      static_cast<void>(ebnf::command_spec::compile(source));
    } catch (const std::exception &error) {
      std::fprintf(stderr, "spec %.*s: %s\n", static_cast<int>(name.size()), name.data(), error.what());
      check(false);
    }
  }
  check(std::ranges::find(shipped::specs, std::string_view{"telar"}, &std::pair<std::string_view, std::string_view>::first) != shipped::specs.end());
  make("bin/nmap", "", 0700);
  std::string reported = "gst";
  const auto spec = [&](std::string_view command, std::uint64_t known = 0) {
    WordRequest request{.client = 1, .request = 5, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};
    request.prefix.assign(command);
    request.path.assign(base + "/bin");
    request.shell = IntegratedShell::zsh;
    request.names = std::make_shared<const std::string>(reported);
    request.spec = true;
    request.known_digest = known;
    return reader.observe(request);
  };
  const auto saved_config = std::getenv("XDG_CONFIG_HOME") == nullptr ? std::optional<std::string>{} : std::optional<std::string>{std::getenv("XDG_CONFIG_HOME")};
  ::setenv("XDG_CONFIG_HOME", base.c_str(), 1);
  const auto nmap = spec("nmap");
  check(nmap.spec && nmap.command == "nmap" && nmap.spec_state == CommandSpecState::available && nmap.source.find("nmap = ") != std::string::npos && nmap.digest != 0);
  check(spec("nmap", nmap.digest).spec_state == CommandSpecState::unchanged && spec("nmap", nmap.digest).source.empty());
  check(spec("git").spec_state == CommandSpecState::unavailable);
  check(spec("cd").spec_state == CommandSpecState::available);
  check(spec("../nmap").spec_state == CommandSpecState::unavailable);
  // An alias completes as the command it stands for, through aliases of aliases; one that
  // names itself (ls='ls -G') stands for that command.
  make("bin/git", "", 0700);
  reported = "n=nmap gst=git%20status gl=gst%20--oneline less=less%20-R weird f";
  const auto alias = spec("n");
  check(alias.spec_state == CommandSpecState::available && alias.expansion == "nmap" && alias.source == nmap.source && alias.digest == nmap.digest);
  check(spec("gst").expansion == "git status" && spec("gst").source.find("git = ") != std::string::npos);
  check(spec("gl").expansion == "git status --oneline");
  check(spec("less").spec_state == CommandSpecState::unavailable);
  check(spec("weird").spec_state == CommandSpecState::unavailable && spec("weird").expansion.empty());
  reported = "gst";
  check(::mkdir((base + "/telar").c_str(), 0700) == 0 && ::mkdir((base + "/telar/completions").c_str(), 0700) == 0);
  make("telar/completions/nmap.ebnf", "nmap = { \"--mine\" : \"The user's own\" } ;\n", 0600);
  const auto users = spec("nmap");
  check(users.spec_state == CommandSpecState::available && users.source.find("--mine") != std::string::npos && users.digest != nmap.digest);
  make("telar/completions/nmap.ebnf", "nmap = { \"--broken\" \n", 0600);
  check(spec("nmap").source == nmap.source);
  if (saved_config) {
    ::setenv("XDG_CONFIG_HOME", saved_config->c_str(), 1);
  } else {
    ::unsetenv("XDG_CONFIG_HOME");
  }

  // This process is the user's, named; newer ones come first. The prefix also matches
  // longer process identifiers, newer than this one, so it need not be the first.
  WordRequest processes{.client = 1, .request = 3, .provider = CompletionProvider::process, .prefix = {}, .directory = {}, .home = {}, .path = {}};
  processes.prefix.assign(std::to_string(::getpid()));
  const auto own = reader.observe(processes).words;
  const auto found = std::ranges::find(own, std::to_string(::getpid()), &Word::text);
  check(found != own.end() && !found->description.empty());
  check(std::ranges::is_sorted(own, std::greater{}, [](const Word &word) { return std::stoll(word.text); }));
}

void testShellIntegration() {
  SystemAllocator memory;
  detection();
  preparation(memory);
  shells(memory);
  sshArguments(memory);
  paneState(memory);
  sessionBlocks(memory);
  sshSession(memory);
  gitContext();
  words();
}
