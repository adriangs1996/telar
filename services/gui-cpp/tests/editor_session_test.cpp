#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <concepts>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <string_view>
#include <stdexcept>
#include <charconv>
#include <cstring>
#include <system_error>
#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include "../terminal/screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "../terminal/cell_position.hpp"
#include <bit>
#include <tuple>
#include <cmath>
#include "../input/wheel_accumulator.hpp"
#include "telar_base/memory/allocator.hpp"
#include <memory>
#include "assertions.hpp"
#include "session_fixture.hpp"
#include <cstdio>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.application.sound_playback;
import telar.gui.application.session;
import telar.gui.links.cell_links;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

struct Environment {
  [[nodiscard]] std::optional<std::string_view> operator()(std::string_view name) const noexcept {
    return name == "HOME" ? std::optional{std::string_view{"/home/reader"}} : std::nullopt;
  }
};

FilePath filePath(std::string_view text, bool prose = false) {
  const auto target = prose ? LinkTarget::fromPath(text) : LinkTarget::fromUri(text);
  if (!target) {
    throw std::runtime_error{"Editor fixture must be a valid link target"};
  }

  return FilePath::parse(*target);
}

struct Fixture {
  Fixture()
      : memory(system, allocation_budget),
        client(memory, transport) {
    openFirstPane(client, transport);
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work/project"});
  }

  void open(std::string_view target = "file:/tmp/a%20b.cpp#L12C3", bool prose = false) {
    client.openFile(filePath(target, prose), "nvim", environment, 1);
  }

  static constexpr std::size_t allocation_budget = std::size_t{16} * 1024 * 1024;
  SystemAllocator system;
  BudgetAllocator<SystemAllocator> memory;
  Transport transport;
  Session<BudgetAllocator<SystemAllocator>, Transport> client;
  Environment environment;
};

void reuseAndFallback() {
  Fixture fixture;
  auto &client = fixture.client;
  const auto &transport = fixture.transport;
  client.split(ClientLayoutAxis::vertical);
  const auto split = transport.last<CreatePane>();
  constexpr std::uint64_t editor_generation = 7;
  deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = editor_generation});
  client.focusPane(1);
  fixture.open("../src/a.cpp:12:3", true);
  const auto request = transport.last<OpenEditor>();
  constexpr std::uint32_t line = 12;
  constexpr std::uint32_t column = 3;
  require(request.pane_id == 1 && request.pane_generation == 1 && request.editor == "nvim" && request.path == "/work/src/a.cpp" && request.line == line && request.column == column, "file requests must anchor at their source pane and preserve its runtime identity");
  require(deliver(client, EditorOpened{.request_id = request.request_id + 1, .outcome = EditorOutcome::unavailable}) == Change::none, "an unrelated reply must leave the current editor operation pending");
  bool busy = false;
  try {
    fixture.open();
  } catch (const std::runtime_error &error) {
    busy = std::string_view{error.what()} == "EditorOpenBusy";
  }

  require(busy, "concurrent file clicks must report busy without replacing the retained target");
  require(deliver(client, EditorOpened{.request_id = request.request_id, .outcome = EditorOutcome::opened, .pane_id = 2, .pane_generation = editor_generation}) == Change::model && client.focusedPane()->id == 2, "a matching editor reply must focus the reused pane");
  const auto count = transport.count(ClientTag::create_pane);
  deliver(client, EditorOpened{.request_id = request.request_id, .outcome = EditorOutcome::unavailable});
  require(transport.count(ClientTag::create_pane) == count, "a duplicate reply must not spawn an editor");

  client.focusPane(1);
  fixture.open("../src/pinned.cpp:12:3", true);
  const auto fallback_id = transport.last<OpenEditor>().request_id;
  deliver(client, PaneCwd{.pane_id = 1, .cwd = "/changed/after/click"});
  require(deliver(client, EditorOpened{.request_id = fallback_id, .outcome = EditorOutcome::unavailable}) == Change::model, "unavailable editor reuse must fall back to a split");
  const auto fallback = transport.last<CreatePane>();
  require(fallback.launch.cwd_source == 1 && fallback.launch.arguments.size() == 3 && fallback.launch.arguments[0] == "nvim" && fallback.launch.arguments[1] == "+call cursor(12, 3)" && fallback.launch.arguments[2] == "/work/src/pinned.cpp", "fallback must use the retained literal path and the source pane's directory");
  deliver(client, PaneOpened{.request_id = fallback.request_id, .pane_id = 3, .location = fallback.location, .created = true, .pane_generation = 1});
  require(client.focusedPane()->id == 3 && client.activeTab()->layout.contains(1), "the new editor must become a focused sibling of its source");
}

