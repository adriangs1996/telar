#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include "telar_base/memory/allocator.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.history;
import telar.wire.runtime;
import telar.gui.foundation.core;
import telar.config.client;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  namespace prompt = telar::gui::application::prompt;

  template <typename Client>
  void typeKeys(Client& client, std::string_view keys) {
    for (std::size_t index = 0; index < keys.size(); ++index) {
      const auto outcome = prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = static_cast<char32_t>(keys[index]), .text = keys.substr(index, 1)});

      check(outcome == prompt::Outcome::edited, "typing must edit the line");
    }
  }

  template <typename Client>
  prompt::Outcome enter(Client& client) {
    return prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::enter});
  }

  PaneShell atPrompt(std::uint32_t commands = 0, std::int32_t status = 0) {
    return PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true, .commands = commands, .status = status};
  }

  PaneShell running(std::uint32_t commands, bool echo = true) {
    // A canonical tty's ^C, ^\, ^Z and ^D.
    constexpr Byte interrupt_key = 3;
    constexpr Byte quit_key = 28;
    constexpr Byte suspend_key = 26;
    constexpr Byte end_of_file_key = 4;

    return PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::running, .canonical = true, .echo = echo, .signal_keys = true, .interrupt = interrupt_key, .quit = quit_key, .suspend = suspend_key, .end_of_file = end_of_file_key, .commands = commands};
  }

  void lineRunsCommands() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    frame.input_modes.bracketed_paste = true;
    deliverSingleCell(client, frame);

    check(deliver(client, atPrompt()) == application::Change::terminal, "the shell's state must repaint its pane");
    check(prompt::surface(client, 1) == prompt::Surface::none, "classic mode keeps the terminal");
    check(transport.count(ClientTag::configure_shell_prompt) == 1 && !transport.last<ConfigureShellPrompt>().bare, "a classic client keeps the prompt of the shells it opens");
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);
    check(prompt::surface(client, 1) == prompt::Surface::editor, "telar mode edits at the shell's prompt");
    check(transport.count(ClientTag::configure_shell_prompt) == 2 && transport.last<ConfigureShellPrompt>().bare, "telar mode asks for bare prompts in the shells it opens next");
    application::configuration::configure(client, configuration);
    check(transport.count(ClientTag::configure_shell_prompt) == 2, "an unchanged mode is not sent again");

    auto before = transport.sent.size();

    check(enter(client) == prompt::Outcome::edited && transport.inputSince(before).empty() && transport.commandsSince(before).empty(), "Enter on an empty line sends nothing, so the shell prints no prompt of its own");
    typeKeys(client, "  ");
    check(enter(client) == prompt::Outcome::edited && transport.inputSince(before).empty() && transport.commandsSince(before).empty() && prompt::line(client, 1)->text().empty(), "a blank line runs nothing and clears");

    typeKeys(client, "ls -la");
    check(transport.inputSince(before).empty(), "typing stays in the line");
    check(enter(client) == prompt::Outcome::run, "Enter runs a complete command");
    check(transport.commandsSince(before) == std::vector<std::string>{"ls -la"} && transport.inputSince(before).empty(), "the command reaches the runtime whole, which types it at the prompt");
    check(prompt::line(client, 1)->text().empty() && prompt::line(client, 1)->recent().back() == "ls -la", "the line clears and remembers it");

    before = transport.sent.size();
    typeKeys(client, "echo 'a");
    check(enter(client) == prompt::Outcome::edited && transport.inputSince(before).empty(), "an open quote continues on a new line");
    typeKeys(client, "b'");
    check(enter(client) == prompt::Outcome::run && transport.commandsSince(before) == std::vector<std::string>{"echo 'a\nb'"}, "a multi-line command runs whole");

    before = transport.sent.size();
    client.paste(1, "git status\x1b[201~; rm -rf ~");
    check(transport.inputSince(before).empty() && prompt::line(client, 1)->text() == "git status[201~; rm -rf ~", "a paste lands in the line without its controls");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    check(prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'd', .modifiers = {.control = true}}) == prompt::Outcome::bytes && transport.inputSince(before) == "\x04", "Ctrl-D on an empty line ends the shell");

    // A command queued while another runs waits for it and runs after a success.
    deliver(client, running(1));
    check(prompt::surface(client, 1) == prompt::Surface::running, "a running program queues keys");
    check(prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'c', .modifiers = {.control = true}}) == prompt::Outcome::terminal, "Ctrl-C belongs to the program");
    before = transport.sent.size();
    typeKeys(client, "make test");
    enter(client);
    check(prompt::line(client, 1)->queued() && transport.inputSince(before).empty(), "Enter arms the queued command");
    deliver(client, atPrompt(2, 0));
    check(transport.commandsSince(before) == std::vector<std::string>{"make test"}, "a success runs the queued command");

    deliver(client, running(2));
    before = transport.sent.size();
    typeKeys(client, "deploy");
    enter(client);
    deliver(client, atPrompt(3, 1));
    check(transport.inputSince(before).empty() && prompt::line(client, 1)->text() == "deploy", "a failure keeps the queued command as a draft");

    // A password prompt gets the keys; the line only counts them.
    deliver(client, running(3, false));
    check(prompt::surface(client, 1) == prompt::Surface::secret, "echo off is a secret");
    check(prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'a', .text = "a"}) == prompt::Outcome::terminal, "secret keys go to the terminal");
    client.input(1, "a");
    client.input(1, "b");
    check(prompt::line(client, 1)->secretKeys() == 2, "the line counts the hidden keys");
    deliver(client, atPrompt(4, 0));
    check(prompt::line(client, 1)->secretKeys() == 0, "the count clears with the prompt");

    frame.frame_id = 2;
    frame.input_modes.alternate_screen = true;
    deliverSingleCell(client, frame);
    check(prompt::surface(client, 1) == prompt::Surface::none, "a full-screen program keeps the terminal");
  }

  // A command the shell cannot receive stays in the editor with its error: nothing is sent,
  // cleared or remembered until it can be.
  void lineKeepsUnsendableCommands() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);
    deliver(client, atPrompt());

    const auto refused = [&] {
      try {
        static_cast<void>(enter(client));
      } catch (const std::exception&) {
        return true;
      }

      return false;
    };

    // Without bracketed paste the shell would run each line of it on its own.
    const auto before = transport.sent.size();

    typeKeys(client, "echo 'a");
    check(enter(client) == prompt::Outcome::edited, "an open quote continues on a new line");
    typeKeys(client, "b'");
    check(refused(), "a multi-line command the shell cannot take whole is refused");
    check(transport.commandsSince(before).empty() && transport.inputSince(before).empty(), "nothing reaches the shell");
    check(prompt::line(client, 1)->text() == "echo 'a\nb'", "the command stays in the editor");
    check(prompt::line(client, 1)->recent().empty() && prompt::history(client).empty(), "a command never sent is not remembered");

    // An answer to a running program is checked the same way.
    deliver(client, running(1));
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::enter, .modifiers = {.alt = true}});
    check(prompt::line(client, 1)->answering(), "Alt-Enter answers the program");
    check(refused() && prompt::line(client, 1)->text() == "echo 'a\nb'" && transport.inputSince(before).empty(), "an answer the program cannot take stays in the editor");

    // C1 controls act on the terminal: a paste drops them as it drops the others.
    deliver(client, atPrompt(2, 0));
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'c', .modifiers = {.control = true}});
    client.paste(1, "a\xc2\x9b"
                    "2Jb");
    check(prompt::line(client, 1)->text() == "a2Jb", "a pasted C1 control is dropped");
  }

  // A frame of one row, the cursor at `column` on it.
  struct Row {
    std::uint64_t frame_id = 0;
    std::uint16_t column = 0;
  };

  // One row of two cells.
  template <typename Client>
  void deliverRow(Client& client, Row row) {
    const ds::Array cells{Cell{.text = byteView("$")}, Cell{.text = byteView(" ")}};
    constexpr std::size_t cell_capacity = 64;
    ds::Array<Byte, cell_capacity> encoded{};
    const ds::Array spans{FrameSpan{.start = 0, .count = 2, .cells = CellRunCodec::encode(cells, encoded.viewMut())}};
    const ds::Array<Byte, 1> flags{};
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = row.frame_id;
    frame.cols = 2;
    frame.rows = 1;
    frame.scroll.total_rows = 1;
    frame.cursor = {.visible = true, .x = row.column, .y = 0};
    frame.text_metadata = TextMetadata{.row_flags = flags};
    frame.spans = spans;
    deliver(client, PaneFrame{frame});
  }

  void lineHidesTerminalCursor() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    deliverRow(client, {.frame_id = 1, .column = 0});
    deliver(client, running(1));
    check(!prompt::hidesTerminalCursor(client, 1), "classic mode draws the terminal's cursor");

    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);
    check(prompt::hidesTerminalCursor(client, 1), "a quick command's cursor at a line's start, where no key lands, is not drawn");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::enter, .modifiers = {.alt = true}});
    check(prompt::line(client, 1)->answering() && !prompt::hidesTerminalCursor(client, 1), "answering the program, the keys land at its cursor");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::enter, .modifiers = {.alt = true}});
    deliverRow(client, {.frame_id = 2, .column = 1});
    check(!prompt::hidesTerminalCursor(client, 1), "a program that printed a question shows where its answer goes");

    deliverRow(client, {.frame_id = 3, .column = 0});
    deliver(client, PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::unknown, .shell_foreground = true, .commands = 2});
    check(prompt::hidesTerminalCursor(client, 1), "between a command's end and the next prompt the editor is about to take the row");
    deliver(client, PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::unknown, .shell_foreground = true});
    check(!prompt::hidesTerminalCursor(client, 1), "a shell that never marked a command keeps its cursor");
    deliver(client, atPrompt(2));
    check(prompt::surface(client, 1) == prompt::Surface::editor && prompt::hidesTerminalCursor(client, 1), "at the prompt the editor has the keys, so the terminal's cursor is not drawn");
  }

  // A command is marked found or missing while it is typed: an answer that lists every command
  // under a prefix settles the longer words typed after it without asking again.
  void commandsSettleAsTyped() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    deliver(client, atPrompt());
    check(prompt::commandPresence(client, 1, "g") == prompt::CommandPresence::pending, "the first letter asks the runtime");
    const auto asked = transport.last<CompleteWords>();
    const auto requests = transport.count(ClientTag::complete_words);
    const ds::Array words{CompletionWord{.text = "git"}, CompletionWord{.text = "gzip"}};

    deliver(client, CompletionWords{.request_id = asked.request_id, .truncated = false, .words = words});
    check(prompt::commandPresence(client, 1, "g") == prompt::CommandPresence::missing, "no command is named g");
    check(prompt::commandPresence(client, 1, "gi") == prompt::CommandPresence::missing && prompt::commandPresence(client, 1, "git") == prompt::CommandPresence::found && prompt::commandPresence(client, 1, "gzx") == prompt::CommandPresence::missing, "longer words settle from the listing");
    check(transport.count(ClientTag::complete_words) == requests, "without asking again");

    check(prompt::commandPresence(client, 1, "m") == prompt::CommandPresence::pending, "another prefix asks");
    const auto cut = transport.last<CompleteWords>();

    deliver(client, CompletionWords{.request_id = cut.request_id, .truncated = true, .words = {}});
    check(prompt::commandPresence(client, 1, "ma") == prompt::CommandPresence::pending && transport.count(ClientTag::complete_words) == requests + 2, "a cut listing settles nothing longer");
  }

  template <typename Client>
  void tab(Client& client) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::tab});
  }

  // A prompt request the runtime fails, or a lost connection never answers, settles quietly
  // instead of waiting forever.
  void promptRequestsSettleOnFailure() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);
    deliver(client, atPrompt());

    check(prompt::commandPresence(client, 1, "g") == prompt::CommandPresence::pending, "the first letter asks the runtime");
    const auto checked = transport.last<CompleteWords>();

    check(deliver(client, RequestFailed{.request_id = checked.request_id, .code = FailureCode::pane_not_found, .message = "Check failed"}) == application::Change::terminal && client.error().empty(), "a failed command check repaints its pane without an error");
    check(prompt::commandPresence(client, 1, "g") == prompt::CommandPresence::unknown, "the word stops waiting");

    typeKeys(client, "cat sr");
    tab(client);
    const auto spec = transport.last<RequestCommandSpec>();

    check(deliver(client, RequestFailed{.request_id = spec.request_id, .code = FailureCode::pane_not_found, .message = "Spec failed"}) == application::Change::none && client.error().empty(), "a failed spec is no error");
    tab(client);
    const auto find = transport.last<FindPaths>();

    check(find.request_id > spec.request_id && prompt::line(client, 1)->pending(find.request_id), "Tab completes without the spec it could not get");
    check(deliver(client, RequestFailed{.request_id = find.request_id, .code = FailureCode::pane_not_found, .message = "Paths failed"}) == application::Change::terminal && client.error().empty(), "a failed path search repaints the line without an error");
    check(!prompt::line(client, 1)->pending(find.request_id), "the menu stops waiting for it");

    tab(client);
    const auto lost = transport.last<FindPaths>();

    check(lost.request_id > find.request_id && prompt::line(client, 1)->pending(lost.request_id), "Tab asks again");
    client.disconnected();
    check(!prompt::line(client, 1)->pending(lost.request_id), "a lost connection answers no request");
  }

  // Commands run after the history loaded replace its oldest entries instead of growing it.
  void promptHistoryStaysBounded() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);
    deliver(client, atPrompt());

    // The line keeps the newest thousand commands.
    constexpr std::size_t history_capacity = 1000;

    for (std::size_t index = 0; index <= history_capacity; ++index) {
      typeKeys(client, "c" + std::to_string(index));
      check(enter(client) == prompt::Outcome::run, "Enter runs the command");
    }

    const auto history = prompt::history(client);

    check(history.size() == history_capacity && history.front() == "c1000" && history.back() == "c1", "the newest thousand commands are kept, newest first");
  }

  // A pane that leaves the model takes its prompt and the requests it made with it.
  void paneRemovalForgetsPrompt() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);
    deliver(client, atPrompt());

    check(prompt::commandPresence(client, 1, "g") == prompt::CommandPresence::pending, "the first letter asks the runtime");
    const auto checked = transport.last<CompleteWords>();

    typeKeys(client, "ls");
    check(prompt::line(client, 1).hasValue(), "the pane has a line");

    deliver(client, PaneExited{.pane_id = 1, .kind = ExitKind::exited});
    check(!prompt::line(client, 1), "the line goes with its pane");
    const ds::Array words{CompletionWord{.text = "git"}};

    check(deliver(client, CompletionWords{.request_id = checked.request_id, .words = words}) == application::Change::none, "an answer for a pane that left finds nothing waiting");
  }

  // The digest the runtime gives git's spec.
  constexpr std::uint64_t git_spec_digest = 7;

  // Tab completes from a command's spec, and an alias from the spec of the command it stands for.
  template <typename Client>
  void completesFromSpecs(Client& client, Transport& transport) {
    // The spec of a command comes from the runtime, asked the first time Tab needs it; the Tab
    // completes once it arrives.
    typeKeys(client, "git sw");
    tab(client);
    const auto asked = transport.last<RequestCommandSpec>();

    check(asked.command == "git" && asked.pane_id == 1 && asked.known_digest == 0 && prompt::line(client, 1)->text() == "git sw", "Tab asks the runtime for the command's spec and waits");
    constexpr std::string_view git_spec = R"(git = [ command ] ;
command = "switch" : "Switch branches" , { @branch } | "status" : "Show the working tree status" | "stash" : "Stash the changes" ;)";

    check(deliver(client, CommandSpec{.request_id = asked.request_id, .command = "git", .state = CommandSpecState::available, .digest = git_spec_digest, .source = git_spec}) == application::Change::terminal, "the spec completes the waiting Tab");
    check(prompt::line(client, 1)->text() == "git switch ", "one choice from the spec is written with a space");

    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "git s");
    tab(client);
    const auto& menu = prompt::line(client, 1)->menu();

    check(menu && menu->choices.size() > 1 && menu->choices[0].text.view().starts_with('s'), "several choices open the menu");
    check(!menu->choices[0].description.empty(), "choices carry the spec's description");
    const auto second = menu->choices[1].text.clone();

    tab(client);
    enter(client);
    const auto taken = prompt::line(client, 1)->text();

    check(taken.starts_with("git ") && taken.substr(4) == std::format("{} ", second) && !prompt::line(client, 1)->menu(), "Tab moves through the menu and Enter takes the choice");

    // An alias completes as the words it stands for, with its command's spec.
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "gs st");
    tab(client);
    const auto alias = transport.last<RequestCommandSpec>();

    check(alias.command == "gs" && alias.known_digest == 0, "an alias's spec is asked for under its name");
    deliver(client, CommandSpec{.request_id = alias.request_id, .command = "gs", .state = CommandSpecState::unchanged, .digest = git_spec_digest, .source = {}, .expansion = "git"});
    const auto& aliased = prompt::line(client, 1)->menu();

    check(aliased && aliased->choices.size() == 2 && std::ranges::any_of(aliased->choices, [](const prompt::Choice& choice) {
      return choice.text == "stash";
    }) && std::ranges::any_of(aliased->choices, [](const prompt::Choice& choice) {
      return choice.text == "status";
    }),
        "the alias completes with git's spec");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "gsw fe");
    tab(client);
    const auto several = transport.last<RequestCommandSpec>();

    deliver(client, CommandSpec{.request_id = several.request_id, .command = "gsw", .state = CommandSpecState::unchanged, .digest = git_spec_digest, .source = {}, .expansion = "git switch"});
    check(transport.last<CompleteWords>().provider == CompletionProvider::branch, "an alias of several words completes after all of them");
    deliver(client, CompletionWords{.request_id = transport.last<CompleteWords>().request_id, .words = {}});
  }

  // Tab completes files and commands from the runtime, and typing narrows what it offered.
  template <typename Client>
  void completesFromRuntime(Client& client, Transport& transport) {
    // A command without a spec completes files from the runtime, one directory at a time.
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "cat sr");
    tab(client);
    const auto cat = transport.last<RequestCommandSpec>();

    check(cat.command == "cat", "a command's spec is asked for once");
    deliver(client, CommandSpec{.request_id = cat.request_id, .command = "cat", .state = CommandSpecState::unavailable, .digest = 0, .source = {}});
    const auto find = transport.last<FindPaths>();

    check(find.root.starts_with('/') && find.query == "sr" && prompt::line(client, 1)->pending(find.request_id), "paths are asked from the runtime");
    const ds::Array matches{PathMatch{.path = "src/", .kind = PathKind::directory}, PathMatch{.path = "src/main.cpp", .kind = PathKind::file}, PathMatch{.path = "README", .kind = PathKind::file}};

    check(deliver(client, PathResults{.request_id = find.request_id, .root = find.root, .complete = true, .matches = matches}) == application::Change::terminal, "the answer repaints the line");
    check(prompt::line(client, 1)->text() == "cat src/", "the only child that matches is written, a directory without a space");

    typeKeys(client, "my file");
    check(prompt::line(client, 1)->text() == "cat src/my file", "typing after a completion edits as usual");

    // A command's name comes from the shell's PATH, through the runtime.
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "tel");
    tab(client);
    const auto commands = transport.last<CompleteWords>();

    check(commands.provider == CompletionProvider::command && commands.prefix == "tel" && commands.pane_id == 1, "the runtime is asked for commands");
    const ds::Array found{CompletionWord{.text = "telar"}, CompletionWord{.text = "telnet"}};

    deliver(client, CompletionWords{.request_id = commands.request_id, .words = found});
    check(prompt::line(client, 1)->menu() && prompt::line(client, 1)->menu()->choices.size() == 2, "the runtime's commands fill the menu");

    // Typing with the menu open narrows it; a single choice left waits for the user.
    const auto asked_words = transport.count(ClientTag::complete_words);

    typeKeys(client, "a");
    check(prompt::line(client, 1)->text() == "tela" && prompt::line(client, 1)->menu() && prompt::line(client, 1)->menu()->choices.size() == 1 && prompt::line(client, 1)->menu()->choices[0].text == "telar", "typing narrows the menu");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::backspace});
    check(prompt::line(client, 1)->menu() && prompt::line(client, 1)->menu()->choices.size() == 2 && transport.count(ClientTag::complete_words) == asked_words, "erasing back to the word it offered widens the menu without asking");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::backspace});
    const auto wider = transport.last<CompleteWords>();

    check(transport.count(ClientTag::complete_words) == asked_words + 1 && wider.prefix == "te", "erasing past it asks again");
    const ds::Array widened{CompletionWord{.text = "tee"}};

    deliver(client, CompletionWords{.request_id = wider.request_id, .words = widened});
    check(prompt::line(client, 1)->text() == "te" && prompt::line(client, 1)->menu() && prompt::line(client, 1)->menu()->choices.size() == 1, "a single answer to a refined menu is not written");
    typeKeys(client, "x");
    check(!prompt::line(client, 1)->menu() && prompt::line(client, 1)->text() == "tex", "nothing left closes the menu");

    // A list the runtime cut asks again as typing narrows it.
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "t");
    tab(client);
    const auto cut = transport.last<CompleteWords>();

    deliver(client, CompletionWords{.request_id = cut.request_id, .truncated = true, .words = found});
    typeKeys(client, "e");
    check(transport.last<CompleteWords>().prefix == "te" && transport.last<CompleteWords>().request_id != cut.request_id, "a cut list asks again");
    deliver(client, CompletionWords{.request_id = transport.last<CompleteWords>().request_id, .words = found});
    typeKeys(client, "l ");
    check(!prompt::line(client, 1)->menu() && prompt::line(client, 1)->text() == "tel ", "a space leaves the word and closes the menu");
  }

  // A spec's provider completes branches, and the history suggests whole commands.
  template <typename Client>
  void completesFromProviders(Client& client, Transport& transport) {
    // A spec's provider: git switch asks for branches.
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "git switch fe");
    tab(client);
    const auto branches = transport.last<CompleteWords>();

    check(branches.provider == CompletionProvider::branch && branches.prefix == "fe", "branches are asked for where the spec expects one");
    const ds::Array branch{CompletionWord{.text = "feature/island", .description = ""}};

    deliver(client, CompletionWords{.request_id = branches.request_id, .words = branch});
    check(prompt::line(client, 1)->text() == "git switch feature/island ", "the only branch is written");

    // Suggestions come from the history, newest first, and from what the line just sent.
    const auto query = transport.last<QueryHistory>();

    check(query.distinct && query.author == HistoryAuthorFilter::human, "the line loads the commands people typed");
    const ds::Array entries{HistoryEntry{.id = 2, .pane_id = 1, .command = "make test-runtime", .cwd = "/"}, HistoryEntry{.id = 1, .pane_id = 1, .command = "make install", .cwd = "/"}};

    check(deliver(client, HistoryResults{.request_id = query.request_id, .snapshot_id = 1, .entries = entries}) == application::Change::none, "the editor's history does not touch the history panel");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "make t");
    check(prompt::suggestion(client, 1) == "est-runtime", "the newest command that extends the line is suggested");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::right});
    check(prompt::line(client, 1)->text() == "make test-runtime", "Right takes the suggestion");
    enter(client);
    typeKeys(client, "mak");
    check(prompt::suggestion(client, 1) == "e test-runtime", "a command sent from the line is suggested next");
  }

  // Where the spec does not accept the line, Tab offers files, as zsh and fish fall back to
  // theirs.
  template <typename Client>
  void fallsBackToFiles(Client& client, Transport& transport) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    const auto before = transport.count(ClientTag::find_paths);

    typeKeys(client, "git reset fi");
    tab(client);
    check(transport.count(ClientTag::find_paths) == before + 1 && transport.last<FindPaths>().query == "fi", "a subcommand the spec does not know completes files");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});
  }

  void lineCompletes() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    frame.input_modes.bracketed_paste = true;
    deliverSingleCell(client, frame);
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);
    deliver(client, atPrompt());

    completesFromSpecs(client, transport);
    completesFromRuntime(client, transport);
    completesFromProviders(client, transport);
    fallsBackToFiles(client, transport);

    // After a command the pane asks again, with the digest of the spec it holds: an unchanged
    // spec is not sent twice.
    auto next = atPrompt();

    next.commands = 1;
    deliver(client, next);
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "git sta");
    tab(client);
    const auto again = transport.last<RequestCommandSpec>();

    check(again.command == "git" && again.known_digest == git_spec_digest, "the pane asks again with the digest it holds");
    deliver(client, CommandSpec{.request_id = again.request_id, .command = "git", .state = CommandSpecState::unchanged, .digest = git_spec_digest, .source = {}});
    check(prompt::line(client, 1)->text() == "git stash " || (prompt::line(client, 1)->menu() && prompt::line(client, 1)->menu()->choices.size() == 2), "the spec it held completes");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});

    // A shell ssh reached: its files and commands are not this host's to offer.
    auto remote = atPrompt();

    remote.remote = true;
    deliver(client, remote);
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    const auto paths = transport.count(ClientTag::find_paths);
    const auto words = transport.count(ClientTag::complete_words);
    const auto specs = transport.count(ClientTag::request_command_spec);

    typeKeys(client, "cat sr");
    tab(client);
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'u', .modifiers = {.control = true}});
    typeKeys(client, "tel");
    tab(client);
    check(transport.count(ClientTag::find_paths) == paths && transport.count(ClientTag::complete_words) == words && transport.count(ClientTag::request_command_spec) == specs, "a remote shell asks the runtime for nothing");
    check(prompt::surface(client, 1) == prompt::Surface::editor, "its prompt is still edited");
  }

  void lineBindings() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    frame.input_modes.bracketed_paste = true;
    deliverSingleCell(client, frame);
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    configuration.prompt.keymap = PromptKeymap::vim;
    using Chord = runtime::config::KeyChord;

    // ctrl+j runs in insert mode; H goes to the line start in normal mode.
    configuration.prompt.bindings = {
        {.key = static_cast<std::uint8_t>(Chord::Key::character), .character = 'j', .modifiers = static_cast<unsigned>(Chord::Modifier::control), .action = static_cast<std::uint8_t>(prompt::Action::submit)},
        {.key = static_cast<std::uint8_t>(Chord::Key::character), .character = 'H', .modifiers = 0, .action = static_cast<std::uint8_t>(prompt::Action::line_start), .normal = true},
    };

    application::configuration::configure(client, configuration);
    deliver(client, atPrompt());

    typeKeys(client, "echo hi");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'H', .text = "H"});
    check(prompt::line(client, 1)->cursor() == 0 && prompt::line(client, 1)->text() == "echo hi", "a binding in normal mode replaces vim's own key");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'i', .text = "i"});
    const auto before = transport.sent.size();

    check(prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'j', .modifiers = {.control = true}}) == prompt::Outcome::run, "a bound key runs its action");
    check(transport.commandsSince(before) == std::vector<std::string>{"echo hi"}, "and submits like Enter");
  }

  template <typename Client>
  void control(Client& client, char key) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = static_cast<char32_t>(key), .modifiers = {.control = true}});
  }

  template <typename Client>
  void press(Client& client, char key) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = static_cast<char32_t>(key)});
  }

  // The command blocks, from the editor: stepped through from vim's normal mode, their output
  // selected in copy mode or copied whole, their command copied, and left for the prompt.
  void lineBlocks() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    configuration.prompt.keymap = PromptKeymap::vim;
    application::configuration::configure(client, configuration);
    deliver(client, atPrompt(3));
    const ds::Array blocks{
        CommandBlock{.row = 0, .rows = 1, .lines = 0, .state = CommandBlockState::succeeded, .status = 0, .duration_ms = 5, .command = "ls"},
        CommandBlock{.row = 4, .rows = 2, .lines = 0, .state = CommandBlockState::failed, .status = 1, .duration_ms = 9, .command = "make test"},
        CommandBlock{.row = 10, .rows = 1, .lines = 0, .state = CommandBlockState::succeeded, .status = 0, .duration_ms = 3, .command = "git status"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});

    // Insert mode types: Ctrl-U is the editor's there.
    control(client, 'u');
    check(!client.selectedBlock(1), "insert mode leaves the blocks alone");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});
    control(client, 'u');
    check(client.selectedBlock(1) == std::size_t{2} && client.takeBlockChange(), "Ctrl-U selects the last block");
    control(client, 'u');
    press(client, '[');
    press(client, '[');
    check(client.selectedBlock(1) == std::size_t{0}, "Ctrl-U and [[ step back");
    press(client, ']');
    press(client, ']');
    check(client.selectedBlock(1) == std::size_t{1}, "]] steps forward");

    // Y copies the block's whole output, from under its command to the next block's prompt.
    constexpr std::uint32_t output_first = 6;
    constexpr std::uint32_t output_last = 9;

    press(client, 'Y');
    const auto copied = transport.last<CopySelection>();

    check(copied.start_y == output_first && copied.end_y == output_last && copied.linewise, "Y copies the block's output");
    press(client, 'y');
    press(client, 'c');
    check(client.takeClipboardWrite() && std::string_view{client.clipboard()} == "make test", "yc copies its command");

    // v selects its output in copy mode, and the editor stays in place of the prompt.
    press(client, 'v');
    const auto& copy = application::terminal::copy_mode::view(client).state();

    check(copy && copy->pane_id == 1 && copy->anchor && copy->anchor->y == output_first && copy->cursor.y == output_first, "v starts copy mode on the block's output");
    check(prompt::surface(client, 1) == prompt::Surface::editor, "copy mode keeps telar's editor");
    application::terminal::copy_mode::leave(client);
    check(client.selectedBlock(1) == std::size_t{1}, "leaving copy mode goes back to the block");

    // Stepping past the last block, or A, goes back to the prompt; A in insert mode.
    control(client, 'd');
    control(client, 'd');
    check(!client.selectedBlock(1), "past the last block is the live prompt");
    control(client, 'u');
    press(client, 'A');
    check(!client.selectedBlock(1) && prompt::line(client, 1)->mode() == prompt::Mode::insert, "A goes back to the prompt to type");

    // Without vim's normal mode, prefix+[ is the way in.
    configuration.prompt.keymap = PromptKeymap::emacs;
    application::configuration::configure(client, configuration);
    check(client.enterBlocks() && client.selectedBlock(1) == std::size_t{2}, "prefix+[ selects the last block");
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});
    check(!client.selectedBlock(1), "Esc goes back to the prompt");
  }

  // The scrollback lineBlockMotions steps through: a hundred rows, with blocks at rows 10, 40
  // (the failed one) and 70.
  constexpr std::uint32_t motions_rows = 100;
  constexpr std::uint32_t motions_live_top = motions_rows - 1;
  constexpr std::uint32_t failed_block_row = 40;
  constexpr std::uint32_t last_block_row = 70;

  template <typename Client>
  void openBlocksAtLiveEnd(Client& client, Transport& transport) {
    constexpr std::uint32_t first_block_row = 10;

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll = {.total_rows = motions_rows, .offset = motions_live_top};
    deliverSingleCell(client, frame);
    deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = 0});
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    configuration.prompt.keymap = PromptKeymap::vim;
    application::configuration::configure(client, configuration);
    deliver(client, atPrompt(3));
    const ds::Array blocks{
        CommandBlock{.row = first_block_row, .rows = 1, .state = CommandBlockState::succeeded, .command = "ls"},
        CommandBlock{.row = failed_block_row, .rows = 1, .state = CommandBlockState::failed, .status = 1, .command = "make"},
        CommandBlock{.row = last_block_row, .rows = 1, .state = CommandBlockState::succeeded, .command = "git log"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
  }

  template <typename Client>
  auto top(const Client& client) {
    return client.findPane(1)->screen.scroll().offset;
  }

  // Selecting, jumping between and scrolling around the blocks.
  template <typename Client>
  void stepsThroughBlocks(Client& client) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});
    control(client, 'u');
    check(client.selectedBlock(1) == std::size_t{2} && top(client) == last_block_row - 1, "Ctrl-U selects the last block above its prompt");
    press(client, '[');
    press(client, 'f');
    check(client.selectedBlock(1) == std::size_t{1} && top(client) == failed_block_row - 1, "[f steps to the failed block");
    control(client, 'o');
    check(top(client) == last_block_row - 1, "Ctrl-O goes back to where the jump left");
    control(client, 'i');
    check(top(client) == failed_block_row - 1, "Ctrl-I comes forward again");
    press(client, 'j');
    check(top(client) == failed_block_row, "j moves the view down a row");
    press(client, 'k');
    check(top(client) == failed_block_row - 1, "k moves it up a row");
    press(client, 'g');
    press(client, 'g');
    check(top(client) == 0 && client.selectedBlock(1) == std::size_t{1}, "gg goes to the top, keeping the block");
    press(client, 'z');
    press(client, 't');
    check(top(client) == failed_block_row, "zt puts the block's separator at the top");
  }

  template <typename Client>
  void foldsBlocks(Client& client) {
    press(client, 'z');
    press(client, 'c');
    check(client.folded({.pane_id = 1, .index = 1}) && client.findPane(1)->folds.hides(failed_block_row + 1) && !client.findPane(1)->folds.hides(last_block_row), "zc folds the block's output");
    press(client, 'z');
    press(client, 'o');
    check(!client.folded({.pane_id = 1, .index = 1}), "zo unfolds it");
    press(client, 'z');
    press(client, 'M');
    check(client.folded({.pane_id = 1, .index = 0}) && client.folded({.pane_id = 1, .index = 1}) && client.folded({.pane_id = 1, .index = 2}), "zM folds every block that is not running");
    press(client, 'z');
    press(client, 'R');
    check(!client.folded({.pane_id = 1, .index = 0}) && !client.folded({.pane_id = 1, .index = 2}), "zR unfolds them all");
  }

  template <typename Client>
  void searchesBlockOutput(Client& client, Transport& transport) {
    constexpr std::uint32_t output_first = failed_block_row + 1;
    constexpr std::uint32_t output_last = last_block_row - 1;

    press(client, '/');
    const auto& copy = application::terminal::copy_mode::view(client).state();

    check(copy && copy->cursor.y == output_first && application::terminal::copy_mode::takeSearchRequest(client) && application::terminal::copy_mode::searchBlock(client) == std::size_t{1}, "/ starts a search of the block's output");
    application::terminal::copy_mode::search(client, "error");
    const auto scoped = transport.last<SearchPaneRows>();

    check(scoped.first_row == output_first && scoped.last_row == output_last, "the search reads only the block's output");
    // Typed a letter at a time: the matches the runtime found, the cursor on the first after
    // where the search began, n and N between them, and back to the start with nothing to find.
    constexpr std::uint32_t first_match_row = 50;
    constexpr std::uint32_t second_match_row = 60;
    const ds::Array found{PaneMatch{.x = 2, .y = first_match_row, .len = 5}, PaneMatch{.x = 0, .y = second_match_row, .len = 5}};

    deliver(client, PaneMatches{.request_id = scoped.request_id, .pane_id = 1, .matches = found});
    check(application::terminal::copy_mode::searchState(client).count == 2 && application::terminal::copy_mode::searchState(client).index == 0 && application::terminal::copy_mode::view(client).state()->cursor.y == first_match_row, "the first match after where the search began is the current one");
    application::terminal::copy_mode::stepMatch(client, true);
    check(application::terminal::copy_mode::searchState(client).index == 1 && application::terminal::copy_mode::view(client).state()->cursor.y == second_match_row, "the next match is a step away");
    application::terminal::copy_mode::search(client, "");
    check(application::terminal::copy_mode::searchState(client).count == 0 && application::terminal::copy_mode::view(client).state()->cursor.y == output_first, "an empty query finds nothing and goes back where the search began");
    application::terminal::copy_mode::toggleSearchScope(client);
    application::terminal::copy_mode::search(client, "error");
    check(!application::terminal::copy_mode::searchBlock(client) && transport.last<SearchPane>().needle == "error", "Tab widens it to the whole scrollback");
    application::terminal::copy_mode::leave(client);
    check(!application::terminal::copy_mode::searchScopes(client), "leaving copy mode forgets the search's command");
  }

  // On a selected block the view moves, folds, jumps and searches the block's output.
  void lineBlockMotions() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openBlocksAtLiveEnd(client, transport);
    stepsThroughBlocks(client);
    foldsBlocks(client);
    searchesBlockOutput(client, transport);

    // A view that draws its own rows says where its top is; the keys move from there.
    constexpr std::uint64_t shown = 20;

    client.findPaneMut(1)->shown_top = shown;
    press(client, 'j');
    check(top(client) == shown + 1, "j moves from the top the view shows, not the runtime's view");
    client.findPaneMut(1)->shown_top.reset();

    press(client, 'G');
    check(!client.selectedBlock(1) && top(client) == motions_live_top, "G goes back to the live end");
  }

  // Ctrl-R and the path search start from the command the line holds, and the path chosen
  // replaces the word it started from.
  void lineSearches() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work"});
    deliver(client, atPrompt());
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    application::configuration::configure(client, configuration);

    typeKeys(client, "cat src/ma");
    check(prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'r', .modifiers = {.control = true}}) == prompt::Outcome::search_history, "Ctrl-R at the prompt searches the history");
    check(prompt::line(client, 1)->text() == "cat src/ma", "opening the search keeps the line");

    check(application::paths::open(client), "the path search opens over the line");
    check(application::paths::seed(client) == "src/ma" && transport.last<FindPaths>().query == "src/ma", "the path search starts from the word before the caret");
    auto request = transport.last<FindPaths>();
    ds::Array matches{PathMatch{.path = "src/main.cpp", .kind = PathKind::file}};

    deliver(client, PathResults{.request_id = request.request_id, .root = request.root, .complete = true, .matches = matches});
    const auto before = transport.sent.size();

    check(application::paths::insert(client, 0, false), "a found path inserts");
    check(transport.inputSince(before).empty() && prompt::line(client, 1)->text() == "cat src/main.cpp", "the path replaces the word in the line");

    typeKeys(client, " ~/x");
    check(application::paths::open(client) && application::paths::seed(client).empty() && transport.last<FindPaths>().query.empty(), "a word that is not a plain relative path starts the search empty");
    request = transport.last<FindPaths>();
    matches.atMut(0) = PathMatch{.path = "a.txt", .kind = PathKind::file};
    deliver(client, PathResults{.request_id = request.request_id, .root = request.root, .complete = true, .matches = matches});
    check(application::paths::insert(client, 0, false) && prompt::line(client, 1)->text() == "cat src/main.cpp ~/xa.txt", "without a word the path goes in at the caret");

    deliver(client, running(1));
    typeKeys(client, "x");
    check(prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = 'r', .modifiers = {.control = true}}) == prompt::Outcome::edited, "Ctrl-R while a command runs stays in the queue");
  }

  const telar::testing::Case case_line_runs_commands{"prompt_session.line_runs_commands", lineRunsCommands};
  const telar::testing::Case case_line_keeps_unsendable_commands{"prompt_session.line_keeps_unsendable_commands", lineKeepsUnsendableCommands};
  const telar::testing::Case case_line_hides_terminal_cursor{"prompt_session.line_hides_terminal_cursor", lineHidesTerminalCursor};
  const telar::testing::Case case_commands_settle_as_typed{"prompt_session.commands_settle_as_typed", commandsSettleAsTyped};
  const telar::testing::Case case_line_searches{"prompt_session.line_searches", lineSearches};
  const telar::testing::Case case_line_bindings{"prompt_session.line_bindings", lineBindings};
  const telar::testing::Case case_line_completes{"prompt_session.line_completes", lineCompletes};
  const telar::testing::Case case_prompt_requests_settle_on_failure{"prompt_session.prompt_requests_settle_on_failure", promptRequestsSettleOnFailure};
  const telar::testing::Case case_pane_removal_forgets_prompt{"prompt_session.pane_removal_forgets_prompt", paneRemovalForgetsPrompt};
  const telar::testing::Case case_prompt_history_stays_bounded{"prompt_session.prompt_history_stays_bounded", promptHistoryStaysBounded};
  const telar::testing::Case case_line_blocks{"prompt_session.line_blocks", lineBlocks};
  const telar::testing::Case case_line_block_motions{"prompt_session.line_block_motions", lineBlockMotions};

}
