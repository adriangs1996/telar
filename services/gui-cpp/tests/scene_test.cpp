#include "application/dependencies.hpp"
#include "core/color.hpp"
#include "core/configuration.hpp"
#include "core/terminal_surface.hpp"
#include "fonts/face.hpp"
#include "fonts/font_role.hpp"
#include "fonts/glyph_bitmap_view.hpp"
#include "graphics/store.hpp"
#include "links/link_hit.hpp"
#include "links/link_match.hpp"
#include "links/link_target.hpp"
#include "qt/box_font.hpp"
#include "qt/bundled_fonts.hpp"
#include "qt/font_collection.hpp"
#include "qt/font_resolver.hpp"
#include "qt/link_preview.hpp"
#include "qt/projection.hpp"
#include "qt/resident_fonts.hpp"
#include "qt/scene_nodes.hpp"
#include "qt/terminal_font.hpp"
#include "qt/terminal_scene.hpp"
#include "qt/window_images.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/font_grid.hpp"
#include "terminal/screen.hpp"
#include "terminal/selection.hpp"
#include <QColor>
#include <QGuiApplication>
#include <QImage>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRect>
#include <QSGNode>
#include <QSGSimpleRectNode>
#include <QSize>
#include <QSizeF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qnamespace.h>
#include <QtCore/qsystemdetection.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qrgb.h>
#include <QtGui/qtestsupport_gui.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;

constexpr CellStyle plain_style;
constexpr CellSelection no_selection;
constexpr CellPosition origin;
constexpr TabLocation no_location;

constexpr auto background_color = Color::rgb(0x101010);
constexpr auto cursor_color = Color::rgb(0x22cc55);
constexpr auto cursor_text_color = Color::rgb(0x3366ff);

enum class BackgroundPattern : std::uint8_t {
  uniform,
  alternating,
  default_gaps,
  selection_inverse,
  wide_overlap,
  translucent_wide_overlap,
  clipped_wide,
};

struct BackgroundRectangle {
  qreal column;
  qreal columns;
  Color color;
};

constexpr std::size_t background_columns = 8;
constexpr std::size_t background_selection_start = 2;
constexpr std::size_t background_selection_end = 5;
constexpr auto background_blue = Color::rgb(0x2040dc);

struct BackgroundRow {
  std::array<Cell, background_columns> cells;
  std::vector<BackgroundRectangle> rectangles;
};

BackgroundRow backgroundRow(BackgroundPattern pattern, Color first_color) {
  static constexpr std::array<Byte, 1> space{' '};
  constexpr std::size_t inverse_columns = 4;
  constexpr qreal wide_columns = 2;
  const auto wide = pattern == BackgroundPattern::wide_overlap || pattern == BackgroundPattern::translucent_wide_overlap || pattern == BackgroundPattern::clipped_wide;
  BackgroundRow row;
  for (std::size_t column = 0; column < background_columns; ++column) {
    const auto alternate = pattern == BackgroundPattern::alternating && column % 2 != 0;
    auto &cell = row.cells[column];
    cell.text = space;
    cell.style.background = {.kind = CellColor::Kind::indexed, .channels = {static_cast<Byte>(alternate)}};
    Color expected = alternate ? background_blue : first_color;
    if (pattern == BackgroundPattern::default_gaps && column % 3 == 1) {
      cell.style.background = {};
      continue;
    }

    if (pattern == BackgroundPattern::selection_inverse) {
      if (column < inverse_columns) {
        cell.style.flags = static_cast<std::uint16_t>(CellAttribute::inverse);
      }

      if (column < background_selection_start || (column >= inverse_columns && column <= background_selection_end)) {
        expected = cursor_color;
      }
    }

    if (wide && column % 2 == 0) {
      cell.width = CellWidth::wide;
    } else if (wide) {
      cell.width = CellWidth::continuation;
      cell.text = {};
    }

    row.rectangles.push_back({.column = static_cast<qreal>(column), .columns = cell.width == CellWidth::wide ? wide_columns : 1, .color = expected});
  }

  return row;
}

LinkTarget requireLinkTarget(std::string_view text) {
  const auto target = LinkTarget::fromUri(text);
  if (!target) {
    throw std::runtime_error{"The scene fixture must contain a valid URI"};
  }

  return *target;
}

class SceneItem final : public QQuickItem {
public:
  SceneItem(const TerminalPresentation &frame, QQuickItem *parent)
      : QQuickItem(parent),
        frame_(frame) {
    WindowImages::forWindow(*window());
    setFlag(ItemHasContents);
    setClip(true);
    setWidth(frame.bounds.width());
    setHeight(frame.bounds.height());
  }

  void setKeyboard(bool enabled) {
    frame_.keyboard = enabled;
    update();
  }

  void setPaneFocused(bool focused) {
    frame_.pane_focused = focused;
    update();
  }

  void setCursorOn(bool enabled) {
    frame_.cursor_on = enabled;
    update();
  }

  void setColumns(std::uint16_t columns) {
    frame_.bounds.setWidth(frame_.font.cell.width() * columns);
    setWidth(frame_.bounds.width());
    update();
  }

  void select(CellSelection selection) {
    frame_.selection = selection;
    update();
  }

  void hover(const LinkMatch *match) {
    frame_.hovered_link = match;
    update();
  }

  void resizeCell(QSizeF size) {
    frame_.bounds.setSize(size);
    frame_.grid.width = static_cast<std::uint16_t>(std::round(size.width() * window()->devicePixelRatio()));
    frame_.grid.height = static_cast<std::uint16_t>(std::round(size.height() * window()->devicePixelRatio()));
    ++frame_.appearance;
    setSize(size);
    update();
  }

  void invalidateAppearance() {
    ++frame_.appearance;
    update();
  }

  void setBoxStroke(float stroke) {
    frame_.box_stroke = stroke;
    invalidateAppearance();
  }

  void setRasterPixelHeight(std::uint16_t height) {
    frame_.grid.pixel_height = height;
    invalidateAppearance();
  }