void failureRecovery() {
  Fixture fixture;
  auto &transport = fixture.transport;
  for (const auto outcome : {EditorOutcome::failed, EditorOutcome::missing}) {
    fixture.open();
    const auto request_id = transport.last<OpenEditor>().request_id;
    require(deliver(fixture.client, EditorOpened{.request_id = request_id, .outcome = outcome}) == Change::notification, "failed and missing replies must publish link feedback");
    require(fixture.client.notice() == (outcome == EditorOutcome::missing ? "Could not open link: FileNotFound" : "Could not open link: EditorOpenFailed"), "failure feedback must retain the runtime outcome");
  }

  fixture.open();
  const auto failed_id = transport.last<OpenEditor>().request_id;
  require(deliver(fixture.client, RequestFailed{.request_id = failed_id, .code = FailureCode::resource_limit, .message = "editor busy"}) == Change::notification, "a failed runtime request must release editor ownership");
  transport.reject_editor = true;
  bool rejected = false;
  try {
    fixture.open();
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected, "the injected transport must reject the editor request");
  transport.reject_editor = false;
  fixture.open();
  const auto retry_id = transport.last<OpenEditor>().request_id;
  transport.reject_create_pane = true;
  require(deliver(fixture.client, EditorOpened{.request_id = retry_id, .outcome = EditorOutcome::unavailable}) == Change::notification, "a failed fallback send must publish feedback and release request storage");
  transport.reject_create_pane = false;
  fixture.open();
  const auto recovered_id = transport.last<OpenEditor>().request_id;
  require(recovered_id > retry_id, "transport failures must permit a fresh correlated editor request");
}

void staleSourceReplies() {
  enum class Mutation : std::uint8_t {
    generation,
    attachment,
    location,
    removed,
    disconnect,
  };
  for (const auto mutation : {Mutation::generation, Mutation::attachment, Mutation::location, Mutation::removed, Mutation::disconnect}) {
    Fixture fixture;
    fixture.open();
    const auto request_id = fixture.transport.last<OpenEditor>().request_id;
    auto *pane = fixture.client.findPane(1);
    switch (mutation) {
    case Mutation::generation:
      ++pane->generation;
      break;
    case Mutation::attachment:
      ++pane->attachment_generation;
      break;
    case Mutation::location:
      ++pane->location.tab_id;
      break;
    case Mutation::removed:
      deliver(fixture.client, PaneExited{.pane_id = 1});
      break;
    case Mutation::disconnect:
      fixture.client.disconnected();
      break;
    }

    const auto count = fixture.transport.count(ClientTag::create_pane);
    require(deliver(fixture.client, EditorOpened{.request_id = request_id, .outcome = EditorOutcome::unavailable}) == Change::none && fixture.transport.count(ClientTag::create_pane) == count, "a stale source identity must never launch a fallback editor");
  }
}

