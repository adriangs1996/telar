#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.client;
import telar.vocabulary;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  // What one representative message of each family encodes to under a schema id, as an FNV-1a
  // hash of its bytes.
  struct Layout {
    std::string_view message;
    std::uint64_t hash;
  };

  struct SchemaLayouts {
    SchemaId schema;
    ds::Array<Layout, 6> layouts;
  };

  // A client and a runtime of other versions, over SSH among others, trust each other's layouts
  // only through handshake::schema_id. A change to any of these layouts needs a new schema id and
  // its row here; a row is never edited.
  constexpr ds::Array known_schemas{
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '0', '4'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '0', '5'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '0', '6'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      // Adds QueryHistoryWorkspaces and HistoryWorkspaces; the layouts of the others are unchanged.
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '0', '7'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      // Changes the monitor's QueryMonitor and MonitorSnapshot; the layouts of the others are unchanged.
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '0', '8'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      // Adds the editor pane's messages and the failure for a pane of another kind; the layouts
      // of the others are unchanged.
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '0', '9'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '1', '0'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      // Adds the explorer's file messages; the layouts of the others are unchanged.
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '1', '1'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
      // Changes NvimPreview, which marks what the query matched; the layouts of the others are
      // unchanged.
      SchemaLayouts{
          .schema = {'c', 'q', 'p', '0', '0', '0', '1', '2'},
          .layouts = {{
              {"RequestRuntimeState", 0x24faea53dd5382bf},
              {"OpenPane", 0x54bf92fa37104bc7},
              {"PaneFrame", 0x51181939628bf754},
              {"ClientCommand", 0xa4f02dedcea9f648},
              {"RequestFailed", 0x7369409b7caafd98},
              {"AgentSnapshot", 0x0d98295029aede63},
          }},
      },
  };

  std::uint64_t fnv1a(std::span<const Byte> bytes) {
    std::uint64_t hash = 0xcbf29ce484222325;

    for (const auto byte : bytes) {
      hash = (hash ^ byte) * 0x100000001b3;
    }

    return hash;
  }

  template <typename Message>
  std::uint64_t layoutHash(const Message& message) {
    std::vector<Byte> bytes(Codec::encodedSize(message));

    return fnv1a(Codec::encode(message, std::span<Byte>{bytes}));
  }

  // One canonical instance of each family, with every kind of field it has set.
  ds::Array<std::uint64_t, 6> canonicalHashes() {
    const ds::Array<std::string_view, 3> arguments{"sh", "-c", "echo hi"};
    const ds::Array<EnvironmentEntry, 1> environment{{{"PATH", "/bin"}}};
    ds::Array<Cell, 4> grid;
    const ds::Array<Byte, 1> letter{'a'};

    for (auto& cell : grid.viewMut()) {
      cell.text = letter;
    }

    std::vector<Byte> cells(CellRunCodec::encodedSize(grid));

    static_cast<void>(CellRunCodec::encode(grid, std::span<Byte>{cells}));
    const ds::Array<FrameSpan, 1> spans{{{.start = 0, .count = 4, .cells = cells}}};
    const ds::Array<Byte, 1> row_flags{static_cast<Byte>(RowFlag::hyperlinks)};
    const ds::Array<MetadataLink, 1> links{{{.offset = 0, .len = 5}}};
    const ds::Array<MetadataRun, 1> runs{{{.start = 1, .len = 2, .link_index = 0}}};
    const ds::Array<Byte, 5> uris{'h', 't', 't', 'p', 's'};
    PaneFrame frame{};

    frame.pane_id = 3;
    frame.frame_id = 9;
    frame.cols = 4;
    frame.rows = 1;
    frame.cursor = {.visible = true, .x = 2, .y = 0, .shape = CursorShape::bar};
    frame.scroll = {.total_rows = 10, .offset = 2};
    frame.text_metadata = TextMetadata{.status = MetadataStatus::complete, .row_flags = row_flags, .links = links, .runs = runs, .uris = uris};
    frame.spans = spans;

    const ds::Array entries{AgentSnapshotEntry{
        .pane_id = 3,
        .pane_generation = 2,
        .location = {.workspace = {.id = 1}, .tab_id = 4},
        .pane_index = 1,
        .process_id = 42,
        .workspace_label = "work",
        .status = AgentStatus::working,
        .sequence = 5,
    }};

    return {
        layoutHash(RequestRuntimeState{.client_identity = 7, .interactive = true}),
        layoutHash(OpenPane{
            .request_id = 1,
            .size = {.cols = 80, .rows = 24, .cell_width_px = 8, .cell_height_px = 16},
            .launch = Launch{.cwd = "/tmp", .cwd_source = 2, .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment},
        }),
        layoutHash(frame),
        layoutHash(ClientCommand{.request_id = 1, .route = {.id = 2, .generation = 3}, .action = ClientAction::tab_select, .target_id = 4, .value = -5, .text = "text"}),
        layoutHash(RequestFailed{.request_id = 1, .code = FailureCode::invalid_request, .message = "refused"}),
        layoutHash(AgentSnapshot{.revision = 6, .entries = entries}),
    };
  }

  void testLayoutsMatchSchemaId() {
    const auto row = std::ranges::find(known_schemas, handshake::schema_id, &SchemaLayouts::schema);

    check(row != known_schemas.end(), "handshake::schema_id has no row of layouts: add one");
    const auto hashes = canonicalHashes();

    for (std::size_t index = 0; index < hashes.size(); ++index) {
      const auto& layout = row->layouts[index];
      const auto what = std::format("{} encodes to {:#x}, not the {:#x} of its schema id: a layout change needs a new handshake::schema_id", layout.message, hashes[index], layout.hash);

      telar::testing::expect(hashes[index] == layout.hash, what);
    }
  }

  const telar::testing::Case case_layouts{"wire_schema.layouts_match_schema_id", testLayoutsMatchSchemaId};

}
