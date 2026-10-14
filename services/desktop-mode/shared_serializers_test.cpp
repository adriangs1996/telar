#include "telar_client/telar.hpp"

#include <cassert>
#include <cstdio>
#include <limits>
#include <vector>

namespace {

  std::vector<telar::Byte> fromHex(std::string_view text) {
    std::vector<telar::Byte> result;
    int high = -1;
    for (const auto character : text) {
      if (character == ' ' || character == '\n') {
        continue;
      }
      const auto digit = character >= '0' && character <= '9' ? character - '0' : character - 'a' + 10;
      assert(digit >= 0 && digit <= 15);
      if (high == -1) {
        high = digit;
      } else {
        result.push_back(static_cast<telar::Byte>((high << 4) | digit));
        high = -1;
      }
    }
    assert(high == -1);

    return result;
  }

  template <typename Action> void rejects(Action action) {
    bool rejected = false;
    try {
      action();
    } catch (const telar::EncodingError &) {
      rejected = true;
    }
    assert(rejected);
  }

  std::size_t checked_bodies = 0;

  template <typename Value, typename... Context>
  void check(const Value &value, std::string_view golden = {}, Context... context) {
    std::vector<telar::Byte> bytes(telar::BodyCodec::encodedSize(value, context...));
    assert(telar::BodyCodec::encode(value, bytes, context...).size() == bytes.size());
    if (!golden.empty()) {
      assert(bytes == fromHex(golden));
    }

    alignas(std::max_align_t) std::array<telar::Byte, 32768> scratch{};
    telar::DecodeStorage storage{scratch};
    const auto decoded = telar::BodyCodec::decode<Value>(bytes, storage, context...);
    std::vector<telar::Byte> encoded_again(telar::BodyCodec::encodedSize(decoded, context...));
    telar::BodyCodec::encode(decoded, encoded_again, context...);
    assert(bytes == encoded_again);

    // Every proper prefix is truncated; no decoded views escape this scope.
    for (std::size_t size = 0; size < bytes.size(); ++size) {
      rejects([&] {
        telar::DecodeStorage truncated_storage{scratch};
        (void)telar::BodyCodec::decode<Value>(std::span<const telar::Byte>{bytes}.first(size), truncated_storage, context...);
      });
    }
    bytes.push_back(0);
    rejects([&] {
      telar::DecodeStorage trailing_storage{scratch};
      (void)telar::BodyCodec::decode<Value>(bytes, trailing_storage, context...);
    });
    ++checked_bodies;
  }

