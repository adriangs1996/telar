#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <concepts>
#include <utility>
#include "../platform/window.hpp"
#include "../qt/alpha_mask_material.hpp"
#include "../qt/alpha_mask_vertex.hpp"
#include "../qt/chrome_glyph_images.hpp"
#include "../qt/chrome_text_scene.hpp"
#include "../qt/font_collection.hpp"
#include "../qt/resident_fonts.hpp"
#include "../qt/bundled_fonts.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QColor>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCryptographicHash>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QObject>
#include <QQuickWindow>
#include <QSGGeometryNode>
#include <QSGNode>
#include <QSGTransformNode>
#include <QString>
#include <QTimer>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <bit>
#include <exception>
#include <iostream>
#include <string>
#include <vector>

#include "platform/window.hpp"
#include "qt/alpha_mask_material.hpp"
#include "qt/alpha_mask_vertex.hpp"
#include "qt/chrome_glyph_images.hpp"
#include "qt/chrome_text_scene.hpp"
#include "qt/font_collection.hpp"
#include "qt/resident_fonts.hpp"
#include "qt/bundled_fonts.hpp"


import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.terminal.font_grid;

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr std::uint16_t pixel_height = 15;
constexpr std::array text_lengths{32U, 128U, 512U};
constexpr int window_side = 64;
constexpr int timeout_ms = 30'000;
constexpr unsigned measured_iterations = 2000;
constexpr unsigned warmup_iterations = 100;

enum class Operation : unsigned char {
  create,
  rebuild,
  repaint,
};

struct Options {
  unsigned iterations = measured_iterations;
  unsigned warmup = warmup_iterations;
};

Options parseOptions(const QGuiApplication &application) {
  QCommandLineParser parser;
  parser.addHelpOption();
  parser.addOption({QStringLiteral("iterations"), QStringLiteral("Measured scene operations per case"), QStringLiteral("count"), QString::number(measured_iterations)});
  parser.addOption({QStringLiteral("warmup"), QStringLiteral("Untimed scene operations per case"), QStringLiteral("count"), QString::number(warmup_iterations)});
  parser.process(application);
  bool iterations_valid = false;
  bool warmup_valid = false;
  const auto iterations = parser.value(QStringLiteral("iterations")).toUInt(&iterations_valid);
  const auto warmup = parser.value(QStringLiteral("warmup")).toUInt(&warmup_valid);
  constexpr unsigned maximum_iterations = 1'000'000;
  if (!iterations_valid || !warmup_valid || iterations == 0 || iterations > maximum_iterations || warmup > maximum_iterations) {
    throw std::invalid_argument{"Expected 1..1000000 iterations and 0..1000000 warmup operations"};
  }

  return {.iterations = iterations, .warmup = warmup};
}

template <typename Value>
void hashValue(QCryptographicHash &hash, const Value &value) {
  const auto bytes = std::bit_cast<std::array<char, sizeof(Value)>>(value);
  hash.addData(QByteArrayView{bytes.data(), static_cast<qsizetype>(bytes.size())});
}

void hashMesh(QCryptographicHash &hash, const QSGGeometryNode &node) {
  const auto *geometry = node.geometry();
  const auto *material = dynamic_cast<const AlphaMaskMaterial *>(node.material());
  if (geometry == nullptr || material == nullptr || std::cmp_not_equal(geometry->sizeOfVertex(), sizeof(AlphaMaskVertex))) {
    throw std::runtime_error{"Unexpected text scene mesh"};
  }

  hashValue(hash, geometry->vertexCount());
  hashValue(hash, geometry->drawingMode());
  const auto *vertices = static_cast<const AlphaMaskVertex *>(geometry->vertexData());
  for (const auto &vertex : std::span{vertices, static_cast<std::size_t>(geometry->vertexCount())}) {
    hashValue(hash, vertex.x);
    hashValue(hash, vertex.y);
    hashValue(hash, vertex.u);
    hashValue(hash, vertex.v);
    hashValue(hash, vertex.opacity);
  }

  const auto ink = material->foreground();
  hashValue(hash, ink.r);
  hashValue(hash, ink.g);
  hashValue(hash, ink.b);
  hashValue(hash, ink.a);
  hashValue(hash, material->blend());
}

QByteArray sceneDigest(const QSGNode &root) {
  QCryptographicHash hash{QCryptographicHash::Sha256};
  for (const auto *node = &root; node != nullptr;) {
    hashValue(hash, node->type());
    if (const auto *transform = dynamic_cast<const QSGTransformNode *>(node)) {
      constexpr std::size_t matrix_elements = 16;
      for (const auto value : std::span<const float, matrix_elements>{transform->matrix().constData(), matrix_elements}) {
        hashValue(hash, value);
      }
    }

    if (const auto *mesh = dynamic_cast<const QSGGeometryNode *>(node)) {
      hashMesh(hash, *mesh);
    }

    if (node->firstChild() != nullptr) {
      node = node->firstChild();
      continue;
    }

    while (node != &root && node->nextSibling() == nullptr) {
      node = node->parent();
    }

    node = node == &root ? nullptr : node->nextSibling();
  }

  return hash.result().toHex();
}

class TextCase {
public:
  TextCase(const TextCase &) = delete;
  TextCase &operator=(const TextCase &) = delete;

