import std;
import telar.testing;
import telar.runtime.persistence.session_store;
import telar.wire.vocabulary;
import telar.wire.worktrees;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Encodes a checkpoint by hand, as a given release of telar wrote it.
  class Encoder {
  public:
    explicit Encoder(std::uint16_t version)
        : version_(version) {
      raw(checkpoint::magic);
      integer(version);
      for (int counter = 0; counter < 4; ++counter) {
        integer(std::uint64_t{100});
      }
    }

    template <std::unsigned_integral Integer>
    Encoder& integer(Integer value) {
      for (std::size_t index = 0; index < sizeof(value); ++index) {
        bytes_.push_back(static_cast<Byte>(value >> (8 * index)));
      }

      return *this;
    }

    Encoder& raw(std::string_view text) {
      bytes_.insert(bytes_.end(), text.begin(), text.end());
      return *this;
    }

    Encoder& text16(std::string_view text) {
      integer(static_cast<std::uint16_t>(text.size()));
      return raw(text);
    }

    Encoder& kind(checkpoint::Kind kind) {
      return integer(static_cast<Byte>(kind));
    }

    Encoder& workspace(std::uint64_t id, std::string_view label) {
      kind(checkpoint::Kind::workspace).integer(id).text16("/tmp").text16("Workspace").integer(std::uint64_t{7}).text16(label);
      return *this;
    }

    // A pane as `version` wrote it: arguments in a 16-bit length before version 9, no title
    // before 2, the dropped flag of version 4 and the in-pane flag from version 8.
    Encoder& pane(std::uint64_t id, std::uint16_t count, std::string_view arguments, bool dropped = false) {
      kind(checkpoint::Kind::pane).integer(id).integer(std::uint64_t{1}).integer(std::uint64_t{7}).text16("/tmp");
      integer(std::uint16_t{80}).integer(std::uint16_t{24}).integer(count);
      if (version_ >= 9) {
        integer(static_cast<std::uint32_t>(arguments.size())).raw(arguments);
      } else {
        text16(arguments);
      }

      integer(static_cast<Byte>(AgentProvider::claude)).text16("session-1");
      if (version_ >= 2) {
        text16("Title").integer(static_cast<Byte>(AgentTitleSource::manual));
      }

      if (version_ >= 8) {
        integer(Byte{1});
      }

      if (version_ == 4) {
        integer(Byte{dropped});
      }

      return *this;
    }

    Encoder& worktree(std::uint64_t id) {
      kind(checkpoint::Kind::worktree).integer(id).integer(std::uint64_t{2}).integer(std::uint64_t{1}).integer(std::uint64_t{0});
      integer(static_cast<Byte>(WorktreeOrigin::telar)).text16("/tmp/worktree").text16("feature").text16("main").text16("Title").text16("Brief");
      if (version_ >= 7) {
        text16("dispatcher");
      }

      if (version_ >= 10) {
        integer(Byte{0});
      }

      return *this;
    }

    std::span<const Byte> finish() {
      bytes_.push_back(static_cast<Byte>(checkpoint::Kind::end));
      return bytes_;
    }

  private:
    std::uint16_t version_;
    std::vector<Byte> bytes_;
  };

  constexpr std::string_view cat{"/bin/cat\0", 9};

  struct Decoded {
    std::vector<checkpoint::WorkspaceRecord> workspaces;
    std::vector<checkpoint::PaneRecord> panes;
    std::vector<checkpoint::WorktreeRecord> worktrees;
  };

  Decoded decode(std::span<const Byte> bytes) {
    Decoded decoded;
    checkpoint::Reader reader{bytes};

    reader.read([&]<typename Record>(const Record& record) {
      if constexpr (std::same_as<Record, checkpoint::WorkspaceRecord>) {
        decoded.workspaces.push_back(record);
      } else if constexpr (std::same_as<Record, checkpoint::PaneRecord>) {
        decoded.panes.push_back(record);
      } else if constexpr (std::same_as<Record, checkpoint::WorktreeRecord>) {
        decoded.worktrees.push_back(record);
      }
    });

    return decoded;
  }

  bool rejected(std::span<const Byte> bytes) {
    try {
      decode(bytes);
    } catch (const EncodingError&) {
      return true;
    }

    return false;
  }

  void testWorktreeRoundTrip() {
    std::array<Byte, 4096> buffer;
    checkpoint::Writer writer{buffer, checkpoint::Counters{}};
    CoordinatorReference coordinator{.pane_id = 3, .pane_generation = 4};

    coordinator.session_id.fill(9);
    writer.append(checkpoint::WorktreeRecord{12, 5, RegisterWorktree{.source = 2, .created_by = 1, .origin = WorktreeOrigin::external, .path = "/tmp/worktree", .branch = "feature", .base = "main", .title = "A title", .brief = "A brief", .dispatched_from = "dispatcher", .coordinator = coordinator}});
    // A record after the worktree reads back only when the worktree's fields all did.
    writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "After", 6, "Shell"});
    const auto decoded = decode(writer.finish());

    check(decoded.worktrees.size() == 1 && decoded.workspaces.size() == 1 && decoded.workspaces.front().name == "After");
    const auto& record = decoded.worktrees.front();
    const auto& registration = record.registration;

    check(record.id == 12 && record.workspace == 5);
    check(registration.source == 2 && registration.created_by == 1 && registration.origin == WorktreeOrigin::external);
    check(registration.path == "/tmp/worktree" && registration.branch == "feature" && registration.base == "main");
    check(registration.title == "A title" && registration.brief == "A brief" && registration.dispatched_from == "dispatcher");
    check(registration.coordinator && registration.coordinator->session_id == coordinator.session_id);
    check(registration.coordinator->pane_id == 3 && registration.coordinator->pane_generation == 4);
  }

  void testOlderVersionsDecode() {
    for (const std::uint16_t version : {1, 3, 4, 7, 8}) {
      Encoder encoder{version};

      encoder.workspace(1, "Shell").pane(2, 1, cat);
      if (version == 4) {
        // Version 4 marked panes it had dropped; they are not restored.
        encoder.pane(3, 1, cat, true);
      }

      encoder.worktree(4);
      const auto decoded = decode(encoder.finish());

      check(decoded.workspaces.size() == 1 && decoded.workspaces.front().first_label == "Shell");
      check(decoded.panes.size() == 1, "a dropped pane was restored");
      const auto& pane = decoded.panes.front();

      check(pane.id == 2 && pane.cwd == "/tmp" && pane.argument_count == 1 && pane.arguments == cat);
      check(pane.provider == AgentProvider::claude && pane.session == "session-1");
      check(pane.title == (version >= 2 ? "Title" : ""));
      check(pane.in_pane == (version >= 8));
      check(decoded.worktrees.size() == 1 && decoded.worktrees.front().registration.branch == "feature");
      check(decoded.worktrees.front().registration.dispatched_from == (version >= 7 ? "dispatcher" : ""));
    }
  }

  std::vector<Byte> panes(std::uint64_t count) {
    std::vector<Byte> buffer(1024 * 1024);
    checkpoint::Writer writer{buffer, checkpoint::Counters{}};

    writer.append(checkpoint::WorkspaceRecord{1, "/tmp", "Panes", 7, "Shell"});
    for (std::uint64_t id = 1; id <= count; ++id) {
      writer.append(checkpoint::PaneRecord{id, 1, 7, "/tmp", 80, 24, 1, cat});
    }

    const auto bytes = writer.finish();

    return {bytes.begin(), bytes.end()};
  }

  void testPaneCap() {
    // A restore holds the panes a runtime can run, 256; a checkpoint with more is refused whole.
    check(decode(panes(256)).panes.size() == 256);
    check(rejected(panes(257)), "a checkpoint with more panes than a runtime holds was read");
  }

  void testMalformedPanesRejected() {
    const std::string many_arguments(65, '\0');

    const struct {
      std::string_view name;
      std::uint16_t count;
      std::string_view arguments;
    } panes[] = {
        {"more than 64 arguments", 65, many_arguments},
        {"separators that do not match the count", 2, cat},
        {"no arguments", 0, {}},
    };

    for (const auto& malformed : panes) {
      Encoder encoder{checkpoint::current_version};

      encoder.workspace(1, "Shell").pane(2, malformed.count, malformed.arguments);
      check(rejected(encoder.finish()), malformed.name);
    }

    Encoder unknown{checkpoint::current_version};

    unknown.workspace(1, "Shell").integer(Byte{9});
    check(rejected(unknown.finish()), "an unknown record kind");
  }

  const telar::testing::Case case_worktree_round_trip{"checkpoint_format.worktree_round_trip", testWorktreeRoundTrip};
  const telar::testing::Case case_older_versions_decode{"checkpoint_format.older_versions_decode", testOlderVersionsDecode};
  const telar::testing::Case case_pane_cap{"checkpoint_format.pane_cap", testPaneCap};
  const telar::testing::Case case_malformed_panes_rejected{"checkpoint_format.malformed_panes_rejected", testMalformedPanesRejected};

}