  void sharedBodies() {
    using namespace telar;

    check(TerminalSize{80, 24, 8, 16}, "50 00 18 00 08 00 10 00");
    check(PaneTarget{}, "00");
    check(PaneTarget{.kind = PaneTarget::Kind::pane, .id = 42}, "01 2a 00 00 00 00 00 00 00");
    check(PaneTarget{.kind = PaneTarget::Kind::workspace, .id = 42}, "02 2a 00 00 00 00 00 00 00");
    const WorkspaceLocation location{.kind = WorkspaceLocation::Kind::worktree, .id = 7};
    check(location, "01 07 00 00 00 00 00 00 00");
    const TabLocation tab{.workspace = location, .tab_id = 2};
    check(tab, "01 07 00 00 00 00 00 00 00 02 00 00 00 00 00 00 00");
    check(HistoryScopeValue{}, "", HistoryScope::global);
    check(HistoryScopeValue{std::string_view{"/tmp"}}, "04 00 2f 74 6d 70", HistoryScope::cwd);
    check(HistoryScopeValue{std::string_view{"/tmp"}}, "04 00 2f 74 6d 70", HistoryScope::workspace);
    check(HistoryScopeValue{std::uint64_t{42}}, "2a 00 00 00 00 00 00 00", HistoryScope::pane);
    const ClientRoute route{1, 2};
    check(route, "01 00 00 00 00 00 00 00 02 00 00 00 00 00 00 00");
    const CoordinatorReference coordinator{.session_id = {0xab}, .pane_id = 1, .pane_generation = 2};
    check(coordinator);
    check(EnvironmentEntry{"A", "b"}, "01 00 41 01 00 00 00 62");
    const std::array<std::string_view, 1> arguments{"sh"};
    check(Launch{.cwd = "/", .arguments = arguments}, "01 00 2f 00 00 00 00 00 00 00 00 01 00 02 00 73 68 00 00 00");
    const std::array<EnvironmentEntry, 2> environment{{{"TERM", "xterm"}, {"LANG", "C"}}};
    check(Launch{.cwd = "/tmp", .cwd_source = 42, .arguments = arguments,
                 .environment_mode = EnvironmentMode::replace, .environment = environment});
    const PaneForeground foreground{.pane_id = 1, .name = "sh"};
    check(foreground);
    const std::array<PaneForeground, 1> foregrounds{foreground};
    check(TabDescriptor{.tab_id = 2, .position = 0, .pane_count = 1, .label = "test", .foregrounds = foregrounds});
    check(WorkspaceListEntry{.workspace = 7, .name = "test", .path = "/tmp", .tab_count = 1, .branch = "main", .dirty = true});
    check(WorktreeListEntry{.worktree = 1, .source = 7, .path = "/tmp/task", .branch = "task"});
    check(WorktreeListEntry{.worktree = 1, .source = 7, .workspace = 7, .created_by = 1,
                           .path = "/tmp/task", .branch = "task", .coordinator = coordinator,
                           .diff_added = 3, .command_label = "sh", .command_state = CommandState::exited, .command_exit = -1});
    check(HistoryEntry{.id = 1, .pane_id = 2, .started_at_ms = -1, .duration_ns = -2, .exit_code = -3, .command = "ls"},
          "01 00 00 00 00 00 00 00 02 00 00 00 00 00 00 00 "
          "ff ff ff ff ff ff ff ff fe ff ff ff ff ff ff ff "
          "01 fd ff ff ff 00 00 00 00 00 02 00 00 00 6c 73 00 00 00 00 00");
    check(HistoryEntry{.id = 1, .pane_id = 2, .command = "ls"});
    check(AgentSnapshotEntry{.pane_id = 1, .pane_generation = 2, .location = tab, .pane_index = 1,
                             .session_id = {0xab}, .provider = static_cast<AgentProvider>(32),
                             .provider_name = "custom", .display_name = "Custom", .confidence = 100,
                             .sequence = 1, .observed_at_ms = -1, .expires_at_ms = 2,
                             .final_message = "Done\nTested", .plan_done = 1, .plan_total = 1});
    check(ClientDescriptor{1, 2, 3, 1, 4, 5});
    check(ClientCommand{.request_id = 1, .route = route, .action = ClientAction::pane_scroll, .value = -42, .text = "query"});
    check(ClientCommand{.request_id = 1, .route = route, .text = std::string_view{"a\0b", 3}});
    check(ClientLayoutPane{1}, "01 00 00 00 00 00 00 00");
    check(ClientLayoutSplit{ClientLayoutAxis::horizontal, 5000}, "00 88 13");
    check(ClientLayoutNode{ClientLayoutPane{1}}, "00 01 00 00 00 00 00 00 00");
    check(ClientLayoutNode{ClientLayoutSplit{ClientLayoutAxis::horizontal, 5000}}, "01 00 88 13");
    const std::array<ClientLayoutNode, 3> nodes{
        ClientLayoutSplit{ClientLayoutAxis::horizontal, 5000}, ClientLayoutPane{1}, ClientLayoutPane{2},
    };
    check(ClientTabLayout{.location = tab, .focused_pane = 1, .nodes = nodes});
    check(NotificationTarget{}, "00");
    check(NotificationTarget{NotificationTarget::Kind::tab, 2}, "02 02 00 00 00 00 00 00 00");
    check(NotificationBody{.target = {NotificationTarget::Kind::pane, 1}, .title = "Done", .link = "https://example.com/path?q=1"});
    const std::array<std::uint16_t, 1> positions{0};
    check(PathMatch{.path = "a", .positions = positions}, "01 00 61 00 01 00 00");
    const LimitReach reach{.name = "panes.max", .noun = "panes", .value = 7, .requested = 0, .route = "test"};
    check(reach);
    check(LimitReach{.name = "panes.max", .value = 7});
    check(LimitListEntry{.reach = reach, .origin = LimitOrigin::client, .hits = 2, .last_ms = -1});
    check(GraphicsHeader{1, 2});
    const ImageKey key{1, 1};
    check(key);
    check(ImageDescription{key, ImageFormat::rgb, 2, 3, 18},
          "01 00 00 00 01 00 00 00 00 00 00 00 18 02 00 00 00 03 00 00 00 12 00 00 00 00 00 00 00");
    check(GraphicsPlacement{.key = key, .virtual_id = 1, .x = -3, .y = -4, .z_index = -5});
  }

