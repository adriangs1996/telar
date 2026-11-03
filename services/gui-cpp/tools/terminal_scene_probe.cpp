#include "application/dependencies.hpp"
#include "core/color.hpp"
#include "core/configuration.hpp"
#include "fonts/font_role.hpp"
#include "graphics/store.hpp"
#include "platform/window.hpp"
#include "qt/bundled_fonts.hpp"
#include "qt/font_asset.hpp"
#include "qt/font_collection.hpp"
#include "qt/font_resolver.hpp"
#include "qt/font_source.hpp"
#include "qt/resident_fonts.hpp"
#include "qt/terminal_scene.hpp"
#include "qt/window_images.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "terminal/screen.hpp"
#include "terminal/selection.hpp"
#include <QColor>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QImage>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSGNode>
#include <QTextCharFormat>
#include <QTimer>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <memory>
#include <span>
#include <stdexcept>
#include <utility>
#include <vector>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;

constexpr unsigned terminal_columns = 256;
constexpr unsigned terminal_rows = 52;
constexpr unsigned default_iterations = 12;
constexpr unsigned default_warmup = 3;
constexpr int timeout_ms = 60'000;
constexpr float terminal_font_size = 19;
constexpr float terminal_line_height = 1.3F;
constexpr float terminal_letter_spacing = -0.5F;
constexpr std::uint8_t terminal_thicken_strength = 250;

struct Options {
  unsigned iterations = default_iterations;
  unsigned warmup = default_warmup;
  qreal scale = 1;
  QString family;
  QString output;
  QString snapshot_workload = QStringLiteral("full");
  bool thicken = true;
};

Options parseOptions(const QGuiApplication &application) {
  QCommandLineParser parser;
  parser.addHelpOption();
  parser.addOption({"iterations", "Measured terminal repaints", "count", QString::number(default_iterations)});
  parser.addOption({"warmup", "Untimed terminal repaints", "count", QString::number(default_warmup)});
  parser.addOption({"scale", "Raster scale", "ratio", "1"});
  parser.addOption({"font", "Installed font family", "family", "JetBrains Mono"});
  parser.addOption({"output", "Final rendered image", "path"});
  parser.addOption({"no-thicken", "Measure the standard glyph route"});
  parser.addOption({"snapshot-workload", "Snapshot changes: full, sparse, retained", "workload", "full"});
  parser.process(application);
  bool iterations_valid = false;
  bool warmup_valid = false;
  bool scale_valid = false;
  Options options{
      .iterations = parser.value("iterations").toUInt(&iterations_valid),
      .warmup = parser.value("warmup").toUInt(&warmup_valid),
      .scale = parser.value("scale").toDouble(&scale_valid),
      .family = parser.value("font"),
      .output = parser.value("output"),
      .snapshot_workload = parser.value("snapshot-workload"),
      .thicken = !parser.isSet("no-thicken"),
  };
  constexpr unsigned maximum_iterations = 1000;
  if (!iterations_valid || !warmup_valid || !scale_valid || options.iterations == 0 || options.iterations > maximum_iterations || options.warmup > maximum_iterations || (options.scale != 1 && options.scale != 2)) {
    throw std::invalid_argument{"Invalid terminal scene probe counts or scale"};
  }

  if (options.snapshot_workload != "full" && options.snapshot_workload != "sparse" && options.snapshot_workload != "retained") {
    throw std::invalid_argument{"Invalid snapshot workload"};
  }

  return options;
}

class TerminalProbe final : public QQuickItem {
public:
  TerminalProbe(QQuickWindow &window, Options options)
      : QQuickItem(window.contentItem()),
        options_(std::move(options)),
        screen_(memory_),
        graphics_(memory_, graphics_budget_) {
    setFlag(ItemHasContents);
    WindowImages::forWindow(window);
    configuration_.font.family.assign(options_.family.toStdString());
    configuration_.font.size = terminal_font_size;
    configuration_.font.line_height = terminal_line_height;
    configuration_.font.letter_spacing = terminal_letter_spacing;
    configuration_.font.thicken = options_.thicken;
    configuration_.font.thicken_strength = terminal_thicken_strength;
    auto asset = std::make_shared<const FontAsset>(loadFontData(configuration_.font));
    collection_ = std::make_shared<const FontCollection>(FontCollection{.primary = std::move(asset)});
    fonts_ = ResidentFonts::shared(collection_);
    resolved_ = FontResolver::resolve(fonts_->face(fonts::FontRole::primary), configuration_.font, options_.scale);
    setSize({terminal_columns * resolved_.font.cell.width(), terminal_rows * resolved_.font.cell.height()});
    configuration_.theme.background = Color{.a = 1};
    characters_.resize(static_cast<std::size_t>(terminal_columns) * terminal_rows);
    cells_.resize(characters_.size());
  }

  [[nodiscard]] bool completed() const noexcept {
    return completed_;
  }

