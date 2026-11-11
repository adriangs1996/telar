#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../application/dependencies.hpp"
#include "assertions.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <optional>
#include <span>
#include "telar_client/serializers/telar_messages.hpp"
#include <string_view>
#include <tuple>
#include <utility>
#include "../core/memory.hpp"
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "../platform/window.hpp"
#include "../qt/graphics_scene.hpp"
#include "../qt/scene_nodes.hpp"
#include "../qt/window_images.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "../terminal/screen.hpp"
#include <QColor>
#include <QDir>
#include <QGuiApplication>
#include <QImage>
#include <QObject>
#include <QPoint>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGNode>
#include <QSGRendererInterface>
#include <QSGTransformNode>
#include <QSizeF>
#include <QString>
#include <QTimer>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qtestsupport_gui.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <vector>

#include "application/dependencies.hpp"
#include "platform/window.hpp"
#include "qt/graphics_scene.hpp"
#include "qt/scene_nodes.hpp"
#include "qt/window_images.hpp"
#include "terminal/screen.hpp"


import telar.gui.graphics.texture_cache;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using telar::gui::test::require;

constexpr int wait_ms = 5000;
constexpr int cell_side = 32;
constexpr int window_side = cell_side * 2;
constexpr int pixel_channels = 4;
constexpr int rgb_channels = 3;
constexpr GraphicsHeader header{.pane_id = 1, .revision = 1};
constexpr QColor red{255, 0, 0};
constexpr QColor blue{0, 0, 255};
constexpr QColor green{0, 255, 0};
constexpr QColor yellow{255, 255, 0};

class ImageNode final : public QSGNode {
public:
  ImageNode()
      : below_background_(appendSceneNode<QSGTransformNode>(*this)),
        below_text_(appendSceneNode<QSGTransformNode>(*this)),
        above_text_(appendSceneNode<QSGTransformNode>(*this)),
        images_({.below_background = &below_background_, .below_text = &below_text_, .above_text = &above_text_}) {}

  ~ImageNode() override {
    images_.clearNodes();
  }

  ImageNode(const ImageNode &) = delete;
  ImageNode &operator=(const ImageNode &) = delete;
  ImageNode(ImageNode &&) = delete;
  ImageNode &operator=(ImageNode &&) = delete;

  void synchronize(QQuickItem &owner, const GraphicsStore<ApplicationAllocator> &store, const Screen<ApplicationAllocator> &screen, QSizeF cell) {
    images_.synchronize(owner, store, ImageRows::of(screen, rows_), cell, owner.window()->devicePixelRatio());
  }

private:
  std::vector<std::span<const CellValue>> rows_;
  QSGTransformNode &below_background_;
  QSGTransformNode &below_text_;
  QSGTransformNode &above_text_;
  GraphicsScene images_;
};

class ImageItem final : public QQuickItem {
public:
  ImageItem(const std::optional<GraphicsStore<ApplicationAllocator>> &store, const Screen<ApplicationAllocator> &screen, QQuickItem &parent)
      : QQuickItem(&parent),
        store_(store),
        screen_(screen) {
    setFlag(ItemHasContents, true);
    setSize({window_side, window_side});
  }

  void setCellSize(QSizeF cell) {
    cell_ = cell;
    update();
  }

  [[nodiscard]] std::optional<ImagePlacementSource> source() noexcept {
    if (!store_) {
      return std::nullopt;
    }

    return ImagePlacementSource{.owner = this, .store = &*store_, .cell = cell_};
  }

protected:
  QSGNode *updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) override {
    std::unique_ptr<QSGNode> owned{previous};
    auto *node = dynamic_cast<ImageNode *>(owned.get());
    if (node == nullptr) {
      auto replacement = std::make_unique<ImageNode>();
      node = replacement.get();
      owned = std::move(replacement);
    }

    if (!store_) {
      return nullptr;
    }

    node->synchronize(*this, *store_, screen_, cell_);

    return owned.release();
  }

private:
  const std::optional<GraphicsStore<ApplicationAllocator>> &store_;
  const Screen<ApplicationAllocator> &screen_;
  QSizeF cell_{cell_side, cell_side};
};