void restoredAttachmentRejectsOldReply() {
  Fixture fixture;
  fixture.open();
  const auto request_id = fixture.transport.last<OpenEditor>().request_id;
  const auto location = fixture.client.activeTab()->location;
  const auto generation = fixture.client.findPane(1)->attachment_generation;
  fixture.client.createTab();
  const auto created = fixture.transport.last<CreateTab>();
  deliver(fixture.client, TabCreated{.request_id = created.request_id, .location = {.workspace = location.workspace, .tab_id = 2}, .position = 1, .root_pane_id = 2, .pane_generation = 1});
  fixture.client.selectTab(location);
  const auto attach = fixture.transport.last<OpenPane>();
  deliver(fixture.client, PaneOpened{.request_id = attach.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
  require(fixture.client.findPane(1)->attachment_generation > generation, "restoring a pane must allocate a new attachment generation");
  require(deliver(fixture.client, EditorOpened{.request_id = request_id, .outcome = EditorOutcome::unavailable}) == Change::none, "restoring the same tab must not revive an old file click");
  fixture.open();
  const auto current_id = fixture.transport.last<OpenEditor>().request_id;
  deliver(fixture.client, EditorOpened{.request_id = request_id, .outcome = EditorOutcome::missing});
  require(deliver(fixture.client, EditorOpened{.request_id = current_id, .outcome = EditorOutcome::missing}) == Change::notification, "a delayed old reply must leave a newer request intact");
}

void duplicateAttachmentPreservesPendingEditor() {
  Fixture fixture;
  fixture.client.split(ClientLayoutAxis::horizontal);
  const auto split = fixture.transport.last<CreatePane>();
  const std::array<PaneDescriptor, 2> panes{{{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, {.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = 1}}};
  deliver(fixture.client, TabSnapshot{.request_id = 1, .location = split.location, .panes = panes});
  const auto attach = fixture.transport.last<OpenPane>();
  deliver(fixture.client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
  const auto generation = fixture.client.findPane(2)->attachment_generation;
  fixture.client.openFile(filePath("file:/tmp/a.cpp"), "nvim", fixture.environment, 2);
  const auto request_id = fixture.transport.last<OpenEditor>().request_id;
  deliver(fixture.client, PaneOpened{.request_id = attach.request_id, .pane_id = 2, .location = split.location, .pane_generation = 1});
  require(fixture.client.findPane(2)->attachment_generation == generation, "a duplicate attachment confirmation must preserve the already attached view's identity");
  require(deliver(fixture.client, EditorOpened{.request_id = request_id, .outcome = EditorOutcome::missing}) == Change::notification, "a duplicate attachment must not invalidate an otherwise matching editor reply");
}

void directLaunches() {
  Fixture fixture;
  fixture.client.findPane(1)->generation = 0;
  fixture.open("~/src/a.cpp:12", true);
  require(fixture.transport.count(ClientTag::open_editor) == 0, "a source without a runtime generation must launch directly");
  const auto split = fixture.transport.last<CreatePane>();
  require(split.launch.arguments[2] == "/home/reader/src/a.cpp", "direct splits must still expand home paths");
  fixture.client.openFile(filePath("file:/tmp/new.cpp"), "code", fixture.environment);
  const auto tab = fixture.transport.last<CreateTab>();
  require(tab.launch.arguments.size() == 2 && tab.launch.arguments[0] == "code" && tab.launch.arguments[1] == "/tmp/new.cpp", "a sourceless absolute file must open in a new tab");
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  client.openFile(filePath("file:/tmp/first.cpp"), "nvim", fixture.environment);
  const auto opened = transport.last<OpenPane>();
  require(opened.launch && opened.launch->arguments[0] == "nvim" && opened.launch->arguments[1] == "/tmp/first.cpp", "an empty client must open its first tab with editor arguments");
}

void targetAndCapacityGuards() {
  Fixture fixture;
  fixture.open();
  const auto request_id = fixture.transport.last<OpenEditor>().request_id;
  require(deliver(fixture.client, EditorOpened{.request_id = request_id, .outcome = EditorOutcome::opened, .pane_id = 1, .pane_generation = 2}) == Change::none, "an editor reply must not focus a mismatched runtime generation");

  auto geometry = fixture.client.workbenchGeometry();
  const auto minimum_extent = geometry.layout_metrics.minimumPaneExtent();
  const auto required_columns = (PaneLayout::maximum_panes * (minimum_extent + geometry.layout_metrics.gap)) - geometry.layout_metrics.gap;
  geometry.area.width = static_cast<float>(static_cast<double>(required_columns * geometry.grid.cell_width_px) / geometry.grid.scale);
  fixture.client.setWorkbenchGeometry(geometry);

  std::uint64_t next_pane_id = 2;
  for (std::uint64_t level_size = 1; level_size < PaneLayout::maximum_panes; level_size *= 2) {
    for (std::uint64_t target = 1; target <= level_size; ++target) {
      fixture.client.focusPane(target);
      const auto requests = fixture.transport.count(ClientTag::create_pane);
      fixture.client.split(ClientLayoutAxis::horizontal);
      require(fixture.transport.count(ClientTag::create_pane) == requests + 1, "the capacity fixture must have enough physical space for each requested split");
      const auto split = fixture.transport.last<CreatePane>();
      deliver(fixture.client, PaneOpened{.request_id = split.request_id, .pane_id = next_pane_id++, .location = split.location, .created = true, .pane_generation = 1});
    }
  }

  require(fixture.client.activeTab()->layout.nodes().size() == PaneLayout::maximum_nodes, "the capacity fixture must fill a spatially valid balanced tab");

  fixture.client.focusPane(1);
  fixture.open();
  const auto full_request = fixture.transport.last<OpenEditor>().request_id;
  const auto count = fixture.transport.count(ClientTag::create_pane);
  require(deliver(fixture.client, EditorOpened{.request_id = full_request, .outcome = EditorOutcome::unavailable}) == Change::notification && fixture.client.notice() == "Could not open link: PaneSplitUnavailable", "a full tab must report its unavailable split without creating a pane");
  require(fixture.transport.count(ClientTag::create_pane) == count, "capacity rejection must preserve runtime process ownership");
  bool rejected = false;
  try {
    fixture.client.openFile(filePath("relative.cpp", true), "nvim", fixture.environment);
  } catch (const std::invalid_argument &error) {
    rejected = std::string_view{error.what()} == "RelativeFileLink";
  }

  require(rejected, "a sourceless relative path must not guess a working directory");
}

}

int main() {
  try {
    reuseAndFallback();
    failureRecovery();
    staleSourceReplies();
    restoredAttachmentRejectsOldReply();
    duplicateAttachmentPreservesPendingEditor();
    directLaunches();
    targetAndCapacityGuards();
    std::puts("gui-editor-session: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-editor-session: " << error.what() << '\n';

    return 1;
  }
}