  [[nodiscard]] std::exception_ptr failure() const noexcept {
    return failure_;
  }

protected:
  QSGNode *updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) override {
    std::unique_ptr<QSGNode> root{previous != nullptr ? previous : new QSGNode};
    if (completed_) {
      return root.release();
    }

    try {
      for (unsigned frame = 0; frame < options_.warmup; ++frame) {
        prepareFrame(frame);
        paint(root);
      }

      std::int64_t elapsed = 0;
      std::int64_t apply_elapsed = 0;
      for (unsigned frame = 0; frame < options_.iterations; ++frame) {
        prepareFrame(frame);
        apply_elapsed += apply_elapsed_;
        const auto started = std::chrono::steady_clock::now();
        paint(root);
        elapsed += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
      }

      const QJsonObject result{{"iterations", static_cast<int>(options_.iterations)}, {"warmup", static_cast<int>(options_.warmup)}, {"elapsed_ns", elapsed}, {"apply_ns", apply_elapsed}, {"apply_and_paint_ns", elapsed + apply_elapsed}, {"snapshot_workload", options_.snapshot_workload}, {"columns", static_cast<int>(terminal_columns)}, {"rows", static_cast<int>(terminal_rows)}, {"scale", options_.scale}, {"font", options_.family}, {"thicken", options_.thicken}, {"fixed_pitch", resolved_.font.fixed_pitch}};
      std::cout << QJsonDocument{result}.toJson(QJsonDocument::Compact).constData() << '\n';
    } catch (...) {
      failure_ = std::current_exception();
    }

    completed_ = true;

    return root.release();
  }

private:
  void prepareFrame(unsigned frame) {
    constexpr unsigned printable_first = 33;
    constexpr unsigned printable_count = 94;
    constexpr unsigned row_stride = 37;
    constexpr unsigned column_stride = 13;
    constexpr unsigned bright_period = 7;
    constexpr Byte dim_green = 128;
    constexpr Byte bright_green = 255;
    for (unsigned row = 0; row < terminal_rows; ++row) {
      const auto phase = options_.snapshot_workload == "retained" || (options_.snapshot_workload == "sparse" && row != 0) ? 0U : frame;
      for (unsigned column = 0; column < terminal_columns; ++column) {
        const auto offset = (row * terminal_columns) + column;
        const auto value = (row * row_stride) + (column * column_stride) + phase;
        characters_[offset] = static_cast<Byte>(printable_first + (value % printable_count));
        const auto green = (column + row + phase) % bright_period == 0 ? bright_green : dim_green;
        cells_[offset] = {.width = CellWidth::single, .style = {.foreground = {.kind = CellColor::Kind::rgb, .channels = {0, green, 0}}}, .text = std::span{characters_}.subspan(offset, 1)};
      }
    }

    encoded_.resize(CellRunCodec::encodedSize(cells_));
    const auto encoded = CellRunCodec::encode(cells_, encoded_);
    const FrameSpan span{.start = 0, .count = static_cast<std::uint32_t>(cells_.size()), .cells = encoded};
    const std::array spans{span};
    PaneFrame snapshot;
    snapshot.pane_id = 1;
    snapshot.frame_id = ++frame_id_;
    snapshot.cols = terminal_columns;
    snapshot.rows = terminal_rows;
    snapshot.scroll.total_rows = terminal_rows;
    snapshot.text_metadata = TextMetadata{.row_flags = row_flags_};
    snapshot.spans = spans;
    const auto started = std::chrono::steady_clock::now();
    const auto applied = screen_.apply(snapshot);
    apply_elapsed_ = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    if (applied != FrameApplication::applied) {
      throw std::runtime_error{"Terminal scene fixture was not applied"};
    }
  }

  void paint(std::unique_ptr<QSGNode> &root) {
    const TerminalPresentation frame{.screen = screen_, .graphics = graphics_, .configuration = configuration_, .font = resolved_.font, .preedit = preedit_, .fonts = collection_, .grid = resolved_.grid, .selection = selection_, .bounds = boundingRect(), .scale = options_.scale, .appearance = 1, .owner = this};
    root.reset(TerminalScene::synchronizeNode(root.release(), *window(), frame));
  }

  Options options_;
  ApplicationAllocator memory_;
  Configuration configuration_;
  Screen<ApplicationAllocator> screen_;
  GraphicsBudget graphics_budget_;
  GraphicsStore<ApplicationAllocator> graphics_;
  std::shared_ptr<const FontCollection> collection_;
  std::shared_ptr<ResidentFonts> fonts_;
  ResolvedFont resolved_;
  std::vector<Byte> characters_;
  std::vector<Cell> cells_;
  std::vector<Byte> encoded_;
  std::array<Byte, terminal_rows> row_flags_{};
  QString preedit_;
  CellSelection selection_;
  std::uint64_t frame_id_ = 0;
  std::int64_t apply_elapsed_ = 0;
  std::exception_ptr failure_;
  bool completed_ = false;
};

}

int main(int argc, char **argv) {
  platform::configureGraphics();
  QGuiApplication application{argc, argv};
  try {
    const auto options = parseOptions(application);
    static_cast<void>(bundledFonts());
    QQuickWindow window;
    window.setColor(Qt::black);
    TerminalProbe probe{window, options};
    window.resize(static_cast<int>(probe.width()), static_cast<int>(probe.height()));
    bool captured = false;
    QObject::connect(&window, &QQuickWindow::frameSwapped, &application, [&] {
      if (captured || !probe.completed()) {
        return;
      }

      captured = true;
      if (!options.output.isEmpty() && !window.grabWindow().save(options.output)) {
        QGuiApplication::exit(1);
        return;
      }

      QGuiApplication::quit();
    });
    QTimer::singleShot(timeout_ms, &application, [] {
      QGuiApplication::exit(1);
    });
    window.show();
    const auto result = QGuiApplication::exec();
    if (probe.failure()) {
      std::rethrow_exception(probe.failure());
    }

    return captured ? result : 1;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