class Fixture {
public:
  Fixture()
      : catalog_(std::in_place, memory_, budget_),
        screen_(memory_),
        item_(catalog_, screen_, *window_.contentItem()) {
    auto &images = WindowImages::forWindow(window_);
    QObject::connect(&window_, &QQuickWindow::afterAnimating, &window_, [this] {
      preparePlacements();
    });
    QObject::connect(&window_, &QQuickWindow::beforeSynchronizing, &window_, [this, &images] {
      images.beginCatalogSnapshot();
      std::vector<ImagePlacementSource> sources;
      collectSources(*window_.contentItem(), sources, false);
      for (const auto &source : sources) {
        images.observeCatalog(*source.store);
      }
    },
                     Qt::DirectConnection);
    QObject::connect(&window_, &QQuickWindow::afterSynchronizing, &window_, [this, &images] {
      statistics_ = images.statistics();
    },
                     Qt::DirectConnection);
    QObject::connect(&window_, &QQuickWindow::sceneGraphAboutToStop, &window_, [this, &images] {
      const auto sample = images.statistics();
      QTimer::singleShot(0, &window_, [this, sample] {
        if (sample.frame >= statistics_.frame) {
          statistics_ = sample;
        }
      });
    },
                     Qt::DirectConnection);
    platform::configureWindow(window_, {});
    window_.setColor(Qt::black);
    window_.resize(window_side, window_side);
    window_.show();
  }

  [[nodiscard]] GraphicsStore<ApplicationAllocator> &graphics() {
    if (!catalog_) {
      throw std::logic_error{"The image fixture requires its catalog"};
    }

    return *catalog_;
  }

  [[nodiscard]] QQuickWindow &window() noexcept {
    return window_;
  }

  void setImageVisible(bool visible) {
    item_.setVisible(visible);
  }

  void requestImageUpdate() {
    item_.update();
  }

  [[nodiscard]] GraphicsBudget &budget() noexcept {
    return budget_;
  }

  [[nodiscard]] WindowImageStatistics statistics() const noexcept {
    return statistics_;
  }

  [[nodiscard]] const std::optional<GraphicsStore<ApplicationAllocator>> &catalog() const noexcept {
    return catalog_;
  }

  void reconstructCatalog() {
    catalog_.emplace(memory_, budget_);
    item_.update();
  }

  ImageDescription begin(std::uint64_t generation, std::uint32_t width = 2, std::uint32_t height = 2, ImageFormat format = ImageFormat::rgba) {
    const auto channels = format == ImageFormat::rgb ? rgb_channels : pixel_channels;
    const ImageDescription image{.key = {.image_id = 1, .generation = generation}, .format = format, .width = width, .height = height, .byte_len = std::uint64_t{width} * height * static_cast<std::uint64_t>(channels)};
    graphics().image({.header = header, .image = image});

    return image;
  }

  void finishPattern(const ImageDescription &image, std::span<const QColor> pattern) {
    require(!pattern.empty(), "the image fixture must provide its pixel colors");
    const auto channels = image.format == ImageFormat::rgb ? rgb_channels : pixel_channels;
    std::vector<Byte> pixels(static_cast<std::size_t>(image.byte_len));
    for (std::size_t index = 0; index < pixels.size(); index += static_cast<std::size_t>(channels)) {
      const auto color = pattern[(index / static_cast<std::size_t>(channels)) % pattern.size()];
      pixels[index] = static_cast<Byte>(color.red());
      pixels[index + 1] = static_cast<Byte>(color.green());
      pixels[index + 2] = static_cast<Byte>(color.blue());
      if (image.format == ImageFormat::rgba) {
        pixels[index + 3] = static_cast<Byte>(color.alpha());
      }
    }

    graphics().chunk({.header = header, .key = image.key, .bytes = pixels});
  }

  void finish(const ImageDescription &image, QColor color) {
    const std::array pattern{color};
    finishPattern(image, pattern);
  }

  void place(const ImageDescription &image, bool square = true) {
    graphics().placement({.header = header, .placement = {.key = image.key, .virtual_id = 1, .columns = 2, .rows = square ? 2U : 0U}});
  }

  void setCapturePhase(QString phase) {
    capture_phase_ = std::move(phase);
  }

  QColor sample(QPoint logical) {
    const auto image = capture();
    const auto scale = window_.devicePixelRatio();

    return image.pixelColor(static_cast<int>(std::lround(logical.x() * scale)), static_cast<int>(std::lround(logical.y() * scale)));
  }

  QImage capture() {
    require(QTest::qWaitForWindowExposed(&window_, wait_ms), "the image fixture must expose its native window");
    preparePlacements();
    item_.update();
    const auto image = window_.grabWindow();
    require(!image.isNull(), "the image fixture must capture a rendered frame");
    const auto capture_directory = qEnvironmentVariable("TELAR_GUI_GRAPHICS_CAPTURE_DIR");
    if (!capture_directory.isEmpty()) {
      const QDir directory{capture_directory};
      require(directory.mkpath(QStringLiteral(".")), "the image fixture must create its capture directory");
      const auto suffix = capture_phase_.isEmpty() ? QString::number(++capture_index_) : capture_phase_;
      const auto name = QStringLiteral("%1-%2.png").arg(QString::fromLatin1(QTest::currentTestFunction()), suffix);
      require(image.save(directory.filePath(name)), "the image fixture must save its captured frame");
    }

    return image;
  }