  void referenceBackgrounds(std::optional<std::vector<BackgroundRectangle>> rectangles) {
    reference_backgrounds_ = std::move(rectangles);
    update();
  }

protected:
  QSGNode *updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *update_data) override {
    frame_.scale = window()->devicePixelRatio();
    frame_.owner = this;

    if (reference_backgrounds_) {
      std::unique_ptr<QSGNode> old{previous};
      old.reset();
      auto root = std::make_unique<QSGNode>();
      appendSceneNode<QSGSimpleRectNode>(*root, frame_.bounds, toQColor(frame_.configuration.theme.background));
      for (const auto &rectangle : *reference_backgrounds_) {
        const QRectF bounds{rectangle.column * frame_.font.cell.width(), 0, rectangle.columns * frame_.font.cell.width(), frame_.font.cell.height()};
        appendSceneNode<QSGSimpleRectNode>(*root, bounds, toQColor(rectangle.color));
      }

      return root.release();
    }

    return TerminalScene::synchronizeNode(previous, *window(), frame_);
  }

private:
  TerminalPresentation frame_;
  std::optional<std::vector<BackgroundRectangle>> reference_backgrounds_;
};

class SceneFixture {
public:
  explicit SceneFixture(CursorShape shape, bool cursor_visible = true)
      : screen_(memory_),
        graphics_(memory_, budget_),
        resolved_(FontResolver::resolve(memory_, configuration_.font, window_.devicePixelRatio())),
        font_(resolved_.font),
        item_({
                  .screen = screen_,
                  .graphics = graphics_,
                  .configuration = configuration_,
                  .font = font_,
                  .preedit = preedit_,
                  .fonts = std::make_shared<const FontCollection>(FontCollection{.primary = ResidentFonts::resolveSource({}, {})}),
                  .grid = resolved_.grid,
                  .selection = no_selection,
                  .bounds = {0, 0, font_.cell.width(), font_.cell.height()},
                  .appearance = 1,
                  .pane_focused = true,
                  .keyboard = true,
              },
              window_.contentItem()) {
    configuration_.theme.background = background_color;
    configuration_.theme.cursor = cursor_color;
    configuration_.theme.foreground = cursor_color;
    window_.setColor(toQColor(background_color));
    window_.resize(static_cast<int>(std::ceil(font_.cell.width())), static_cast<int>(std::ceil(font_.cell.height())));
    setCell(plain_style, shape, cursor_visible);
    window_.show();
  }

  void setCell(CellStyle style, CursorShape shape, bool cursor_visible, std::string_view text = " ") {
    std::array<Byte, CellValue::text_capacity> bytes{};
    if (text.empty() || text.size() > bytes.size()) {
      throw std::length_error{"Scene fixture text exceeds one cell"};
    }

    for (std::size_t index = 0; index < text.size(); ++index) {
      bytes[index] = static_cast<Byte>(text[index]);
    }

    const std::array<Cell, 1> cells{{{.style = style, .text = std::span{bytes}.first(text.size())}}};
    setCells(cells, {.visible = cursor_visible, .shape = shape});
  }

  void setCells(std::span<const Cell> cells, Cursor cursor) {
    constexpr std::size_t encoded_capacity = 1024;
    std::array<Byte, encoded_capacity> encoded{};
    const auto run = CellRunCodec::encode(cells, encoded);
    const std::array<FrameSpan, 1> spans{{{.start = 0, .count = static_cast<std::uint32_t>(cells.size()), .cells = run}}};
    const std::array<Byte, 1> flags{};
    PaneFrame frame;
    frame.pane_id = 1;
    frame.frame_id = ++frame_id_;
    frame.cols = static_cast<std::uint16_t>(cells.size());
    frame.rows = 1;
    frame.scroll.total_rows = 1;
    frame.cursor = cursor;
    frame.text_metadata = TextMetadata{.row_flags = flags};
    frame.spans = spans;
    const auto previous_columns = screen_.columns();
    if (screen_.apply(frame) != FrameApplication::applied) {
      throw std::runtime_error{"Scene fixture rejected its snapshot"};
    }

    if (previous_columns != frame.cols) {
      item_.setColumns(frame.cols);
      resizeWindow();
    }

    item_.update();
  }

  void moveCursor(std::uint16_t column) {
    PaneFrame frame;
    frame.pane_id = 1;
    frame.base_frame_id = screen_.frameId();
    frame.frame_id = ++frame_id_;
    frame.cols = screen_.columns();
    frame.rows = screen_.rows();
    frame.scroll = screen_.scroll();
    frame.cursor = screen_.cursor();
    frame.cursor.x = column;
    if (screen_.apply(frame) != FrameApplication::applied) {
      throw std::runtime_error{"Scene fixture rejected its cursor delta"};
    }

    item_.update();
  }

  void setCursorOn(bool enabled) {
    item_.setCursorOn(enabled);
  }

  void setVisibleColumns(std::uint16_t columns) {
    item_.setColumns(columns);
    resizeWindow();
  }

  void invalidateAppearance() {
    item_.invalidateAppearance();
  }

  [[nodiscard]] std::uint64_t rowRevision() const {
    return screen_.rowRevision(0);
  }

  [[nodiscard]] QImage capture() {
    constexpr int frame_wait_ms = 50;
    waitForExposure();
    QTest::qWait(frame_wait_ms);

    const auto scale = window_.devicePixelRatio();
    const QRect cell{0, 0, static_cast<int>(std::ceil(item_.width() * scale)), static_cast<int>(std::ceil(item_.height() * scale))};
    QImage image;
    const auto ready = QTest::qWaitFor([&] {
      image = window_.grabWindow();
      if (image.width() >= cell.width() && image.height() >= cell.height()) {
        return true;
      }

      resizeWindow();
      window_.update();

      return false;
    });
    if (!ready) {
      throw std::runtime_error{"Scene test surface is smaller than the requested cell"};
    }

    return image.size() == cell.size() ? image : image.copy(cell);
  }

  [[nodiscard]] QColor pixel(const QImage &image, qreal x, qreal y) const {
    const auto scale = window_.devicePixelRatio();

    return image.pixelColor(static_cast<int>(x * scale), static_cast<int>(y * scale));
  }

  void setKeyboard(bool enabled) {
    item_.setKeyboard(enabled);
  }

