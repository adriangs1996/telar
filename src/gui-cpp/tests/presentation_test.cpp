#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cmath>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cstdio>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.core.metrics;
import telar.gui.graphics.pauses;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.presentation.history_inspection;
import telar.gui.presentation.frame_pacer;
import telar.gui.presentation.application_mark;
import telar.gui.presentation.notification_stack;

namespace {

using telar::gui::WindowTitle;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

WindowTitle paneTitle(std::string_view text) {
  return WindowTitle::render("{pane_title}", {.workspace = {}, .tab = {}, .pane_title = text, .hostname = {}});
}

void titleTokens() {
  constexpr WindowTitle::Tokens tokens{.workspace = "project", .tab = "build", .pane_title = "compiler", .hostname = "host"};
  const auto expanded = WindowTitle::render("{hostname}/{workspace}/{tab}: {pane_title}", tokens);
  require(expanded.view() == "host/project/build: compiler", "all configured title tokens must expand");
  require(WindowTitle::render("{unknown} {{tab}} {unfinished", tokens).view() == "{unknown} {build} {unfinished", "unknown tokens and unmatched braces must remain literal");
  require(WindowTitle::render("{tab}/{pane_title}", {}).view() == "/", "missing values must expand to empty text");
}

void titleSanitization() {
  const auto controls = paneTitle("a\n\t\x7f\xc2\x80\xc2\x9f"
                                  "b中");
  require(controls.view() == "ab中", "title delivery must remove ASCII and C1 controls while preserving UTF-8");
  require(paneTitle("kept\xfflost").view() == "kept", "invalid UTF-8 must end the delivered title");
  require(paneTitle("kept\xe4\xb8").view() == "kept", "incomplete Unicode scalars must not reach the host");
}

void titleBoundsAndSuffix() {
  const std::string prefix(WindowTitle::capacity - 1, 'a');
  const auto clipped = paneTitle(prefix + "中");
  require(clipped.view() == prefix, "bounded titles must end at a complete Unicode scalar");
  auto title = paneTitle(std::string(WindowTitle::capacity - 3, 'a') + "中");
  title.appendSuffix("!");
  require(title.view() == std::string(WindowTitle::capacity - 3, 'a') + "!", "a suffix must replace a partial final scalar without losing its own bytes");
  const std::string suffix(WindowTitle::capacity + 1, 's');
  title.appendSuffix(suffix);
  require(title.view() == std::string_view{suffix}.substr(0, WindowTitle::capacity), "an oversized suffix must keep the complete bounded suffix prefix");
}

void sidebarColumnBounds() {
  using telar::gui::SidebarColumns;
  constexpr std::uint16_t host_columns = 120;
  constexpr std::uint16_t preferred_columns = 70;
  constexpr auto maximum_columns = std::numeric_limits<std::uint16_t>::max();
  require(SidebarColumns::clamp(host_columns, preferred_columns) == preferred_columns, "an exact sidebar width must fit inside the current host");
  require(SidebarColumns::clamp(host_columns, maximum_columns) == host_columns - SidebarColumns::minimum_workbench, "a wide sidebar must preserve the workbench minimum");
  require(SidebarColumns::clamp(SidebarColumns::minimum_workbench, preferred_columns) == SidebarColumns::minimum_width, "a narrow host must preserve the semantic minimum preference");
}

void workspaceMarksPreserveTheOriginalInitial() {
  using telar::gui::WorkspaceMark;
  require(WorkspaceMark::resolve("telar").initial.view() == "T", "ASCII initials must be uppercase");
  require(WorkspaceMark::resolve("ñandú").initial.view() == "ñ", "non-ASCII initials must preserve the original scalar");
  require(WorkspaceMark::resolve("🧶 project").initial.view() == "🧶", "four-byte initials must remain complete");
  for (const auto name : {std::string_view{}, std::string_view{"\xff"}, std::string_view{"\xe4\xb8"}, std::string_view{"\xed\xa0\x80"}}) {
    require(WorkspaceMark::resolve(name).initial.view().empty(), "malformed or absent initials must use the folder fallback");
  }
}

void chromeSurfacesPreserveThemeAndTransparency() {
  using namespace telar::gui;
  for (const auto background : {Color::rgb(0x15151a), Color::rgb(0xf6f4ef)}) {
    Theme theme;
    theme.background = background;
    theme.foreground = background.r < 0.5F ? Color::rgb(0xe0e0e0) : Color::rgb(0x202020);
    const auto surfaces = ChromeSurfaces::derive(theme, 1);
    auto panel = theme.chromeColor(PaletteRole::panel_bg);
    panel.a = 1;
    require(surfaces.pane == panel, "pane surfaces must respect the configured panel color");
    require(surfaces.sidebar == surfaces.workbench && surfaces.topbar == surfaces.workbench && surfaces.bottombar == surfaces.workbench && surfaces.workbench != surfaces.pane, "light and dark themes must distinguish navigation, headers and gutters");
    for (const auto opacity : {0.0F, 0.5F}) {
      const auto translucent = ChromeSurfaces::derive(theme, opacity);
      require(translucent.pane.a == opacity && translucent.workbench.a == opacity && translucent.sidebar.a == opacity, "unset surface opacities must inherit the global value exactly");
    }
    require(surfaces.workbench.a == 1 && surfaces.pane.a == 1, "an unconfigured window must be opaque");
    BackgroundOpacity overrides;
    overrides.overrides[static_cast<std::size_t>(BackgroundOpacity::Surface::pane)] = 0.25F;
    const auto independent = ChromeSurfaces::derive(theme, 1, overrides);
    require(independent.pane.a == 0.25F && independent.workbench.a == 1, "a translucent pane must not reduce the workspace opacity or alter header inheritance");
  }
}

void paneSurfacesUseOnlyExistingChromeSpace() {
  using namespace telar::gui;
  for (const std::uint16_t scale : {1, 2, 3}) {
    const WorkbenchGeometry workbench{
        .area = {.width = 900.0F * scale, .height = 720.0F * scale},
        .grid = {.cell_width_px = static_cast<std::uint16_t>(9 * scale), .cell_height_px = static_cast<std::uint16_t>(18 * scale)},
        .layout_metrics = {},
    };
    const CellRectangle bounds{.width = 45, .height = 20};
    const PaneLayout::Placement placement{.bounds = bounds, .content = bounds.inner(1), .framed = true};
    const auto decorated = PaneDecorationGeometry::derive(placement, workbench);
    require(decorated.outer == workbench.pixels(bounds), "surface insets must not move the pane placement");
    require(decorated.content == workbench.pixels(placement.content), "rounded surfaces must preserve every terminal row and column");
    require(decorated.frame.x == decorated.outer.x && decorated.frame.y == decorated.outer.y, "the gutter between panes is the layout gap, not an extra frame inset");
    require(decorated.frame.intersect(decorated.content) == decorated.content, "surface insets must never crop terminal content");

    const PaneLayout::Placement unframed{.bounds = bounds, .content = bounds};
    const auto plain = PaneDecorationGeometry::derive(unframed, workbench);
    require(plain.frame.x == plain.outer.x && plain.frame.y == plain.outer.y, "unframed panes must not acquire decorative insets");
    const PaneLayout::Placement cramped{.bounds = bounds, .content = bounds, .framed = true};
    const auto tight = PaneDecorationGeometry::derive(cramped, workbench);
    require(tight.frame.intersect(tight.content) == tight.content, "missing border space must disable decorative insets");
    auto contiguous = workbench;
    contiguous.layout_metrics.gap = 0;
    const auto joined = PaneDecorationGeometry::derive(placement, contiguous);
    require(joined.frame == joined.outer, "disabled pane gaps must not acquire decorative gutters");
  }
}

void sidebarListsFollowTheReferenceBands() {
  using namespace telar::gui;
  const ChromeMetrics chrome;
  constexpr Rect sidebar{.width = 280, .height = 932};
  const auto geometry = SidebarGeometry::measure(sidebar, chrome, 1);
  constexpr Rect expected_heading{.x = 8, .y = 8, .width = 264, .height = 32};
  constexpr Rect expected_activity{.x = 8, .y = 40, .width = 264, .height = 884};
  require(geometry.projects_header.empty() && geometry.projects.empty(), "project navigation must reserve no sidebar space");
  require(geometry.activity_header == expected_heading, "activity must start at the top of the sidebar");
  require(geometry.activity == expected_activity, "activity must receive the remaining sidebar height");
  const auto crowded = SidebarGeometry::measure(sidebar, chrome, 128);
  require(crowded.activity == geometry.activity, "project count must not reduce the activity viewport");
  const auto machines = SidebarGeometry::measure(sidebar, chrome, 128, {.shown = true, .rows = 2});
  constexpr Rect expected_rows{.x = 8, .y = 40, .width = 264, .height = 64};
  require(machines.machines_header == expected_heading && machines.machines == expected_rows && machines.activity_header.y == 104 && machines.activity.y == 136, "the other machines must list above the activity section");
  const auto collapsed = SidebarGeometry::measure(sidebar, chrome, 128, {.shown = true, .rows = 0});
  require(collapsed.machines_header == expected_heading && collapsed.machines.empty() && collapsed.activity_header.y == 40, "a collapsed machine list keeps only its header");
  constexpr Rect cramped_area{.width = sidebar.width, .height = 150};
  const auto cramped = SidebarGeometry::measure(cramped_area, chrome, 1, {.shown = true, .rows = 4});
  require(cramped.machines.height == 32 && cramped.activity.height >= 32, "machine rows that do not fit stay out whole, so activity keeps its room");
  constexpr Rect short_area{.width = sidebar.width, .height = 60};
  const auto short_sidebar = SidebarGeometry::measure(short_area, chrome, 1);
  require(short_sidebar.projects.empty() && !short_sidebar.activity_header.empty(), "short sidebars must give room to activity and leave project navigation to the top bar");
}

void workspaceRailKeepsTheSelectionInView() {
  using namespace telar::gui;
  constexpr Rect rail{.width = 52, .height = 932};
  const auto single = WorkspaceRailGeometry::measure(rail, 1, {.count = 1, .active = 0});
  constexpr Rect expected_mark{.x = 7, .y = 12, .width = 36, .height = 36};
  require(single.firstMark() == expected_mark, "a single rail mark must remain at the top with the original centering");
  constexpr std::size_t workspace_count = 128;
  const auto crowded = WorkspaceRailGeometry::measure(rail, 1, {.count = workspace_count, .active = workspace_count - 1});
  require(crowded.window.first + crowded.window.count == workspace_count && crowded.window.previous() && !crowded.window.next(), "a direct jump must reveal the selected last workspace and the nearest earlier hidden project");
  auto last = crowded.firstMark();
  for (std::size_t position = 1; position < crowded.window.count; ++position) {
    last = crowded.nextMark(last);
  }

  require(!crowded.previous.empty() && !last.empty(), "overflow controls must reserve space without clipping the selected mark");
  const auto tiny = WorkspaceRailGeometry::measure(rail, std::numeric_limits<float>::min(), {.count = workspace_count, .active = 0});
  require(tiny.window.count == workspace_count, "tiny valid scales must bound slot conversion by the available workspace count");
}

void tabCaptionsFollowForegroundAndDirectory() {
  using telar::gui::TabCaption;
  TabCaption::Buffer storage;
  require(TabCaption::resolve({.manual = {}, .application = "Python", .directory = "/work/telar///", .session_title = {}}, storage) == "telar · Python", "automatic tabs must distinguish their directory and application");
  require(TabCaption::resolve({.manual = {}, .application = "nvim", .directory = R"(C:\work\telar\)", .session_title = {}}, storage) == "telar · nvim", "directory captions must recognize both path separators");
  require(TabCaption::resolve({.manual = "Review", .application = "sh", .directory = {}, .session_title = "Agent title"}, storage) == "Review", "manual tab labels must take precedence over agent session titles");
  require(TabCaption::resolve({.manual = {}, .application = "sh", .directory = "/work/telar", .session_title = "Agent title"}, storage) == "Agent title", "usable agent session titles must take precedence over directory captions");
  const TabCaption::Content missing;
  require(TabCaption::resolve(missing, storage) == "shell", "missing foreground metadata must retain the native shell fallback");
  require(TabCaption::directoryName("/") == "/" && TabCaption::directoryName("\\") == "\\", "root directories must retain their separator");
  require(TabCaption::directoryName("/work/invalid\nname").empty() && TabCaption::directoryName("/work/\xff").empty(), "invalid directory labels must not reach chrome");
  const std::string prefix(TabCaption::directory_capacity - 1, 'a');
  require(TabCaption::directoryName(prefix + "🧶") == prefix, "directory truncation must keep complete Unicode scalars");
}

void tabStripsCompressAroundTheirFocus() {
  using Geometry = telar::gui::TabStripGeometry;
  const auto metrics = Geometry::Metrics::scaled(1);
  constexpr std::size_t tab_count = 4;
  constexpr float caption_width = 100;
  std::array<Geometry::Measure, tab_count> sizes;
  sizes.fill({.caption = caption_width, .chip = Geometry::chip_widths[0], .status = 0});
  constexpr float wide_room = 1000;
  const auto wide = Geometry::arrange(sizes, 0, {.width = wide_room, .metrics = metrics});
  require(wide.first == 0 && wide.end == tab_count && wide.hidden() == 0, "a wide strip must keep every natural caption");
  for (const auto width : std::span{wide.widths}.first(tab_count)) {
    require(width == wide_room / tab_count, "tabs must share the strip equally so the selection slides over a still row");
  }

  constexpr float narrow_room = 215;
  constexpr std::size_t focus = 2;
  const auto narrow = Geometry::arrange(sizes, focus, {.width = narrow_room, .metrics = metrics});
  require(narrow.first == 1 && narrow.end == 3 && narrow.shows(focus), "overflow must hide the farthest tabs while keeping the focus");
  require(narrow.fits[focus] == Geometry::Fit::truncated && narrow.fits[1] == Geometry::Fit::compact, "the focus must retain its caption before its neighbors");
  require(narrow.nearestHidden() == 3, "the overflow counter must select the nearest hidden tab");
  require(narrow.footprint(metrics) <= narrow_room, "the overflow counter and gaps must share the strip's budget");
}

void tabSelectionRetargetsWithoutJumping() {
  using namespace telar::gui;
  const Rect initial{.width = 80, .height = 30};
  const Rect target{.x = 80, .width = 160, .height = 30};
  TabMotion selection{.from = initial, .to = initial};
  TabMotionFrame frame;
  require(selection.place(initial, frame) == initial && !frame.deadline_ns, "an idle selection must not request frames");
  require(selection.place(target, frame) == initial && frame.deadline_ns, "selection movement must start at the displayed capsule");
  frame.begin(TabMotion::duration_ns / 2);
  const auto halfway = selection.place(target, frame);
  require(halfway == Rect{.x = 70, .width = 150, .height = 30}, "selection position and width must share the tab easing curve");
  require(selection.place(initial, frame) == halfway, "rapid selection changes must retarget from the displayed position");
  frame.begin(frame.now_ns + TabMotion::duration_ns);
  require(selection.place(initial, frame) == initial && !frame.deadline_ns, "a settled selection must stop requesting frames");
  require(selection.place(target, frame, true) == target && !frame.deadline_ns, "dragging or changing context must place the capsule immediately");
}

void artworkPreservesAlphaWithoutTransparentFringes() {
  using namespace telar::gui;
  constexpr std::array<std::uint8_t, 8> pixels{255, 0, 0, 0, 0, 0, 255, 255};
  const RgbaImageView source{.pixels = std::as_bytes(std::span{pixels}), .stride = pixels.size(), .width = 2, .height = 1};
  std::array<std::uint8_t, RgbaImageView::channels> destination{};
  require(ArtworkResize::square(source, destination, 1), "valid artwork must resize into caller-owned storage");
  constexpr std::array<std::uint8_t, RgbaImageView::channels> straight{0, 0, 255, 128};
  require(destination == straight, "transparent color must not contaminate an opaque neighbor");
  ArtworkResize::premultiply(destination);
  constexpr std::array<std::uint8_t, RgbaImageView::channels> premultiplied{0, 0, 128, 128};
  require(destination == premultiplied, "sprite storage must round premultiplied channels to the nearest byte");
}

void artworkRejectsInvalidStorageBeforeWriting() {
  using namespace telar::gui;
  constexpr std::array<std::uint8_t, RgbaImageView::channels> pixel{0, 0, 255, 255};
  constexpr auto bytes = pixel.size();
  const auto source = std::as_bytes(std::span{pixel});
  constexpr std::array<std::uint8_t, bytes> unchanged{1, 2, 3, 4};
  auto destination = unchanged;
  std::array<RgbaImageView, 4> invalid{};
  invalid[1] = {.pixels = source, .stride = bytes - 1, .width = 1, .height = 1};
  invalid[2] = {.pixels = source, .stride = bytes, .width = 1, .height = 2};
  invalid[3] = {.pixels = source, .stride = 0, .width = 1, .height = 1};
  for (const auto image : invalid) {
    require(!ArtworkResize::square(image, destination, 1), "invalid source ranges must be rejected");
    require(destination == unchanged, "invalid artwork must preserve the destination");
  }

  const RgbaImageView valid{.pixels = source, .stride = bytes, .width = 1, .height = 1};
  require(!ArtworkResize::square(valid, std::span{destination}.first(bytes - 1), 1), "short output storage must be rejected");
  require(!ArtworkResize::square(valid, destination, std::numeric_limits<std::size_t>::max()), "unrepresentable output dimensions must be rejected");
  require(!ArtworkResize::square(valid, destination, 0), "empty output dimensions must be rejected");
  require(destination == unchanged, "invalid output ranges must be detected before any write");
}

}

int main() {
  try {
    titleTokens();
    titleSanitization();
    titleBoundsAndSuffix();
    sidebarColumnBounds();
    workspaceMarksPreserveTheOriginalInitial();
    chromeSurfacesPreserveThemeAndTransparency();
    paneSurfacesUseOnlyExistingChromeSpace();
    sidebarListsFollowTheReferenceBands();
    workspaceRailKeepsTheSelectionInView();
    tabCaptionsFollowForegroundAndDirectory();
    tabStripsCompressAroundTheirFocus();
    tabSelectionRetargetsWithoutJumping();
    artworkPreservesAlphaWithoutTransparentFringes();
    artworkRejectsInvalidStorageBeforeWriting();
    std::puts("gui-presentation: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-presentation: " << error.what() << '\n';

    return 1;
  }
}