  void placeholders() {
    constexpr std::array<std::string_view, 4> graphemes{"\xf4\x8e\xbb\xae\xcc\x85\xcc\x85", "\xf4\x8e\xbb\xae\xcc\x85\xcc\x8d", "\xf4\x8e\xbb\xae\xcc\x8d\xcc\x85", "\xf4\x8e\xbb\xae\xcc\x8d\xcc\x8d"};
    std::array<Cell, 4> cells;
    for (std::size_t index = 0; index < cells.size(); ++index) {
      cells[index].text = byteView(graphemes[index]);
      cells[index].style.foreground = {.kind = CellColor::Kind::rgb, .channels = {0, 0, 1}};
    }

    replaceScreen(cells, {.cols = 2, .rows = 2, .cell_width_px = 0, .cell_height_px = 0});
  }

  void replaceScreen(std::span<const Cell> cells, TerminalSize size) {
    std::vector<Byte> encoded(CellRunCodec::encodedSize(cells));
    const auto run = CellRunCodec::encode(cells, encoded);
    const std::array<FrameSpan, 1> spans{{{.start = 0, .count = static_cast<std::uint32_t>(cells.size()), .cells = run}}};
    const std::vector<Byte> flags(size.rows);
    PaneFrame frame;
    frame.pane_id = 1;
    frame.frame_id = screen_.frameId() + 1;
    frame.cols = size.cols;
    frame.rows = size.rows;
    frame.scroll.total_rows = size.rows;
    frame.spans = spans;
    frame.text_metadata = TextMetadata{.row_flags = flags};
    require(screen_.apply(frame) == FrameApplication::applied, "the placeholder fixture must apply its screen snapshot");
  }

  ApplicationAllocator memory_;
  GraphicsBudget budget_;
  std::optional<GraphicsStore<ApplicationAllocator>> catalog_;
  Screen<ApplicationAllocator> screen_;
  WindowImageStatistics statistics_;
  std::vector<LimitReach> placement_limits_;
  QQuickWindow window_;
  ImageItem item_;
  std::uint32_t capture_index_ = 0;
  QString capture_phase_;

private:
  void preparePlacements() {
    std::vector<ImagePlacementSource> sources;
    collectSources(*window_.contentItem(), sources, true);
    if (const auto reach = WindowImages::forWindow(window_).preparePlacements(sources)) {
      placement_limits_.push_back(*reach);
    }
  }

  static void collectSources(QQuickItem &parent, std::vector<ImagePlacementSource> &sources, bool visible_only) {
    std::vector<QQuickItem *> pending{&parent};
    while (!pending.empty()) {
      auto *item = pending.back();
      pending.pop_back();
      require(item != nullptr, "the image fixture tree must contain live items");
      if (visible_only && !item->isVisible()) {
        continue;
      }

      const auto children = item->childItems();
      pending.insert(pending.end(), children.crbegin(), children.crend());

      if (auto *view = dynamic_cast<ImageItem *>(item)) {
        if (const auto source = view->source()) {
          sources.push_back(*source);
        }
      }
    }
  }
};

bool closeColor(QColor actual, QColor expected) {
  constexpr int maximum_interpolation_error = 16;

  return std::abs(actual.red() - expected.red()) <= maximum_interpolation_error && std::abs(actual.green() - expected.green()) <= maximum_interpolation_error && std::abs(actual.blue() - expected.blue()) <= maximum_interpolation_error;
}

class GraphicsRetentionSceneTest : public QObject {
  Q_OBJECT

  // An image's row is drawn where the view draws it: from the view's top shown row, through the
  // folds, and nowhere while a fold hides it.
  Q_SLOT static void imageRowsFollowTheViewAndItsFolds() {
    constexpr std::uint32_t fold_first = 10;
    constexpr std::uint32_t fold_rows = 5;
    constexpr std::uint64_t top = 4;
    constexpr std::int64_t above = 6;
    constexpr std::int64_t below = 20;
    FoldMap<> folds;
    const std::array spans{FoldMap<>::Span{.first = fold_first, .count = fold_rows}};
    folds.assign(spans);
    const ImageRows plain{.top = top};
    QCOMPARE(plain.drawn(below), std::optional<std::int64_t>{below - static_cast<std::int64_t>(top)});
    const ImageRows folded{.top = top, .folds = &folds};
    QCOMPARE(folded.drawn(above), std::optional<std::int64_t>{above - static_cast<std::int64_t>(top)});
    QCOMPARE(folded.drawn(below), std::optional<std::int64_t>{below - fold_rows - static_cast<std::int64_t>(top)});
    QVERIFY(!folded.drawn(fold_first + 1));
    QCOMPARE(folded.drawn(-1), std::optional<std::int64_t>{-1 - static_cast<std::int64_t>(top)});
  }