  void malformedBodies() {
    using namespace telar;
    std::array<Byte, 1024> bytes{};
    DecodeStorage storage{};

    rejects([&] { BodyCodec::encode(TerminalSize{}, bytes); });
    rejects([&] { BodyCodec::encode(TerminalSize{65535, 65535, 0, 0}, bytes); });
    rejects([&] { BodyCodec::encode(PaneTarget{PaneTarget::Kind::pane, 0}, bytes); });
    rejects([&] { BodyCodec::encode(PaneTarget{static_cast<PaneTarget::Kind>(3), 1}, bytes); });
    rejects([&] { BodyCodec::encode(ClientRoute{}, bytes); });
    rejects([&] { BodyCodec::encode(CoordinatorReference{.pane_id = 1, .pane_generation = 1}, bytes); });
    rejects([&] { BodyCodec::encode(EnvironmentEntry{"A=B", "x"}, bytes); });
    rejects([&] { BodyCodec::encode(Launch{.cwd = "/"}, bytes); });
    rejects([&] { BodyCodec::encode(HistoryScopeValue{}, bytes, HistoryScope::pane); });
    rejects([&] { BodyCodec::encode(ClientLayoutSplit{ClientLayoutAxis::horizontal, 999}, bytes); });
    rejects([&] { BodyCodec::decode<ClientLayoutNode>(fromHex("02"), storage); });
    rejects([&] { BodyCodec::encode(NotificationBody{.title = "Hello", .link = "https://trusted.example@evil.example"}, bytes); });
    rejects([&] { BodyCodec::encode(NotificationBody{.title = "Hello", .link = "http://example.com"}, bytes); });
    rejects([&] { BodyCodec::encode(LimitReach{.name = "bad name"}, bytes); });
    rejects([&] { BodyCodec::encode(ImageDescription{{1, 1}, ImageFormat::rgb, 2, 3, 17}, bytes); });
    rejects([&] { BodyCodec::encode(ImageDescription{{1, 1}, ImageFormat::rgb, 2, 3, 18}, std::span<Byte>{bytes}.first(28)); });

    const std::array<ClientLayoutNode, 2> incomplete{ClientLayoutSplit{ClientLayoutAxis::horizontal, 5000}, ClientLayoutPane{1}};
    rejects([&] { BodyCodec::encode(ClientTabLayout{.location = {{WorkspaceLocation::Kind::workspace, 1}, 1}, .focused_pane = 1, .nodes = incomplete}, bytes); });
    const std::array<std::uint16_t, 2> duplicate_positions{0, 0};
    rejects([&] { BodyCodec::encode(PathMatch{.path = "ab", .positions = duplicate_positions}, bytes); });
    rejects([&] { BodyCodec::decode<PathMatch>(fromHex("01 00 61 00 41"), storage); });
    rejects([&] { BodyCodec::decode<PathMatch>(fromHex("01 00 61 00 01 00 00"), storage); });
    const std::array<std::string_view, 1> arguments{"sh"};
    const auto launch_bytes = BodyCodec::encode(Launch{.cwd = "/", .arguments = arguments}, bytes);
    rejects([&] { BodyCodec::decode<Launch>(launch_bytes, storage); });
    alignas(std::max_align_t) std::array<Byte, 256> scratch{};
    DecodeStorage borrowed_storage{scratch};
    const auto launch = BodyCodec::decode<Launch>(launch_bytes, borrowed_storage);
    assert(launch.cwd.data() == reinterpret_cast<const char *>(bytes.data() + 2));
    assert(launch.arguments.front().data() == reinterpret_cast<const char *>(bytes.data() + 15));
    const auto address = reinterpret_cast<std::uintptr_t>(launch.arguments.data());
    const auto scratch_begin = reinterpret_cast<std::uintptr_t>(scratch.data());
    assert(address >= scratch_begin && address + sizeof(std::string_view) <= scratch_begin + scratch.size());

    for (const auto invalid : {"c0 80", "ed a0 80", "f4 90 80 80", "f0 80 80 80", "e2 82", "80"}) {
      const auto raw = fromHex(invalid);
      const std::string_view text{reinterpret_cast<const char *>(raw.data()), raw.size()};
      rejects([&] { DisplayText16<96>::encodedSize(text); });
    }
    validateUtf8("Espa\xc3\xb1" "a \xf0\x9f\x98\x80");
    rejects([&] { DisplayText16<96>::encodedSize("line\nbreak"); });
    rejects([&] {
      std::span<const Byte> empty{};
      OptionalValue<u64>::decode(empty, storage);
    });
  }

  void existingMessages() {
    using namespace telar;
    const auto request = Codec::encode(RequestRuntimeState{42, false});
    assert(std::vector<Byte>(request.begin(), request.end()) == fromHex("14 2a 00 00 00 00 00 00 00 00"));
    assert(Codec::decode<RequestRuntimeState>(request).client_identity == 42);
    const auto hello = HandshakeCodec::encode(ClientHello{});
    assert(HandshakeCodec::decode<ClientHello>(hello).schema == handshake::schema_id);

#ifdef TELAR_DEBUG
    auto *output = std::tmpfile();
    assert(output != nullptr);
    Codec::pretty_print(RequestRuntimeState{42, false}, output);
    HandshakeCodec::pretty_print(ClientHello{}, output);
    std::fclose(output);
#endif
  }

} // namespace

int main() {
  sharedBodies();
  malformedBodies();
  existingMessages();
  std::printf("%zu shared-body fixtures passed, including truncation, bounds and message regressions\n", checked_bodies);
}