  void setCursorTextColor(Color color) {
    configuration_.theme.cursor_text = color;
    item_.update();
  }

  void setPaneFocused(bool focused) {
    item_.setPaneFocused(focused);
  }

  void setFontRendering(bool thicken, std::uint8_t strength) {
    configuration_.font.thicken = thicken;
    configuration_.font.thicken_strength = strength;
    item_.invalidateAppearance();
  }

  void setPaletteColor(std::size_t index, Color color) {
    configuration_.theme.palette.at(index) = color;
    item_.invalidateAppearance();
  }

  void referenceBackgrounds(std::optional<std::vector<BackgroundRectangle>> rectangles) {
    item_.referenceBackgrounds(std::move(rectangles));
  }

  void setPreedit(const QString &text) {
    preedit_ = text;
    item_.update();
  }

  void setBoxStroke(float stroke) {
    item_.setBoxStroke(stroke);
  }

  void resizeCell(QSizeF size) {
    waitForExposure();
    font_.cell = size;
    item_.resizeCell(size);
    resizeWindow();
  }

  void resizePhysicalCell(QSize pixels) {
    resizeCell(QSizeF{pixels} / window_.devicePixelRatio());
  }

  void select(CellSelection selection) {
    item_.select(selection);
  }

  void hover(const LinkMatch *match) {
    configuration_.theme.accent = cursor_text_color;
    item_.hover(match);
  }

  [[nodiscard]] static int bluePixels(const QImage &image) {
    int count = 0;
    for (int row = 0; row < image.height(); ++row) {
      for (int column = 0; column < image.width(); ++column) {
        const auto color = image.pixelColor(column, row);
        constexpr int minimum_blue = 150;
        constexpr int maximum_red = 120;
        if (color.blue() > minimum_blue && color.red() < maximum_red && color.blue() > color.green()) {
          ++count;
        }
      }
    }

    return count;
  }

  [[nodiscard]] QSizeF cellSize() const noexcept {
    return font_.cell;
  }

  [[nodiscard]] qreal scale() const {
    return window_.devicePixelRatio();
  }

  void useWhiteTextOnBlack() {
    constexpr auto white = Color::rgb(0xffffff);
    configuration_.theme.background = Color::rgb(0);
    configuration_.theme.foreground = white;
    window_.setColor(Qt::black);
    item_.invalidateAppearance();
  }

  void setRasterPixelHeight(std::uint16_t height) {
    item_.setRasterPixelHeight(height);
  }

  [[nodiscard]] QImage glyphReference(QSize size, fonts::GlyphStyle style) const {
    const auto source = ResidentFonts::resolveSource({}, {});
    fonts::Face face{source->bytes(), source->match()};
    const auto run = face.shape("M", resolved_.grid.pixel_height);
    if (run.size() != 1) {
      throw std::runtime_error{"The mask fixture requires one glyph"};
    }

    const auto glyph = run.glyph(0);
    const auto bitmap = face.rasterize({.index = glyph.index, .pixel_height = resolved_.grid.pixel_height, .style = style});
    const auto left = FontMetrics::roundFixed(glyph.x_offset) + bitmap.left;
    const auto top = static_cast<int>(std::round(font_.baseline * scale())) - FontMetrics::roundFixed(glyph.y_offset) - bitmap.top;
    QImage expected{size, QImage::Format_RGB32};
    expected.fill(Qt::black);
    for (std::uint32_t row = 0; row < bitmap.height; ++row) {
      const auto coverage = bitmap.row(row);
      for (std::uint32_t column = 0; column < bitmap.width; ++column) {
        const QPoint point{left + static_cast<int>(column), top + static_cast<int>(row)};
        if (expected.rect().contains(point)) {
          const auto value = coverage[column];
          expected.setPixel(point, qRgb(value, value, value));
        }
      }
    }

    return expected;
  }

private:
  void resizeWindow() {
    window_.resize(static_cast<int>(std::ceil(item_.width())), static_cast<int>(std::ceil(item_.height())));
  }

  void waitForExposure() {
    if (!QTest::qWaitForWindowExposed(&window_)) {
      throw std::runtime_error{"Scene test window was not exposed"};
    }
  }

  ApplicationAllocator memory_;
  GraphicsBudget budget_;
  Screen<ApplicationAllocator> screen_;
  GraphicsStore<ApplicationAllocator> graphics_;
  Configuration configuration_;
  QString preedit_;
  QQuickWindow window_;
  ResolvedFont resolved_;
  TerminalFont font_;
  SceneItem item_;
  std::uint64_t frame_id_ = 0;
};

class SceneTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void changingTextAndInlineDecorationsMatchesFreshRows_data() {
    QTest::addColumn<bool>("optical");
    QTest::newRow("standard") << false;
    QTest::newRow("optical") << true;
  }

  Q_SLOT static void changingTextAndInlineDecorationsMatchesFreshRows() {
    QFETCH(bool, optical);
    constexpr std::array<std::string_view, 5> contents{"ffi!=->M", "ABCDEFGH", "        ", "01234567", "ffi!=->M"};
    constexpr std::size_t columns = 8;
    constexpr unsigned underline_shift = 8;
    SceneFixture fixture{CursorShape::block, false};
    fixture.useWhiteTextOnBlack();
    fixture.setFontRendering(optical, FontConfiguration::maximum_thicken_strength);
    for (std::size_t variant = 0; variant < contents.size(); ++variant) {
      std::array<Byte, columns> text{};
      std::array<Cell, columns> cells;
      for (std::size_t column = 0; column < columns; ++column) {
        text[column] = static_cast<Byte>(contents[variant][column]);
        CellStyle style;
        if (variant % 2 != 0) {
          style.flags = static_cast<std::uint16_t>(column % 2 == 0 ? CellAttribute::bold : CellAttribute::italic);
          style.flags |= static_cast<std::uint16_t>(CellAttribute::strikethrough);
          style.flags |= static_cast<std::uint16_t>(static_cast<unsigned>(UnderlineStyle::curly) << underline_shift);
        }

        cells[column] = {.style = style, .text = std::span{text}.subspan(column, 1)};
      }

      fixture.setCells(cells, {.visible = false, .shape = CursorShape::block});
      const auto retained = fixture.capture();
      SceneFixture reference{CursorShape::block, false};
      reference.useWhiteTextOnBlack();
      reference.setFontRendering(optical, FontConfiguration::maximum_thicken_strength);
      reference.setCells(cells, {.visible = false, .shape = CursorShape::block});
      QCOMPARE(retained, reference.capture());
    }
  }

  Q_SLOT static void viewportResizeExcludesHiddenLigatureContextWithoutCellDamage() {
    SceneFixture fixture{CursorShape::block, false};
    std::array<Byte, 4> text{'=', '=', '=', '='};
    std::array<Cell, 4> cells;
    for (std::size_t index = 0; index < cells.size(); ++index) {
      cells[index].text = std::span{text}.subspan(index, 1);
    }

    fixture.setCells(cells, {});
    const auto complete = fixture.capture();
    const auto revision = fixture.rowRevision();
    constexpr std::uint16_t visible_columns = 2;
    fixture.setVisibleColumns(visible_columns);
    const auto clipped = fixture.capture();
    QCOMPARE(fixture.rowRevision(), revision);

    SceneFixture reference{CursorShape::block, false};
    reference.setCells(std::span{cells}.first(visible_columns), {});
    QCOMPARE(clipped, reference.capture());
    fixture.setVisibleColumns(static_cast<std::uint16_t>(cells.size()));
    QCOMPARE(fixture.capture(), complete);
  }

  Q_SLOT static void blinkingCursorMovesRebuildLigaturesWithoutCellDamage() {
    SceneFixture fixture{CursorShape::block};
    std::array<Byte, 4> text{'=', '=', '=', ' '};
    std::array<Cell, 4> cells;
    for (std::size_t index = 0; index < cells.size(); ++index) {
      cells[index].text = std::span{text}.subspan(index, 1);
    }

    fixture.setCells(cells, {.visible = true, .shape = CursorShape::block});
    fixture.setCursorOn(false);
    const auto split = fixture.capture();
    const auto revision = fixture.rowRevision();
    constexpr std::uint16_t after_ligature = 3;
    fixture.moveCursor(after_ligature);
    QCOMPARE(fixture.rowRevision(), revision);
    const auto retained = fixture.capture();
    fixture.invalidateAppearance();
    QCOMPARE(fixture.capture(), retained);
    QVERIFY(retained != split);
  }

  Q_SLOT static void regularAndSyntheticStylesUseOriginalGlyphMasks() {
    SceneFixture fixture{CursorShape::block, false};
    fixture.useWhiteTextOnBlack();
    constexpr auto bold_flag = static_cast<std::uint16_t>(CellAttribute::bold);
    constexpr auto italic_flag = static_cast<std::uint16_t>(CellAttribute::italic);
    constexpr std::array flags{std::uint16_t{0}, bold_flag, italic_flag, static_cast<std::uint16_t>(bold_flag | italic_flag)};
    for (const auto value : flags) {
      CellStyle style;
      style.flags = value;
      fixture.setCell(style, CursorShape::block, false, "M");
      auto actual = fixture.capture().convertToFormat(QImage::Format_RGB32);
      actual.setDevicePixelRatio(1);
      const auto expected = fixture.glyphReference(actual.size(), {.bold = (value & bold_flag) != 0, .italic = (value & italic_flag) != 0});
      QCOMPARE(actual, expected);
    }
  }

  Q_SLOT static void oversizedGlyphFallsBackWithoutDiscardingCell() {
    SceneFixture fixture{CursorShape::block, false};
    const auto blank = fixture.capture();
    constexpr std::uint16_t oversized_raster_height = 4096;
    fixture.setRasterPixelHeight(oversized_raster_height);
    fixture.setCell(plain_style, CursorShape::block, false, "M");
    QVERIFY(fixture.capture() != blank);
  }

  Q_SLOT static void malformedUtf8UsesReplacementGlyph() {
    SceneFixture fixture{CursorShape::block, false};
    fixture.setCell(plain_style, CursorShape::block, false, "\ufffd");
    const auto replacement = fixture.capture();
    fixture.setCell(plain_style, CursorShape::block, false, "\xff");
    QCOMPARE(fixture.capture(), replacement);
  }

  Q_SLOT static void boxInkUsesProvidedPhysicalFontMetrics() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF cell{32, 32};
    fixture.resizeCell(cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2500");
    constexpr qreal offset = 2;
    QCOMPARE(fixture.pixel(fixture.capture(), cell.width() / 2, (cell.height() / 2) + offset), toQColor(background_color));
    constexpr qreal logical_stroke = 8;
    fixture.setBoxStroke(static_cast<float>(logical_stroke * fixture.scale()));
    QCOMPARE(fixture.pixel(fixture.capture(), cell.width() / 2, (cell.height() / 2) + offset), toQColor(cursor_color));
  }

  Q_SLOT static void fontSmoothingSelectsOpticalMasksWithoutChangingTheGrid() {
    SceneFixture fixture{CursorShape::block, false};
    fixture.setCell(plain_style, CursorShape::block, false, "M");
    const auto cell = fixture.cellSize();
    const auto plain = fixture.capture();
    fixture.setFontRendering(false, 0);
    QCOMPARE(fixture.capture(), plain);
    fixture.setFontRendering(true, 0);
    const auto light = fixture.capture();
    fixture.setFontRendering(true, FontConfiguration::maximum_thicken_strength);
    const auto strong = fixture.capture();
    QCOMPARE(fixture.cellSize(), cell);
    QCOMPARE(strong.size(), plain.size());
#ifdef Q_OS_MACOS
    QVERIFY(plain != light || plain != strong);
#else
    QCOMPARE(light, plain);
    QCOMPARE(strong, plain);
#endif
    QCOMPARE(fixture.capture(), strong);
    fixture.setFontRendering(false, 0);
    QCOMPARE(fixture.capture(), plain);
  }

  Q_SLOT static void cursorAndPreeditShareFontSmoothing() {
    SceneFixture fixture{CursorShape::block};
    fixture.setCursorTextColor(cursor_text_color);
    fixture.setCell(plain_style, CursorShape::block, true, "M");
    const auto default_cursor = fixture.capture();
    fixture.setFontRendering(true, 0);
    const auto light_cursor = fixture.capture();
    fixture.setFontRendering(true, FontConfiguration::maximum_thicken_strength);
    const auto strong_cursor = fixture.capture();
#ifdef Q_OS_MACOS
    QVERIFY(default_cursor != light_cursor || default_cursor != strong_cursor);
#else
    QCOMPARE(default_cursor, light_cursor);
    QCOMPARE(light_cursor, strong_cursor);
#endif
    fixture.setCell(plain_style, CursorShape::block, false);
    fixture.setPreedit(QStringLiteral("M"));
    const auto strong_preedit = fixture.capture();
    fixture.setFontRendering(true, 0);
    const auto light_preedit = fixture.capture();
    fixture.setFontRendering(false, 0);
    const auto default_preedit = fixture.capture();
#ifdef Q_OS_MACOS
    QVERIFY(default_preedit != light_preedit || default_preedit != strong_preedit);
#else
    QCOMPARE(default_preedit, light_preedit);
    QCOMPARE(light_preedit, strong_preedit);
#endif
  }

  Q_SLOT static void proceduralInkIgnoresFontSmoothing() {
    SceneFixture fixture{CursorShape::block};
    fixture.setCursorTextColor(cursor_text_color);
    for (const auto *const text : {"\u28ff", "\u2588", "\u2500", "\u256d", "\u2573"}) {
      fixture.setFontRendering(false, 0);
      fixture.setCell(plain_style, CursorShape::block, true, text);
      const auto original = fixture.capture();
      fixture.setFontRendering(true, FontConfiguration::maximum_thicken_strength);
      QCOMPARE(fixture.capture(), original);
    }
  }

  Q_SLOT static void boxStrokeUsesDesignMetricsAtDisplayScale() {
    const auto font = TerminalFont::resolve(QVariantMap{}, 1);
    constexpr qreal quadrupled_scale = 4;
    constexpr float expected_thickness = 3;
    constexpr float doubled_thickness = 2;
    QCOMPARE(BoxFont::thickness(font.faces.front(), 1), 1.0F);
    QCOMPARE(BoxFont::thickness(font.faces.front(), 2), doubled_thickness);
    QCOMPARE(BoxFont::thickness(font.faces.front(), quadrupled_scale), expected_thickness);
  }

  Q_SLOT static void boxStrokesUseCompleteCellAndUnicodeWeight() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2500");
    const auto original = fixture.capture();
    QCOMPARE(fixture.pixel(original, expanded_cell.width() - 1, expanded_cell.height() / 2), toQColor(cursor_color));
    CellStyle style;
    style.flags = static_cast<std::uint16_t>(CellAttribute::bold) | static_cast<std::uint16_t>(CellAttribute::italic);
    fixture.setCell(style, CursorShape::block, false, "\u2500");
    QCOMPARE(fixture.capture(), original);
    style.flags = static_cast<std::uint16_t>(CellAttribute::faint);
    fixture.setCell(style, CursorShape::block, false, "\u253c");
    const auto cross = fixture.capture();
    QCOMPARE(fixture.pixel(cross, expanded_cell.width() / 2, expanded_cell.height() / 2), fixture.pixel(cross, expanded_cell.width() - 1, expanded_cell.height() / 2));
  }

  Q_SLOT static void roundedCornersReachTheirCellEdges() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSize expanded_pixels{27, 51};
    fixture.resizePhysicalCell(expanded_pixels);
    fixture.setCell(plain_style, CursorShape::block, false, "\u256d");
    const auto image = fixture.capture();
    QCOMPARE(image.pixelColor(expanded_pixels.width() / 2, expanded_pixels.height() - 1), toQColor(cursor_color));
    QVERIFY(image.pixelColor(expanded_pixels.width() - 1, expanded_pixels.height() / 2).green() > toQColor(background_color).green());
    QCOMPARE(image.pixelColor(0, 0), toQColor(background_color));
    CellStyle style;
    style.flags = static_cast<std::uint16_t>(CellAttribute::bold) | static_cast<std::uint16_t>(CellAttribute::italic);
    fixture.setCell(style, CursorShape::block, false, "\u256d");
    QCOMPARE(fixture.capture(), image);
  }

  Q_SLOT static void diagonalMasksKeepOrientationAndCursorColor() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF square_cell{32, 32};
    fixture.resizeCell(square_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2571");
    const auto rising = fixture.capture();
    const auto last_column = square_cell.width() - (0.5 / fixture.scale());
    const auto last_row = square_cell.height() - (0.5 / fixture.scale());
    QCOMPARE(fixture.pixel(rising, 0, last_row), toQColor(cursor_color));
    QCOMPARE(fixture.pixel(rising, last_column, 0), toQColor(cursor_color));
    QCOMPARE(fixture.pixel(rising, 0, 0), toQColor(background_color));
    fixture.setCursorTextColor(cursor_text_color);
    fixture.setCell(plain_style, CursorShape::block, true, "\u2572");
    const auto falling = fixture.capture();
    QCOMPARE(fixture.pixel(falling, 0, 0), toQColor(cursor_text_color));
    QCOMPARE(fixture.pixel(falling, last_column, last_row), toQColor(cursor_text_color));
    QCOMPARE(fixture.pixel(falling, 0, last_row), toQColor(cursor_color));
  }

  Q_SLOT static void oversizedCurvesKeepProceduralFallback() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF oversized_cell{512, 512};
    fixture.resizeCell(oversized_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2573");
    const auto image = fixture.capture();
    const auto last_column = oversized_cell.width() - (0.5 / fixture.scale());
    const auto last_row = oversized_cell.height() - (0.5 / fixture.scale());
    QVERIFY(fixture.pixel(image, last_column, 0).green() > toQColor(background_color).green());
    QVERIFY(fixture.pixel(image, last_column, last_row).green() > toQColor(background_color).green());
    QCOMPARE(fixture.pixel(image, oversized_cell.width() / 2, 0), toQColor(background_color));
  }

  Q_SLOT static void curveRasterLimitSelectsReservedMask() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr qreal largest_exact_extent = 256;
    const auto exact_extent = largest_exact_extent / fixture.scale();
    fixture.resizeCell({exact_extent, exact_extent});
    fixture.setCell(plain_style, CursorShape::block, false, "\u2573");
    QCOMPARE(fixture.pixel(fixture.capture(), 0, 0), toQColor(cursor_color));
    const auto oversized_extent = (largest_exact_extent + 1) / fixture.scale();
    const QSizeF oversized_cell{oversized_extent, oversized_extent};
    fixture.resizeCell(oversized_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2573");
    const auto image = fixture.capture();
    const auto corner = fixture.pixel(image, 0, 0);
    QVERIFY(corner.green() > toQColor(background_color).green() && corner.green() < toQColor(cursor_color).green());
    const auto last_column = oversized_cell.width() - (0.5 / fixture.scale());
    const auto last_row = oversized_cell.height() - (0.5 / fixture.scale());
    QVERIFY(fixture.pixel(image, last_column, 0).green() > toQColor(background_color).green());
    QVERIFY(fixture.pixel(image, last_column, last_row).green() > toQColor(background_color).green());
    QCOMPARE(fixture.pixel(image, oversized_cell.width() / 2, 0), toQColor(background_color));
  }

  Q_SLOT static void curveMasksSurviveRetainedCursorAndResize() {
    SceneFixture fixture{CursorShape::block};
    fixture.setCursorTextColor(cursor_text_color);
    constexpr QSizeF original_cell{32, 32};
    fixture.resizeCell(original_cell);
    fixture.setCell(plain_style, CursorShape::block, true, "\u2573");
    const auto original = fixture.capture();
    constexpr qreal oversized_physical_extent = 257;
    const auto fallback_extent = oversized_physical_extent / fixture.scale();
    for (const auto size : {QSizeF{fallback_extent, fallback_extent}, QSizeF{24, 48}, original_cell}) {
      fixture.resizeCell(size);
      const auto image = fixture.capture();
      QVERIFY(SceneFixture::bluePixels(image) > 0);
      QCOMPARE(fixture.pixel(image, size.width() / 2, 0), toQColor(cursor_color));
    }

    QCOMPARE(fixture.capture(), original);
  }

  Q_SLOT static void faintCurveIntersectionsBlendOnce() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF square_cell{32, 32};
    fixture.resizeCell(square_cell);
    CellStyle style;
    style.flags = static_cast<std::uint16_t>(CellAttribute::faint);
    fixture.setCell(style, CursorShape::block, false, "\u2573");
    const auto image = fixture.capture();
    const auto center = fixture.pixel(image, square_cell.width() / 2, square_cell.height() / 2);
    QCOMPARE(center, fixture.pixel(image, 0, 0));
    constexpr int expected_green = 110;
    constexpr int channel_tolerance = 1;
    QVERIFY(std::abs(center.green() - expected_green) <= channel_tolerance);
  }

  Q_SLOT static void fullBlockFillsConfiguredCell() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2588");
    const auto image = fixture.capture();
    QVERIFY(!image.isNull());
    QCOMPARE(fixture.pixel(image, 1, 1), toQColor(cursor_color));
    QCOMPARE(fixture.pixel(image, expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(cursor_color));
    CellStyle style;
    style.flags = static_cast<std::uint16_t>(CellAttribute::bold) | static_cast<std::uint16_t>(CellAttribute::italic);
    fixture.setCell(style, CursorShape::block, false, "\u2588");
    QCOMPARE(fixture.capture(), image);
  }

  Q_SLOT static void halfBlocksUseWholeCellGeometry() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2580");
    const auto upper = fixture.capture();
    QCOMPARE(fixture.pixel(upper, expanded_cell.width() - 1, 1), toQColor(cursor_color));
    QCOMPARE(fixture.pixel(upper, expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(background_color));
    fixture.setCell(plain_style, CursorShape::block, false, "\u2584");
    const auto lower = fixture.capture();
    QCOMPARE(fixture.pixel(lower, expanded_cell.width() - 1, 1), toQColor(background_color));
    QCOMPARE(fixture.pixel(lower, expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(cursor_color));
  }

  Q_SLOT static void shadesBlendAcrossWholeCell() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    constexpr auto shade_coverage = 0.25F;
    constexpr auto faint_opacity = 0.5F;
    for (const auto faint : {false, true}) {
      CellStyle style;
      style.flags = faint ? static_cast<std::uint16_t>(CellAttribute::faint) : 0;
      fixture.setCell(style, CursorShape::block, false, "\u2591");
      const auto image = fixture.capture();
      const auto color = fixture.pixel(image, 1, 1);
      QCOMPARE(color, fixture.pixel(image, expanded_cell.width() - 1, expanded_cell.height() - 1));
      const auto coverage = shade_coverage * (faint ? faint_opacity : 1);
      const QColor expected = QColor::fromRgbF((cursor_color.r * coverage) + (background_color.r * (1 - coverage)), (cursor_color.g * coverage) + (background_color.g * (1 - coverage)), (cursor_color.b * coverage) + (background_color.b * (1 - coverage)));
      constexpr int channel_tolerance = 1;
      QVERIFY(std::abs(color.red() - expected.red()) <= channel_tolerance);
      QVERIFY(std::abs(color.green() - expected.green()) <= channel_tolerance);
      QVERIFY(std::abs(color.blue() - expected.blue()) <= channel_tolerance);
    }
  }

  Q_SLOT static void brailleUsesCellGridAndKeepsDecorations() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{16, 32};
    fixture.resizeCell(expanded_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2801");
    const auto image = fixture.capture();
    QCOMPARE(fixture.pixel(image, 3, 3), toQColor(cursor_color));
    QCOMPARE(fixture.pixel(image, 11, 3), toQColor(background_color));
    QCOMPARE(fixture.pixel(image, 3, 27), toQColor(background_color));
    fixture.setCell(plain_style, CursorShape::block, false, "\u2800");
    const auto blank = fixture.capture();
    QCOMPARE(fixture.pixel(blank, 3, 3), toQColor(background_color));
    CellStyle style;
    style.flags = static_cast<std::uint16_t>(CellAttribute::strikethrough) | static_cast<std::uint16_t>(CellAttribute::overline);
    fixture.setCell(style, CursorShape::block, false, " ");
    const auto decorated_space = fixture.capture();
    QVERIFY(decorated_space != blank);
    fixture.setCell(style, CursorShape::block, false, "\u2800");
    QCOMPARE(fixture.capture(), decorated_space);
  }

  Q_SLOT static void blockCursorRepaintsProceduralInk() {
    SceneFixture fixture{CursorShape::block};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    fixture.setCursorTextColor(cursor_text_color);
    fixture.setCell(plain_style, CursorShape::block, true, "\u2580");
    const auto image = fixture.capture();
    QCOMPARE(fixture.pixel(image, expanded_cell.width() - 1, 1), toQColor(cursor_text_color));
    QCOMPARE(fixture.pixel(image, expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(cursor_color));
  }

  Q_SLOT static void combiningMarksKeepTextShaping() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2588\u0301");
    const auto image = fixture.capture();
    QCOMPARE(fixture.pixel(image, expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(background_color));
  }

  Q_SLOT static void underlinesRemainAboveProceduralInk() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    constexpr unsigned underline_shift = 8;
    constexpr std::array<Byte, 3> blue_channels{0x33, 0x66, 0xff};
    for (const auto underline : {UnderlineStyle::single, UnderlineStyle::double_line, UnderlineStyle::curly, UnderlineStyle::dotted, UnderlineStyle::dashed}) {
      CellStyle style;
      style.flags = static_cast<std::uint16_t>(static_cast<unsigned>(underline) << underline_shift);
      style.underline_color = {.kind = CellColor::Kind::rgb, .channels = blue_channels};
      fixture.setCell(style, CursorShape::block, false, "\u2588");
      QVERIFY2(SceneFixture::bluePixels(fixture.capture()) > 0, qPrintable(QStringLiteral("Underline style %1 must stay visible").arg(static_cast<unsigned>(underline))));
    }
  }

  Q_SLOT static void proceduralInkKeepsSelectionInverseAndConcealment() {
    SceneFixture fixture{CursorShape::block, false};
    constexpr QSizeF expanded_cell{27, 51};
    fixture.resizeCell(expanded_cell);
    fixture.setCell(plain_style, CursorShape::block, false, "\u2580");
    fixture.select({.anchor = 0, .head = 0});
    QCOMPARE(fixture.pixel(fixture.capture(), expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(cursor_color));
    fixture.select(no_selection);
    CellStyle style;
    style.flags = static_cast<std::uint16_t>(CellAttribute::inverse);
    fixture.setCell(style, CursorShape::block, false, "\u2580");
    const auto inverted = fixture.capture();
    QCOMPARE(fixture.pixel(inverted, expanded_cell.width() - 1, 1), toQColor(background_color));
    QCOMPARE(fixture.pixel(inverted, expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(cursor_color));
    style.flags = static_cast<std::uint16_t>(CellAttribute::invisible);
    fixture.setCell(style, CursorShape::block, false, "\u2588");
    const auto concealed = fixture.capture();
    QCOMPARE(fixture.pixel(concealed, expanded_cell.width() - 1, 1), toQColor(background_color));
    QCOMPARE(fixture.pixel(concealed, expanded_cell.width() - 1, expanded_cell.height() - 1), toQColor(background_color));
  }

  Q_SLOT static void hoverUnderlineDoesNotChangeRetainedText() {
    SceneFixture fixture{CursorShape::block, false};
    const auto target = requireLinkTarget("https://underline.test");
    const LinkMatch match{.target = target, .start = origin, .end = {.x = 1}};
    const auto original = fixture.capture();
    QCOMPARE(SceneFixture::bluePixels(original), 0);
    fixture.hover(&match);
    QVERIFY(SceneFixture::bluePixels(fixture.capture()) > 0);
    fixture.hover(nullptr);
    QCOMPARE(fixture.capture(), original);
  }

  Q_SLOT static void linkPreviewWrapsAndClipsWithinItsPane() {
    constexpr float pane_width = 200;
    constexpr float pane_height = 600;
    constexpr float cell_width = 8;
    constexpr float cell_height = 16;
    constexpr std::size_t long_path_size = 1000;
    const auto target = requireLinkTarget("https://preview.test/" + std::string(long_path_size, 'x'));
    const LinkHit hit{.location = no_location, .content = {.width = pane_width, .height = pane_height}, .area = {.width = cell_width, .height = cell_height}, .match = {.target = target, .start = origin, .end = origin}};
    const TerminalSurface surface{.content = hit.content, .cell = {.x = cell_width, .y = cell_height}};
    const TerminalFont font = TerminalFont::resolve(QVariantMap{}, 1);
    const auto preview = LinkPreview::layout(hit, surface, font.faces.front(), 1);
    if (!preview) {
      QFAIL("The valid scene fixture must produce a link preview");
    }
    QCOMPARE(preview->lines.size(), LinkPreview::maximum_rows);
    QVERIFY(preview->lines.back().endsWith(QChar{u'\u2026'}));
    QVERIFY((QRectF{0, 0, pane_width, pane_height}.contains(preview->bounds)));
    auto invalid = surface;
    invalid.cell.y = 0;
    QVERIFY(!LinkPreview::layout(hit, invalid, font.faces.front(), 1));
    invalid = surface;
    invalid.content.height = cell_height;
    QVERIFY(!LinkPreview::layout(hit, invalid, font.faces.front(), 1));
  }

  Q_SLOT static void blockCursorIsOpaque() {
    SceneFixture fixture{CursorShape::block};
    const auto image = fixture.capture();
    QVERIFY(!image.isNull());
    const auto cell = fixture.cellSize();
    QCOMPARE(fixture.pixel(image, cell.width() / 2, cell.height() / 2), toQColor(cursor_color));
  }

  Q_SLOT static void inactiveWindowCursorIsHollow() {
    SceneFixture fixture{CursorShape::block};
    fixture.setKeyboard(false);
    const auto image = fixture.capture();
    QVERIFY(!image.isNull());
    const auto cell = fixture.cellSize();
    QCOMPARE(fixture.pixel(image, cell.width() / 2, cell.height() / 2), toQColor(background_color));
    QCOMPARE(fixture.pixel(image, 0, cell.height() / 2), toQColor(cursor_color));
  }

  Q_SLOT static void unfocusedPaneHasNoCursor() {
    SceneFixture fixture{CursorShape::block};
    fixture.setPaneFocused(false);
    const auto image = fixture.capture();
    QVERIFY(!image.isNull());
    const auto cell = fixture.cellSize();
    QCOMPARE(fixture.pixel(image, 0, cell.height() / 2), toQColor(background_color));
    QCOMPARE(fixture.pixel(image, cell.width() / 2, cell.height() / 2), toQColor(background_color));
  }

  Q_SLOT static void underlineVariantsUseOriginalSingleRule() {
    SceneFixture fixture{CursorShape::block, false};
    CellStyle style;
    constexpr unsigned underline_shift = 8;
    style.flags = static_cast<std::uint16_t>(static_cast<unsigned>(UnderlineStyle::double_line) << underline_shift);
    fixture.setCell(style, CursorShape::block, false);
    const auto image = fixture.capture();
    QVERIFY(!image.isNull());
    int bands = 0;
    bool previous_green = false;
    const auto cell = fixture.cellSize();
    const auto sample_rows = static_cast<int>(cell.height() * fixture.scale());
    for (int row = 0; row < sample_rows; ++row) {
      const auto color = fixture.pixel(image, cell.width() / 2, row / fixture.scale());
      constexpr int minimum_green = 150;
      constexpr int maximum_red = 100;
      const auto green = color.green() > minimum_green && color.red() < maximum_red;
      if (green && !previous_green) {
        ++bands;
      }
      previous_green = green;
    }

    QCOMPARE(bands, 1);
    for (const auto variant : {UnderlineStyle::single, UnderlineStyle::curly, UnderlineStyle::dotted, UnderlineStyle::dashed}) {
      style.flags = static_cast<std::uint16_t>(static_cast<unsigned>(variant) << underline_shift);
      fixture.setCell(style, CursorShape::block, false);
      QCOMPARE(fixture.capture(), image);
    }
  }

  Q_SLOT static void cursorUsesConfiguredTextColor() {
    SceneFixture fixture{CursorShape::block};
    fixture.setCursorTextColor(cursor_text_color);
    fixture.setCell(plain_style, CursorShape::block, true, "M");
    const auto image = fixture.capture();
    QVERIFY(!image.isNull());
    QVERIFY(SceneFixture::bluePixels(image) > 0);
  }

  Q_SLOT static void cursorDoesNotRevealInvisibleText() {
    SceneFixture fixture{CursorShape::block};
    fixture.setCursorTextColor(cursor_text_color);
    CellStyle style;
    style.flags = static_cast<std::uint16_t>(CellAttribute::invisible);
    fixture.setCell(style, CursorShape::block, true, "M");
    const auto image = fixture.capture();
    QVERIFY(!image.isNull());
    QCOMPARE(SceneFixture::bluePixels(image), 0);
  }

  Q_SLOT static void selectionInvalidatesRetainedRow() {
    SceneFixture fixture{CursorShape::block, false};
    const auto cell = fixture.cellSize();
    QCOMPARE(fixture.pixel(fixture.capture(), cell.width() / 2, cell.height() / 2), toQColor(background_color));
    fixture.select({.anchor = 0, .head = 0});
    QCOMPARE(fixture.pixel(fixture.capture(), cell.width() / 2, cell.height() / 2), toQColor(cursor_color));
    fixture.select(no_selection);
    QCOMPARE(fixture.pixel(fixture.capture(), cell.width() / 2, cell.height() / 2), toQColor(background_color));
  }

  // NOLINTNEXTLINE(readability-identifier-naming): Qt requires the _data suffix.
  Q_SLOT static void rowBackgroundsMatchIndependentRectangles_data() {
    QTest::addColumn<BackgroundPattern>("pattern");
    QTest::newRow("uniform") << BackgroundPattern::uniform;
    QTest::newRow("alternating") << BackgroundPattern::alternating;
    QTest::newRow("default-gaps") << BackgroundPattern::default_gaps;
    QTest::newRow("selection-inverse") << BackgroundPattern::selection_inverse;
    QTest::newRow("wide-overlap") << BackgroundPattern::wide_overlap;
    QTest::newRow("translucent-wide-overlap") << BackgroundPattern::translucent_wide_overlap;
    QTest::newRow("clipped-wide") << BackgroundPattern::clipped_wide;
  }

  Q_SLOT static void rowBackgroundsMatchIndependentRectangles() {
    QFETCH(const BackgroundPattern, pattern);
    constexpr qreal cell_height = 21;
    constexpr float translucent_alpha = 0.5F;
    const auto first_color = Color::rgb(0xdc3020, pattern == BackgroundPattern::translucent_wide_overlap ? translucent_alpha : 1);
    for (const auto width : {9.0, 9.2, 9.1}) {
      SceneFixture fixture{CursorShape::block, false};
      fixture.resizeCell({width, cell_height});
      fixture.setPaletteColor(0, first_color);
      fixture.setPaletteColor(1, background_blue);
      auto row = backgroundRow(pattern, first_color);
      fixture.setCells(row.cells, {.visible = false});
      if (pattern == BackgroundPattern::selection_inverse) {
        fixture.select({.anchor = background_selection_start, .head = background_selection_end});
      }

      if (pattern == BackgroundPattern::clipped_wide) {
        fixture.setVisibleColumns(background_columns - 1);
        row.rectangles.pop_back();
      }

      fixture.referenceBackgrounds(row.rectangles);
      const auto expected = fixture.capture();
      fixture.referenceBackgrounds(std::nullopt);
      QVERIFY2(fixture.capture() == expected, qPrintable(QStringLiteral("Background pixels differ at cell width %1 and scale %2").arg(width).arg(fixture.scale())));
      fixture.invalidateAppearance();
      QVERIFY2(fixture.capture() == expected, qPrintable(QStringLiteral("Background pixels differ at cell width %1 and scale %2").arg(width).arg(fixture.scale())));
    }
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  bundledFonts();
  SceneTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "scene_test.moc"