  Q_SLOT static void highestPlacementsAreSelectedBeforeAnyUpload() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    fixture.placeholders();
    constexpr auto placements_per_view = GraphicsStore<ApplicationAllocator>::placement_capacity;
    constexpr auto view_count = (ImagePlacementSelection::capacity / placements_per_view) + 1;
    for (std::size_t index = 0; index < placements_per_view; ++index) {
      fixture.graphics().placement({.header = header, .placement = {.key = image.key, .virtual_id = index + 1, .columns = 2, .rows = 2, .z_index = std::numeric_limits<std::int32_t>::max(), .location = PlacementLocation::placeholders}});
    }

    std::array<std::optional<GraphicsStore<ApplicationAllocator>>, view_count - 1> catalogs;
    std::vector<std::unique_ptr<ImageItem>> views;
    for (std::size_t index = 1; index < view_count; ++index) {
      auto &catalog = catalogs[index - 1];
      catalog.emplace(fixture.memory_, fixture.budget_);
      catalog->image({.header = header, .image = image});
      catalog->chunk({.header = header, .key = image.key, .bytes = fixture.graphics().findImage(image.key)->pixels()});
      for (std::size_t placement_index = 0; placement_index < placements_per_view; ++placement_index) {
        catalog->placement({.header = header, .placement = {.key = image.key, .virtual_id = placement_index + 1, .columns = 2, .rows = 2, .z_index = static_cast<std::int32_t>(index)}});
      }

      auto view = std::make_unique<ImageItem>(catalog, fixture.screen_, *fixture.window().contentItem());
      view->setX(static_cast<qreal>(index * window_side));
      views.push_back(std::move(view));
    }

