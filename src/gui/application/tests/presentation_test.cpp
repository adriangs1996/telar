#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <cstring>

import std;
import telar.testing;
import telar.gui.foundation.core;
import telar.gui.features.terminal.graphics;
import telar.gui.features.workbench;
import telar.gui.foundation.text;
import telar.gui.application;
import telar.gui.foundation.model;
import telar.gui.features.window;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui::features::terminal::graphics;
  using namespace telar::gui::features::workbench;

  using telar::gui::features::window::WindowTitle;

  WindowTitle paneTitle(std::string_view text) {
    return WindowTitle::render("{pane_title}", {.workspace = {}, .tab = {}, .pane_title = text, .hostname = {}});
  }

  void titleTokens() {
    constexpr WindowTitle::Tokens tokens{.workspace = "project", .tab = "build", .pane_title = "compiler", .hostname = "host"};
    const auto expanded = WindowTitle::render("{hostname}/{workspace}/{tab}: {pane_title}", tokens);

    check(expanded.view() == "host/project/build: compiler", "all configured title tokens must expand");
    check(WindowTitle::render("{unknown} {{tab}} {unfinished", tokens).view() == "{unknown} {build} {unfinished", "unknown tokens and unmatched braces must remain literal");
    check(WindowTitle::render("{tab}/{pane_title}", {}).view() == "/", "missing values must expand to empty text");
  }

  void titleSanitization() {
    const auto controls = paneTitle("a\n\t\x7f\xc2\x80\xc2\x9f"
                                    "b中");

    check(controls.view() == "ab中", "title delivery must remove ASCII and C1 controls while preserving UTF-8");
    check(paneTitle("kept\xfflost").view() == "kept", "invalid UTF-8 must end the delivered title");
    check(paneTitle("kept\xe4\xb8").view() == "kept", "incomplete Unicode scalars must not reach the host");
  }

  void titleBoundsAndSuffix() {
    const std::string prefix(WindowTitle::capacity - 1, 'a');
    const auto clipped = paneTitle(prefix + "中");

    check(clipped.view() == prefix, "bounded titles must end at a complete Unicode scalar");
    auto title = paneTitle(std::string(WindowTitle::capacity - 3, 'a') + "中");

    title.appendSuffix("!");
    check(title.view() == std::string(WindowTitle::capacity - 3, 'a') + "!", "a suffix must replace a partial final scalar without losing its own bytes");
    const std::string suffix(WindowTitle::capacity + 1, 's');

    title.appendSuffix(suffix);
    check(title.view() == std::string_view{suffix}.substr(0, WindowTitle::capacity), "an oversized suffix must keep the complete bounded suffix prefix");
  }

  void sidebarColumnBounds() {
    using telar::gui::application::SidebarColumns;
    constexpr std::uint16_t host_columns = 120;
    constexpr std::uint16_t preferred_columns = 70;
    constexpr auto maximum_columns = std::numeric_limits<std::uint16_t>::max();

    check(SidebarColumns::clamp(host_columns, preferred_columns) == preferred_columns, "an exact sidebar width must fit inside the current host");
    check(SidebarColumns::clamp(host_columns, maximum_columns) == host_columns - SidebarColumns::minimum_workbench, "a wide sidebar must preserve the workbench minimum");
    check(SidebarColumns::clamp(SidebarColumns::minimum_workbench, preferred_columns) == SidebarColumns::minimum_width, "a narrow host must preserve the semantic minimum preference");
  }

  void workspaceMarksPreserveTheOriginalInitial() {
    using telar::gui::features::workbench::WorkspaceMark;

    check(WorkspaceMark::resolve("telar").initial.view() == "T", "ASCII initials must be uppercase");
    check(WorkspaceMark::resolve("ñandú").initial.view() == "ñ", "non-ASCII initials must preserve the original scalar");
    check(WorkspaceMark::resolve("🧶 project").initial.view() == "🧶", "four-byte initials must remain complete");
    for (const auto name : {std::string_view{}, std::string_view{"\xff"}, std::string_view{"\xe4\xb8"}, std::string_view{"\xed\xa0\x80"}}) {
      check(WorkspaceMark::resolve(name).initial.view().empty(), "malformed or absent initials must use the folder fallback");
    }
  }

  void chromeSurfacesPreserveThemeAndTransparency() {
    using namespace telar::gui;
    using namespace telar::gui::features::workbench;
    using namespace telar::gui::features::window;

    for (const auto background : {Color::rgb(0x15151a), Color::rgb(0xf6f4ef)}) {
      Theme theme;

      theme.background = background;
      theme.foreground = background.r < 0.5F ? Color::rgb(0xe0e0e0) : Color::rgb(0x202020);
      const auto surfaces = ChromeSurfaces::derive(theme, 1);
      auto panel = theme.chromeColor(PaletteRole::panel_bg);

      panel.a = 1;
      check(surfaces.pane == panel, "pane surfaces must respect the configured panel color");
      check(surfaces.sidebar == surfaces.workbench && surfaces.topbar == surfaces.workbench && surfaces.bottombar == surfaces.workbench && surfaces.workbench != surfaces.pane, "light and dark themes must distinguish navigation, headers and gutters");
      for (const auto opacity : {0.0F, 0.5F}) {
        const auto translucent = ChromeSurfaces::derive(theme, opacity);

        check(translucent.pane.a == opacity && translucent.workbench.a == opacity && translucent.sidebar.a == opacity, "unset surface opacities must inherit the global value exactly");
      }

      check(surfaces.workbench.a == 1 && surfaces.pane.a == 1, "an unconfigured window must be opaque");
      BackgroundOpacity overrides;

      overrides.overrides.atMut(static_cast<std::size_t>(BackgroundOpacity::Surface::pane)) = 0.25F;
      const auto independent = ChromeSurfaces::derive(theme, 1, overrides);

      check(independent.pane.a == 0.25F && independent.workbench.a == 1, "a translucent pane must not reduce the workspace opacity or alter header inheritance");
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

      check(decorated.outer == workbench.pixels(bounds), "surface insets must not move the pane placement");
      check(decorated.content == workbench.pixels(placement.content), "rounded surfaces must preserve every terminal row and column");
      check(decorated.frame.x == decorated.outer.x && decorated.frame.y == decorated.outer.y, "the gutter between panes is the layout gap, not an extra frame inset");
      check(decorated.frame.intersect(decorated.content) == decorated.content, "surface insets must never crop terminal content");

      const PaneLayout::Placement unframed{.bounds = bounds, .content = bounds};
      const auto plain = PaneDecorationGeometry::derive(unframed, workbench);

      check(plain.frame.x == plain.outer.x && plain.frame.y == plain.outer.y, "unframed panes must not acquire decorative insets");
      const PaneLayout::Placement cramped{.bounds = bounds, .content = bounds, .framed = true};
      const auto tight = PaneDecorationGeometry::derive(cramped, workbench);

      check(tight.frame.intersect(tight.content) == tight.content, "missing border space must disable decorative insets");
      auto contiguous = workbench;

      contiguous.layout_metrics.gap = 0;
      const auto joined = PaneDecorationGeometry::derive(placement, contiguous);

      check(joined.frame == joined.outer, "disabled pane gaps must not acquire decorative gutters");
    }
  }

  void sidebarListsFollowTheReferenceBands() {
    using namespace telar::gui;
    const ChromeMetrics chrome;
    constexpr Rect sidebar{.width = 280, .height = 932};
    const auto geometry = application::SidebarGeometry::measure(sidebar, chrome, 1);
    constexpr Rect expected_heading{.x = 8, .y = 8, .width = 264, .height = 32};
    constexpr Rect expected_activity{.x = 8, .y = 40, .width = 264, .height = 884};

    check(geometry.projects_header.empty() && geometry.projects.empty(), "project navigation must reserve no sidebar space");
    check(geometry.activity_header == expected_heading, "activity must start at the top of the sidebar");
    check(geometry.activity == expected_activity, "activity must receive the remaining sidebar height");
    const auto crowded = application::SidebarGeometry::measure(sidebar, chrome, 128);

    check(crowded.activity == geometry.activity, "project count must not reduce the activity viewport");
    const auto machines = application::SidebarGeometry::measure(sidebar, chrome, 128, {.shown = true, .rows = 2});
    constexpr Rect expected_rows{.x = 8, .y = 40, .width = 264, .height = 86};

    check(machines.machines_header == expected_heading && machines.machines == expected_rows && machines.activity_header.y == 142 && machines.activity.y == 174, "the other machines must list above the activity section, a section gap apart");
    const auto collapsed = application::SidebarGeometry::measure(sidebar, chrome, 128, {.shown = true, .rows = 0});

    check(collapsed.machines_header == expected_heading && collapsed.machines.empty() && collapsed.activity_header.y == 56, "a collapsed machine list keeps only its header and the gap under it");
    constexpr Rect cramped_area{.width = sidebar.width, .height = 180};
    const auto cramped = application::SidebarGeometry::measure(cramped_area, chrome, 1, {.shown = true, .rows = 4});

    check(cramped.machines.height == 43 && cramped.activity.height >= 32, "machine rows that do not fit stay out whole, so activity keeps its room");
    constexpr Rect short_area{.width = sidebar.width, .height = 60};
    const auto short_sidebar = application::SidebarGeometry::measure(short_area, chrome, 1);

    check(short_sidebar.projects.empty() && !short_sidebar.activity_header.empty(), "short sidebars must give room to activity and leave project navigation to the top bar");
  }

  void tabCaptionsFollowForegroundAndDirectory() {
    using telar::gui::TabCaption;
    TabCaption::Buffer storage;

    check(TabCaption::resolve({.manual = {}, .application = "Python", .directory = "/work/telar///", .session_title = {}}, storage) == "telar · Python", "automatic tabs must distinguish their directory and application");
    check(TabCaption::resolve({.manual = {}, .application = "nvim", .directory = R"(C:\work\telar\)", .session_title = {}}, storage) == "telar · nvim", "directory captions must recognize both path separators");
    check(TabCaption::resolve({.manual = "Review", .application = "sh", .directory = {}, .session_title = "Agent title"}, storage) == "Review", "manual tab labels must take precedence over agent session titles");
    check(TabCaption::resolve({.manual = {}, .application = "sh", .directory = "/work/telar", .session_title = "Agent title"}, storage) == "Agent title", "usable agent session titles must take precedence over directory captions");
    const TabCaption::Content missing;

    check(TabCaption::resolve(missing, storage) == "shell", "missing foreground metadata must retain the native shell fallback");
    check(TabCaption::directoryName("/") == "/" && TabCaption::directoryName("\\") == "\\", "root directories must retain their separator");
    check(TabCaption::directoryName("/work/invalid\nname").empty() && TabCaption::directoryName("/work/\xff").empty(), "invalid directory labels must not reach chrome");
    const std::string prefix(TabCaption::directory_capacity - 1, 'a');

    check(TabCaption::directoryName(prefix + "🧶") == prefix, "directory truncation must keep complete Unicode scalars");
  }

  void tabStripsCompressAroundTheirFocus() {
    using Geometry = telar::gui::features::workbench::TabStripGeometry;
    const auto metrics = Geometry::Metrics::scaled(1);
    constexpr std::size_t tab_count = 4;
    constexpr float caption_width = 100;
    telar::ds::Array<Geometry::Measure, tab_count> sizes;

    sizes.fill({.caption = caption_width, .chip = Geometry::chip_widths[0], .status = 0});
    constexpr float wide_room = 1000;
    const auto wide = Geometry::arrange(sizes, 0, {.width = wide_room, .metrics = metrics});

    check(wide.first == 0 && wide.end == tab_count && wide.hidden() == 0, "a wide strip must keep every natural caption");
    for (const auto width : std::span{wide.widths}.first(tab_count)) {
      check(width == wide_room / tab_count, "tabs must share the strip equally so the selection slides over a still row");
    }

    constexpr float narrow_room = 215;
    constexpr std::size_t focus = 2;
    const auto narrow = Geometry::arrange(sizes, focus, {.width = narrow_room, .metrics = metrics});

    check(narrow.first == 1 && narrow.end == 3 && narrow.shows(focus), "overflow must hide the farthest tabs while keeping the focus");
    check(narrow.fits[focus] == Geometry::Fit::truncated && narrow.fits[1] == Geometry::Fit::compact, "the focus must retain its caption before its neighbors");
    check(narrow.nearestHidden() == 3, "the overflow counter must select the nearest hidden tab");
    check(narrow.footprint(metrics) <= narrow_room, "the overflow counter and gaps must share the strip's budget");
  }

  void tabSelectionRetargetsWithoutJumping() {
    using namespace telar::gui;
    const Rect initial{.width = 80, .height = 30};
    const Rect target{.x = 80, .width = 160, .height = 30};
    TabMotion selection{.from = initial, .to = initial};
    TabMotionFrame frame;

    check(selection.place(initial, frame) == initial && !frame.deadline_ns, "an idle selection must not request frames");
    check(selection.place(target, frame) == initial && frame.deadline_ns, "selection movement must start at the displayed capsule");
    frame.begin(TabMotion::duration_ns / 2);
    const auto halfway = selection.place(target, frame);

    check(halfway == Rect{.x = 70, .width = 150, .height = 30}, "selection position and width must share the tab easing curve");
    check(selection.place(initial, frame) == halfway, "rapid selection changes must retarget from the displayed position");
    frame.begin(frame.now_ns + TabMotion::duration_ns);
    check(selection.place(initial, frame) == initial && !frame.deadline_ns, "a settled selection must stop requesting frames");
    check(selection.place(target, frame, true) == target && !frame.deadline_ns, "dragging or changing context must place the capsule immediately");
  }

  void artworkPreservesAlphaWithoutTransparentFringes() {
    using namespace telar::gui;
    constexpr telar::ds::Array<std::uint8_t, 8> pixels{255, 0, 0, 0, 0, 0, 255, 255};
    const RgbaImageView source{.pixels = std::as_bytes(std::span{pixels}), .stride = pixels.size(), .width = 2, .height = 1};
    telar::ds::Array<std::uint8_t, RgbaImageView::channels> destination{};

    check(ArtworkResize::square(source, destination.viewMut(), 1), "valid artwork must resize into caller-owned storage");
    constexpr telar::ds::Array<std::uint8_t, RgbaImageView::channels> straight{0, 0, 255, 128};

    check(destination == straight, "transparent color must not contaminate an opaque neighbor");
    ArtworkResize::premultiply(destination.viewMut());
    constexpr telar::ds::Array<std::uint8_t, RgbaImageView::channels> premultiplied{0, 0, 128, 128};

    check(destination == premultiplied, "sprite storage must round premultiplied channels to the nearest byte");
  }

  void artworkRejectsInvalidStorageBeforeWriting() {
    using namespace telar::gui;
    constexpr telar::ds::Array<std::uint8_t, RgbaImageView::channels> pixel{0, 0, 255, 255};
    constexpr auto bytes = pixel.size();
    const auto source = std::as_bytes(std::span{pixel});
    constexpr telar::ds::Array<std::uint8_t, bytes> unchanged{1, 2, 3, 4};
    auto destination = unchanged;
    telar::ds::Array<RgbaImageView, 4> invalid{};

    invalid.atMut(1) = {.pixels = source, .stride = bytes - 1, .width = 1, .height = 1};
    invalid.atMut(2) = {.pixels = source, .stride = bytes, .width = 1, .height = 2};
    invalid.atMut(3) = {.pixels = source, .stride = 0, .width = 1, .height = 1};
    for (const auto image : invalid) {
      check(!ArtworkResize::square(image, destination.viewMut(), 1), "invalid source ranges must be rejected");
      check(destination == unchanged, "invalid artwork must preserve the destination");
    }

    const RgbaImageView valid{.pixels = source, .stride = bytes, .width = 1, .height = 1};

    check(!ArtworkResize::square(valid, destination.viewMut().first(bytes - 1), 1), "short output storage must be rejected");
    check(!ArtworkResize::square(valid, destination.viewMut(), std::numeric_limits<std::size_t>::max()), "unrepresentable output dimensions must be rejected");
    check(!ArtworkResize::square(valid, destination.viewMut(), 0), "empty output dimensions must be rejected");
    check(destination == unchanged, "invalid output ranges must be detected before any write");
  }

  const telar::testing::Case case_title_tokens{"presentation.title_tokens", titleTokens};
  const telar::testing::Case case_title_sanitization{"presentation.title_sanitization", titleSanitization};
  const telar::testing::Case case_title_bounds_and_suffix{"presentation.title_bounds_and_suffix", titleBoundsAndSuffix};
  const telar::testing::Case case_sidebar_column_bounds{"presentation.sidebar_column_bounds", sidebarColumnBounds};
  const telar::testing::Case case_workspace_marks_preserve_the_original_initial{"presentation.workspace_marks_preserve_the_original_initial", workspaceMarksPreserveTheOriginalInitial};
  const telar::testing::Case case_chrome_surfaces_preserve_theme_and_transparency{"presentation.chrome_surfaces_preserve_theme_and_transparency", chromeSurfacesPreserveThemeAndTransparency};
  const telar::testing::Case case_pane_surfaces_use_only_existing_chrome_space{"presentation.pane_surfaces_use_only_existing_chrome_space", paneSurfacesUseOnlyExistingChromeSpace};
  const telar::testing::Case case_sidebar_lists_follow_the_reference_bands{"presentation.sidebar_lists_follow_the_reference_bands", sidebarListsFollowTheReferenceBands};
  const telar::testing::Case case_tab_captions_follow_foreground_and_directory{"presentation.tab_captions_follow_foreground_and_directory", tabCaptionsFollowForegroundAndDirectory};
  const telar::testing::Case case_tab_strips_compress_around_their_focus{"presentation.tab_strips_compress_around_their_focus", tabStripsCompressAroundTheirFocus};
  const telar::testing::Case case_tab_selection_retargets_without_jumping{"presentation.tab_selection_retargets_without_jumping", tabSelectionRetargetsWithoutJumping};
  const telar::testing::Case case_artwork_preserves_alpha_without_transparent_fringes{"presentation.artwork_preserves_alpha_without_transparent_fringes", artworkPreservesAlphaWithoutTransparentFringes};
  const telar::testing::Case case_artwork_rejects_invalid_storage_before_writing{"presentation.artwork_rejects_invalid_storage_before_writing", artworkRejectsInvalidStorageBeforeWriting};

}
