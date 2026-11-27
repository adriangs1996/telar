import std;
import telar.testing;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.wire.editor;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};

  // The shell's own completion is asked of a pane's integrated shell: a pane whose program is no
  // shell telar integrates answers it at once, with no words, and a pane that is not there fails.
  void testAPaneWithoutAnIntegratedShellHasNoShellWords() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    constexpr ds::Array<std::string_view, 1> cat{"/bin/cat"};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = host.directory(), .arguments = cat}});
    const auto words = control.exchange<CompletionWords>(CompleteWords{.request_id = 2, .pane_id = opened.pane_id, .provider = CompletionProvider::shell, .prefix = "kubectl get po"});

    check(words.request_id == 2 && words.words.empty() && !words.truncated, "a pane without an integrated shell completes nothing of its shell");

    try {
      static_cast<void>(control.exchange<CompletionWords>(CompleteWords{.request_id = 3, .pane_id = 9999, .provider = CompletionProvider::shell, .prefix = "ls a"}));
      check(false, "a pane that is not there completes nothing");
    } catch (const ProtocolFailure& failure) {
      check(failure.code == FailureCode::pane_not_found);
    }
  }

  const telar::testing::Case case_no_shell{"shell_words_wire.a_pane_without_an_integrated_shell_has_no_shell_words", testAPaneWithoutAnIntegratedShellHasNoShellWords};

}