    fixture.window().resize(static_cast<int>(view_count * window_side), window_side);
    fixture.setCapturePhase(QStringLiteral("highest-selected"));
    QTRY_COMPARE(fixture.statistics().images, view_count - 1);
    QCOMPARE(fixture.sample({cell_side, cell_side}), QColor{Qt::black});
    QCOMPARE(fixture.sample({static_cast<int>((view_count - 1) * window_side) + cell_side, cell_side}), red);
    QCOMPARE(fixture.statistics().placements, ImagePlacementSelection::capacity);
    QCOMPARE(fixture.statistics().dropped_placements, placements_per_view);
    QCOMPARE(fixture.statistics().resources.allocations, view_count - 1);
    QCOMPARE(fixture.placement_limits_.size(), std::size_t{1});
    QCOMPARE(fixture.placement_limits_.front().name, ImagePlacementSelection::limit_name);
    QCOMPARE(fixture.placement_limits_.front().requested, std::optional<std::uint64_t>{view_count * placements_per_view});
    fixture.setCapturePhase(QStringLiteral("placeholder-admitted"));
    views.back()->setVisible(false);
    QTRY_COMPARE(fixture.sample({cell_side, cell_side}), red);
    QCOMPARE(fixture.statistics().dropped_placements, std::size_t{0});
    QCOMPARE(fixture.statistics().resources.allocations, view_count);
    QCOMPARE(fixture.placement_limits_.size(), std::size_t{1});
    fixture.setCapturePhase(QStringLiteral("highest-restored"));
    views.back()->setVisible(true);
    QTRY_COMPARE(fixture.sample({cell_side, cell_side}), QColor{Qt::black});
    QCOMPARE(fixture.statistics().resources.allocations, view_count);
    QCOMPARE(fixture.placement_limits_.size(), std::size_t{2});
  }

  Q_SLOT static void incompleteReplacementPreservesThePreviousTexture() {
    Fixture fixture;
    const auto previous = fixture.begin(1);
    fixture.finish(previous, red);
    fixture.place(previous);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    const auto current = fixture.begin(2);
    fixture.place(current);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    fixture.finish(current, blue);
    QCOMPARE(fixture.sample({cell_side, cell_side}), blue);
  }

  Q_SLOT static void retainedPlacementUsesItsOwnGeometryWithANewerTexture() {
    Fixture fixture;
    const auto previous = fixture.begin(1);
    fixture.finish(previous, red);
    fixture.place(previous, false);
    constexpr QPoint lower_half{cell_side, cell_side + (cell_side / 2)};
    QCOMPARE(fixture.sample(lower_half), red);
    const auto current = fixture.begin(2, 4, 2);
    constexpr std::array bands{blue, blue, red, red};
    fixture.finishPattern(current, bands);
    QCOMPARE(fixture.sample(lower_half), blue);
    QVERIFY(fixture.graphics().findImage(previous.key) != nullptr);
  }

  Q_SLOT static void placeholderFragmentsSampleTheWholeStandIn() {
    Fixture fixture;
    const auto previous = fixture.begin(1);
    constexpr std::array quadrants{red, green, blue, yellow};
    fixture.finishPattern(previous, quadrants);
    fixture.placeholders();
    fixture.graphics().placement({.header = header, .placement = {.key = previous.key, .virtual_id = 1, .columns = 2, .rows = 2, .location = PlacementLocation::placeholders}});
    constexpr QPoint first_cell{cell_side / 2, cell_side / 2};
    QVERIFY(closeColor(fixture.sample(first_cell), red));
    const auto current = fixture.begin(2, 4, 4);
    fixture.graphics().placement({.header = header, .placement = {.key = current.key, .virtual_id = 1, .source_x = 2, .source_y = 2, .source_width = 2, .source_height = 2, .columns = 2, .rows = 2, .location = PlacementLocation::placeholders}});
    QVERIFY(closeColor(fixture.sample(first_cell), red));
    QVERIFY(closeColor(fixture.sample({cell_side + (cell_side / 2), cell_side / 2}), green));
    QVERIFY(closeColor(fixture.sample({cell_side / 2, cell_side + (cell_side / 2)}), blue));
    QVERIFY(closeColor(fixture.sample({cell_side + (cell_side / 2), cell_side + (cell_side / 2)}), yellow));
  }

  Q_SLOT static void reattachedCatalogDoesNotShowPixelsFromThePreviousLifetime() {
    Fixture fixture;
    const auto previous = fixture.begin(1);
    fixture.finish(previous, red);
    fixture.place(previous);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    fixture.graphics().detach();
    const auto current = fixture.begin(1);
    fixture.finish(current, blue);
    fixture.place(current);
    QCOMPARE(fixture.sample({cell_side, cell_side}), blue);
  }

  Q_SLOT static void reconstructedCatalogAtTheSameAddressReplacesItsTexture() {
    Fixture fixture;
    const auto previous = fixture.begin(1);
    fixture.finish(previous, red);
    fixture.place(previous);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    const auto *previous_address = std::addressof(fixture.graphics());
    fixture.reconstructCatalog();
    QCOMPARE(std::addressof(fixture.graphics()), previous_address);
    const auto current = fixture.begin(1);
    fixture.finish(current, blue);
    fixture.place(current);
    QCOMPARE(fixture.sample({cell_side, cell_side}), blue);
  }

  Q_SLOT static void rgbRowsKeepTheirColorWithoutAnAlphaChannel() {
    Fixture fixture;
    const auto image = fixture.begin(1, 2, 2, ImageFormat::rgb);
    fixture.finish(image, red);
    fixture.place(image);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
  }

  Q_SLOT static void straightAlphaIsBlendedOnce() {
    Fixture fixture;
    constexpr int half_opacity = 128;
    const auto image = fixture.begin(1);
    auto translucent_red = red;
    translucent_red.setAlpha(half_opacity);
    fixture.finish(image, translucent_red);
    fixture.place(image);
    QCOMPARE(fixture.sample({cell_side, cell_side}), QColor(half_opacity, 0, 0));
  }

  Q_SLOT static void drawBudgetIncludesRetainedScenesInPaintOrder() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    constexpr std::size_t global_draw_capacity = 2048;
    constexpr auto draws_per_view = GraphicsStore<ApplicationAllocator>::placement_capacity;
    constexpr auto view_count = (global_draw_capacity / draws_per_view) + 1;
    for (std::size_t index = 0; index < draws_per_view; ++index) {
      fixture.graphics().placement({.header = header, .placement = {.key = image.key, .virtual_id = index + 1, .columns = 2, .rows = 2}});
    }

    ApplicationAllocator memory;
    const Screen<ApplicationAllocator> screen{memory};
    QQuickItem group{fixture.window().contentItem()};
    group.setSize({static_cast<qreal>(view_count * window_side), window_side});
    std::vector<std::unique_ptr<ImageItem>> views;
    for (std::size_t index = 1; index < view_count; ++index) {
      auto &parent = index + 1 == view_count ? *fixture.window().contentItem() : group;
      auto view = std::make_unique<ImageItem>(fixture.catalog(), screen, parent);
      view->setX(static_cast<qreal>(index * window_side));
      views.push_back(std::move(view));
    }

    fixture.window().resize(static_cast<int>(view_count * window_side), window_side);
    const auto last_view_x = static_cast<int>((view_count - 1) * window_side) + cell_side;
    fixture.setCapturePhase(QStringLiteral("initial"));
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    QCOMPARE(fixture.sample({last_view_x, cell_side}), QColor{Qt::black});
    QCOMPARE(fixture.statistics().image_draws, global_draw_capacity);
    fixture.setCapturePhase(QStringLiteral("first-hidden"));
    fixture.setImageVisible(false);
    QTRY_COMPARE(fixture.sample({last_view_x, cell_side}), red);
    fixture.setCapturePhase(QStringLiteral("reordered"));
    fixture.setImageVisible(true);
    auto &last = *views.back();
    last.setParentItem(&group);
    last.stackBefore(views.front().get());
    const auto displaced_view_x = static_cast<int>((view_count - 2) * window_side) + cell_side;
    QTRY_COMPARE(fixture.sample({last_view_x, cell_side}), red);
    QCOMPARE(fixture.sample({displaced_view_x, cell_side}), QColor{Qt::black});
    fixture.setCapturePhase(QStringLiteral("last-hidden"));
    last.setVisible(false);
    QTRY_COMPARE(fixture.sample({displaced_view_x, cell_side}), red);
  }

  Q_SLOT static void placeholderDrawsPrecedeAboveTextImagesAtTheBound() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.graphics().placement({.header = header, .placement = {.key = image.key, .virtual_id = 1, .columns = 1, .rows = 1, .location = PlacementLocation::placeholders}});
    constexpr std::uint16_t screen_side = window_side;
    auto upper = image;
    upper.key.image_id = 2;
    fixture.graphics().image({.header = header, .image = upper});
    fixture.finish(upper, blue);
    fixture.graphics().placement({.header = header, .placement = {.key = upper.key, .virtual_id = 2, .columns = screen_side, .rows = screen_side, .z_index = 1}});
    constexpr std::string_view first_fragment{"\xf4\x8e\xbb\xae\xcc\x85\xcc\x85"};
    std::vector<Cell> cells(static_cast<std::size_t>(screen_side) * screen_side);
    for (auto &cell : cells) {
      cell.text = byteView(first_fragment);
      cell.style.foreground = {.kind = CellColor::Kind::rgb, .channels = {0, 0, 1}};
    }

    fixture.replaceScreen(cells, {.cols = screen_side, .rows = screen_side, .cell_width_px = 0, .cell_height_px = 0});
    fixture.item_.setCellSize({1, 1});
    constexpr QPoint admitted{window_side / 4, window_side / 4};
    constexpr QPoint omitted{window_side / 4, (window_side * 3) / 4};
    fixture.setCapturePhase(QStringLiteral("saturated"));
    QCOMPARE(fixture.sample(admitted), red);
    QCOMPARE(fixture.sample(omitted), QColor{Qt::black});
    constexpr std::size_t global_draw_capacity = 2048;
    QCOMPARE(fixture.statistics().image_draws, global_draw_capacity);
    fixture.setCapturePhase(QStringLiteral("above-text"));
    fixture.graphics().erase(GraphicsDeletePlacement{.header = header, .virtual_id = 1});
    QCOMPARE(fixture.sample(admitted), blue);
    QCOMPARE(fixture.statistics().image_draws, std::size_t{1});
  }

  Q_SLOT static void imageGeometryIsClippedToItsOwnView() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.graphics().placement({.header = header, .placement = {.key = image.key, .virtual_id = 1, .x = 2, .columns = 2, .rows = 2}});
    fixture.window().resize(window_side * 2, window_side);
    fixture.setCapturePhase(QStringLiteral("outside"));
    QCOMPARE(fixture.sample({window_side + cell_side, cell_side}), QColor{Qt::black});
    QCOMPARE(fixture.sample({cell_side, cell_side}), QColor{Qt::black});
    QCOMPARE(fixture.statistics().image_draws, std::size_t{0});
    fixture.setCapturePhase(QStringLiteral("partial"));
    fixture.graphics().placement({.header = header, .placement = {.key = image.key, .virtual_id = 1, .x = 1, .columns = 2, .rows = 2}});
    QCOMPARE(fixture.sample({cell_side + (cell_side / 2), cell_side}), red);
    QCOMPARE(fixture.sample({window_side + (cell_side / 2), cell_side}), QColor{Qt::black});
    QCOMPARE(fixture.statistics().image_draws, std::size_t{1});
    fixture.setCapturePhase(QStringLiteral("expanded"));
    fixture.item_.setWidth(window_side * 2);
    QCOMPARE(fixture.sample({window_side + (cell_side / 2), cell_side}), red);
  }

  Q_SLOT static void visibleImagesAdvanceAcrossTheUploadBound() {
    Fixture fixture;
    fixture.capture();
    constexpr std::uint32_t image_count = 7;
    constexpr std::size_t bytes_per_image = 16;
    for (std::uint32_t index = 1; index <= image_count; ++index) {
      const ImageDescription image{.key = {.image_id = index, .generation = 1}, .format = ImageFormat::rgba, .width = 2, .height = 2, .byte_len = bytes_per_image};
      fixture.graphics().image({.header = header, .image = image});
      fixture.finish(image, index == image_count ? blue : red);
      fixture.graphics().placement({.header = header, .placement = {.key = image.key, .virtual_id = index, .columns = 2, .rows = 2, .z_index = static_cast<std::int32_t>(index)}});
    }

    fixture.requestImageUpdate();
    QTRY_COMPARE(fixture.statistics().images, image_count);
    QCOMPARE(fixture.sample({cell_side, cell_side}), blue);
    QCOMPARE(fixture.statistics().resident_bytes, image_count * bytes_per_image);
    constexpr std::size_t maximum_uploads = 4;
    QVERIFY(fixture.statistics().uploads_started <= maximum_uploads);
  }

  Q_SLOT static void twoViewsShareOneTextureAndRefreshTogether() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    ApplicationAllocator memory;
    const Screen<ApplicationAllocator> screen{memory};
    ImageItem other{fixture.catalog(), screen, *fixture.window().contentItem()};
    other.setX(window_side);
    fixture.window().resize(window_side * 2, window_side);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    QCOMPARE(fixture.sample({window_side + cell_side, cell_side}), red);
    QCOMPARE(fixture.statistics().images, std::size_t{1});
    QCOMPARE(fixture.statistics().resources.allocations, std::uint64_t{1});
    const auto newer = fixture.begin(2);
    fixture.finish(newer, blue);
    fixture.place(newer);
    QCOMPARE(fixture.sample({cell_side, cell_side}), blue);
    QTRY_COMPARE(fixture.sample({window_side + cell_side, cell_side}), blue);
  }

  Q_SLOT static void panesCompeteForOneGlobalTextureBudget() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    ApplicationAllocator memory;
    constexpr std::size_t colliding_catalog_distance = image_texture_capacity * 2;
    for (std::size_t index = 1; index < colliding_catalog_distance; ++index) {
      const GraphicsStore temporary{memory, fixture.budget()};
    }

    std::optional<GraphicsStore<ApplicationAllocator>> catalog{std::in_place, memory, fixture.budget()};
    constexpr std::size_t texture_bytes = 16;
    constexpr Byte full_channel = 255;
    const std::array<Byte, texture_bytes> pixels{0, 0, full_channel, full_channel, 0, 0, full_channel, full_channel, 0, 0, full_channel, full_channel, 0, 0, full_channel, full_channel};
    catalog->image({.header = header, .image = image});
    catalog->chunk({.header = header, .key = image.key, .bytes = pixels});
    catalog->placement({.header = header, .placement = {.key = image.key, .virtual_id = 1, .columns = 2, .rows = 2}});
    const Screen<ApplicationAllocator> screen{memory};
    ImageItem other{catalog, screen, *fixture.window().contentItem()};
    other.setX(window_side);
    fixture.window().resize(window_side * 2, window_side);
    const QObject observation;
    QObject::connect(&fixture.window(), &QQuickWindow::beforeSynchronizing, &observation, [&] {
      WindowImages::findWindow(fixture.window())->observeCatalog(*catalog);
    },
                     Qt::DirectConnection);
    const auto real_retained_bytes = fixture.budget().used;
    fixture.budget().used = GraphicsBudget::global_capacity - texture_bytes;
    const auto frame = fixture.capture();
    const auto scale = fixture.window().devicePixelRatio();
    const auto first = frame.pixelColor(static_cast<int>(cell_side * scale), static_cast<int>(cell_side * scale));
    const auto second = frame.pixelColor(static_cast<int>((window_side + cell_side) * scale), static_cast<int>(cell_side * scale));
    QVERIFY((first == red && second == Qt::black) || (first == Qt::black && second == blue));
    QCOMPARE(fixture.statistics().resident_bytes, texture_bytes);
    other.update();
    fixture.capture();
    constexpr int settle_ms = 100;
    QTest::qWait(settle_ms);
    const auto settled_frame = fixture.statistics().frame;
    QTest::qWait(settle_ms);
    QVERIFY2(fixture.statistics().frame <= settled_frame + 1, "a protected texture budget must wait for state changes rather than force continuous frames");
    if (first == red) {
      fixture.setImageVisible(false);
    } else {
      other.setVisible(false);
    }

    constexpr int admission_wait_ms = 1000;
    QTRY_COMPARE_WITH_TIMEOUT(fixture.statistics().resources.allocations, std::uint64_t{2}, admission_wait_ms);
    fixture.budget().used = real_retained_bytes;
    fixture.setImageVisible(true);
    other.setVisible(true);
    fixture.capture();
    QTRY_COMPARE(fixture.sample({cell_side, cell_side}), red);
    QTRY_COMPARE(fixture.sample({window_side + cell_side, cell_side}), blue);
    QCOMPARE(fixture.statistics().resident_bytes, texture_bytes * 2);
  }

  Q_SLOT static void aSpareOfTheSameSizeReusesItsNativeTexture() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    fixture.graphics().erase(GraphicsDeleteImage{.header = header, .key = image.key});
    QTRY_VERIFY(([&] {
      fixture.capture();
      return fixture.statistics().spares == 1;
    })());
    const auto newer = fixture.begin(2);
    fixture.finish(newer, blue);
    fixture.place(newer);
    QCOMPARE(fixture.sample({cell_side, cell_side}), blue);
    if (fixture.window().rendererInterface()->graphicsApi() != QSGRendererInterface::Software) {
      QCOMPARE(fixture.statistics().resources.allocations, std::uint64_t{1});
      QCOMPARE(fixture.statistics().resources.rewrites, std::uint64_t{1});
    }
  }

  Q_SLOT static void hidingTheWindowReleasesAndRestoresItsImages() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    fixture.window().hide();
    QTRY_COMPARE(fixture.statistics().resident_bytes, std::size_t{0});
    fixture.window().show();
    QTRY_COMPARE(fixture.sample({cell_side, cell_side}), red);
    QCOMPARE(fixture.statistics().resources.allocations, std::uint64_t{2});
  }

  Q_SLOT static void idleImagesExpireWhileTheirPaneIsHidden() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    fixture.setImageVisible(false);
    constexpr int expiry_wait_ms = 7000;
    QTRY_COMPARE_WITH_TIMEOUT(fixture.statistics().resident_bytes, std::size_t{0}, expiry_wait_ms);
    fixture.setImageVisible(true);
    QTRY_COMPARE(fixture.sample({cell_side, cell_side}), red);
    QCOMPARE(fixture.statistics().resources.allocations, std::uint64_t{2});
  }

  Q_SLOT static void visibleImagesRemainResidentAtAnIdleDeadline() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    constexpr int beyond_idle_deadline_ms = 5500;
    QTest::qWait(beyond_idle_deadline_ms);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    QCOMPARE(fixture.statistics().resources.allocations, std::uint64_t{1});
  }

  Q_SLOT static void aTemporaryRenderStopKeepsTheVisibleImageResident() {
    Fixture fixture;
    const auto image = fixture.begin(1);
    fixture.finish(image, red);
    fixture.place(image);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    const auto allocations = fixture.statistics().resources.allocations;
    auto &images = WindowImages::forWindow(fixture.window());
    WindowImageStatistics stopped;
    bool injected = false;
    const QObject observation;
    QObject::connect(&fixture.window(), &QQuickWindow::afterSynchronizing, &observation, [&] {
      if (!injected) {
        injected = true;
        fixture.window().sceneGraphAboutToStop();
        stopped = images.statistics();
      }
    },
                     Qt::DirectConnection);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    QVERIFY(injected);
    QCOMPARE(stopped.resident_bytes, static_cast<std::size_t>(image.byte_len));
    QCOMPARE(stopped.resources.allocations, allocations);
    QCOMPARE(fixture.statistics().resources.allocations, allocations);
  }

  Q_SLOT static void oversizedTextureKeepsItsDrawableStandIn() {
    Fixture fixture;
    const auto previous = fixture.begin(1);
    fixture.finish(previous, red);
    fixture.place(previous);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
    constexpr std::uint32_t beyond_texture_limit = 16385;
    const auto current = fixture.begin(2, beyond_texture_limit, 1);
    fixture.finish(current, blue);
    fixture.place(current);
    QCOMPARE(fixture.sample({cell_side, cell_side}), red);
  }
};

}

QTEST_MAIN(GraphicsRetentionSceneTest)
#include "graphics_retention_scene_test.moc"
