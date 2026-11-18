#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.wire.vocabulary;
import telar.cli.worktree_git;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime::cli::sessions;

  bool refused(std::string_view value) {
    try {
      static_cast<void>(coordinatorReference(value));
    } catch (const std::invalid_argument&) {
      return true;
    }

    return false;
  }

  // `--coordinator SESSION:PANE:GENERATION`, written by the telar that dispatches, names the
  // session and pane that hear about the worktree.
  void coordinatorReferenceParses() {
    const auto reference = coordinatorReference("0123456789abcdefFEDCBA9876543210:17:29");
    constexpr std::array<Byte, 16> session{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10};

    check(reference.session_id == session);
    check(reference.pane_id == 17 && reference.pane_generation == 29);

    for (const auto value : {"00000000000000000000000000000000:17:29", "0123456789abcdef0123456789abcdeg:17:29", "0123456789abcdef0123456789abcdef:17", "0123456789abcdef0123456789abcdef"}) {
      check(refused(value), value);
    }
  }

  // Without `--client` the window a person typed in last; with it, that window or none.
  void chooseClientPicksWindow() {
    const std::array clients{
        ClientDescriptor{.id = 1, .last_input_sequence = 5},
        ClientDescriptor{.id = 2, .last_input_sequence = 9},
        ClientDescriptor{.id = 4, .last_input_sequence = 7},
    };

    check(chooseClient(clients, 0).id == 2);
    check(chooseClient(clients, 1).id == 1);
    check(chooseClient(clients, 4).id == 4);

    bool missing = false;

    try {
      static_cast<void>(chooseClient(clients, 3));
    } catch (const std::exception&) {
      missing = true;
    }

    check(missing);
  }

  const telar::testing::Case case_coordinator_reference_parses{"sessions.coordinator_reference_parses", coordinatorReferenceParses};
  const telar::testing::Case case_choose_client{"sessions.choose_client", chooseClientPicksWindow};

}