  // The case paints through the window, region `a`, whose glyph cache it keeps warm.
  TextCase(tbc::view<QQuickWindow &, tbc::lt::a> window, const std::shared_ptr<const FontCollection> &collection, unsigned length)
      : window_(window),
        collection_(collection),
        fonts_(ResidentFonts::shared(collection)),
        images_(ChromeGlyphImages<ResidentFonts>::shared(window, fonts_)) {
    constexpr std::string_view alphabet = "0123456789abcdef ABCDEF -> != ffi ";
    std::string text;
    text.reserve(length);
    for (unsigned index = 0; index < length; ++index) {
      text.push_back(alphabet[index % alphabet.size()]);
    }

    auto &face = fonts_->face(fonts::FontRole::primary);
    const auto shaped = face.shape(text, pixel_height);
    glyphs_.reserve(shaped.size());
    for (std::size_t index = 0; index < shaped.size(); ++index) {
      glyphs_.push_back(shaped.glyph(index));
    }

    paint_.glyphs = glyphs_;
    paint_.metrics = face.metrics(pixel_height);
    paint_.bounds = {static_cast<qreal>(shaped.advance()), window_side};
    paint_.color = QColor{Qt::white};
    paint_.revision = 1;
    paint_.pixel_height = pixel_height;
    paint_.advance = shaped.advance();
    paint_.role = fonts::FontRole::primary;
  }

  [[nodiscard]] const ChromeTextPaint &paint() const noexcept {
    return paint_;
  }

  [[nodiscard]] const std::shared_ptr<const FontCollection> &collection() const noexcept {
    return collection_;
  }

  [[nodiscard]] tbc::view<QQuickWindow &, tbc::lt::a> window() const noexcept {
    return window_;
  }

private:
  tbc::view<QQuickWindow &, tbc::lt::a> window_;
  std::shared_ptr<const FontCollection> collection_;
  std::shared_ptr<ResidentFonts> fonts_;
  tbc::view<std::shared_ptr<ChromeGlyphImages<ResidentFonts>>, tbc::lt::a> images_;
  std::vector<fonts::ShapedGlyph> glyphs_;
  // The paint views the glyphs stored beside it.
  tbc::view<ChromeTextPaint, tbc::lt::self> paint_;
};

class SceneRun {
public:
  SceneRun(const TextCase &text, Operation operation)
      : window_(text.window()),
        text_(text),
        operation_(operation),
        paint_(text.paint()) {}

  void step() {
    if (operation_ == Operation::create) {
      node_.reset();
    } else if (operation_ == Operation::rebuild) {
      ++paint_.revision;
    }

    node_.reset(paintChromeText(node_.release(), window_, paint_, text_.collection()));
  }

  [[nodiscard]] QByteArray digest() const {
    if (!node_) {
      throw std::runtime_error{"The scene probe did not produce a node"};
    }

    return sceneDigest(*node_);
  }

private:
  QQuickWindow &window_;
  const TextCase &text_;
  Operation operation_;
  ChromeTextPaint paint_;
  std::unique_ptr<QSGNode> node_;
};

void measure(const TextCase &text, Operation operation, Options options) {
  SceneRun scene{text, operation};
  for (unsigned index = 0; index < options.warmup; ++index) {
    scene.step();
  }

  const auto started = std::chrono::steady_clock::now();
  for (unsigned index = 0; index < options.iterations; ++index) {
    scene.step();
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  const auto name = std::array{QStringLiteral("create"), QStringLiteral("rebuild"), QStringLiteral("repaint")}[std::to_underlying(operation)];
  const QJsonObject row{{QStringLiteral("operation"), name}, {QStringLiteral("glyphs"), static_cast<qint64>(text.paint().glyphs.size())}, {QStringLiteral("iterations"), static_cast<qint64>(options.iterations)}, {QStringLiteral("warmup"), static_cast<qint64>(options.warmup)}, {QStringLiteral("elapsed_ns"), static_cast<qint64>(elapsed)}, {QStringLiteral("scene_sha256"), QString::fromLatin1(scene.digest())}};
  std::cout << QJsonDocument{row}.toJson(QJsonDocument::Compact).constData() << '\n';
}

void runCases(QQuickWindow &window, const std::shared_ptr<const FontCollection> &collection, Options options) {
  for (const auto length : text_lengths) {
    const TextCase text{window, collection, length};
    for (const auto operation : {Operation::create, Operation::rebuild, Operation::repaint}) {
      measure(text, operation, options);
    }
  }
}

}

int main(int argc, char **argv) {
  platform::configureGraphics();
  QGuiApplication application{argc, argv};
  try {
    const auto options = parseOptions(application);
    static_cast<void>(bundledFonts());
    const auto collection = std::make_shared<const FontCollection>(FontCollection{
        .primary = ResidentFonts::resolveSource({}, {}),
    });
    QQuickWindow window;
    window.resize(window_side, window_side);
    std::exception_ptr failure;
    bool completed = false;
    QObject::connect(&window, &QQuickWindow::beforeSynchronizing, &window, [&] {
      if (completed) {
        return;
      }

      completed = true;
      try {
        runCases(window, collection, options);
      } catch (...) {
        failure = std::current_exception();
      }

      QMetaObject::invokeMethod(&application, &QGuiApplication::quit, Qt::QueuedConnection);
    },
                     Qt::DirectConnection);
    QTimer::singleShot(timeout_ms, &application, [] {
      QGuiApplication::exit(1);
    });
    window.show();
    const auto result = QGuiApplication::exec();
    if (failure) {
      std::rethrow_exception(failure);
    }

    return completed ? result : 1;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
