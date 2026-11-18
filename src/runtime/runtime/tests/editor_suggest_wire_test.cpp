import std;
import telar.testing;
import telar.runtime.runtime.tests.protocol_peer;
import telar.runtime.runtime.tests.runtime_host;
import telar.runtime.runtime.tests.wire_session;
import telar.wire.editor;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr std::array<std::string_view, 1> cat{"/bin/cat"};

  void testSuggestUnavailableAndUnknownPane() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});

    // No engine is configured: the window shows that, rather than waiting.
    check(control.exchange<CommandSuggestion>(SuggestCommand{.request_id = 2, .pane_id = opened.pane_id, .text = "list files"}).status == SuggestionStatus::unavailable);

    RuntimeHost engine_host{RuntimeHostOptions{.suggestion_engine = "/bin/cat"}};
    ProtocolPeer engine_control{engine_host.socket()};

    check(engine_control.exchange<CommandSuggestion>(SuggestCommand{.request_id = 3, .pane_id = 9999, .text = "list files"}).status == SuggestionStatus::failed);
  }

  void testSuggestPromptCarriesPaneContext() {
    RuntimeHost host_for_paths;
    const auto directory = host_for_paths.directory();
    const auto prompt = directory + "/prompt";
    const auto engine = directory + "/engine.sh";

    // An engine that keeps what it is asked and answers one command.
    std::ofstream{engine} << "while IFS= read -r line; do printf '%s\\n' \"$line\" >> '" << prompt << "'; case \"$line\" in *get_last_assistant_text*) printf '%s\\n' '{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"ls\"}}';; *) printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}' '{\"type\":\"agent_settled\"}';; esac; done\n";
    RuntimeHost host{RuntimeHostOptions{.suggestion_engine = engine}};
    ProtocolPeer control{host.socket()};
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "echo screen-marker; exec cat"};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = directory, .arguments = arguments}});

    screenShowing(control, opened.pane_id, "screen-marker");
    const auto suggestion = control.exchange<CommandSuggestion>(SuggestCommand{.request_id = 2, .pane_id = opened.pane_id, .text = "list the files here"});

    check(suggestion.status == SuggestionStatus::ready && suggestion.text == "ls");
    const auto asked = readFile(prompt);
    const auto name = directory.substr(directory.rfind('/') + 1);

    check(asked.contains(name), "the engine was not told the pane's directory");
    check(asked.contains("screen-marker"), "the engine was not shown the pane's screen");
    check(asked.contains("list the files here"), "the engine was not given the request");
  }

  void testOpenEditorRefusals() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto file = host.directory() + "/file.txt";

    std::ofstream{file} << "text\n";
    const auto open = [&](std::uint64_t request, std::uint64_t pane, std::uint64_t generation) -> ds::Option<FailureCode> {
      try {
        control.exchange<EditorOpened>(OpenEditor{.request_id = request, .pane_id = pane, .pane_generation = generation, .editor = "nvim", .path = file, .line = 1, .column = 1});
        return ds::none;
      } catch (const ProtocolFailure& failure) {
        return failure.code;
      }
    };

    check(open(1, 9999, 1) == FailureCode::pane_not_found);
    const std::array<std::string_view, 1> exiting{"/usr/bin/true"};
    const auto exited = control.exchange<PaneOpened>(OpenPane{.request_id = 2, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = exiting}});

    waitExited(control, exited.pane_id);
    const auto late = open(3, exited.pane_id, exited.pane_generation);

    check(late == FailureCode::pane_exited || late == FailureCode::pane_not_found, "an exited pane asked for an editor");
  }

  const telar::testing::Case case_suggest_unavailable_and_unknown_pane{"editor_suggest_wire.suggest_unavailable_and_unknown_pane", testSuggestUnavailableAndUnknownPane};
  const telar::testing::Case case_suggest_prompt_carries_pane_context{"editor_suggest_wire.suggest_prompt_carries_pane_context", testSuggestPromptCarriesPaneContext};
  const telar::testing::Case case_open_editor_refusals{"editor_suggest_wire.open_editor_refusals", testOpenEditorRefusals};

}
