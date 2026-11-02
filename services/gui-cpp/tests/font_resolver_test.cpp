#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "fonts/face.hpp"
#include "fonts/font_coverage.hpp"
#include "fonts/font_query.hpp"
#include "fonts/glyph_bitmap_view.hpp"
#include "fonts/native_match.hpp"
#include "fonts/shaped_run_view.hpp"
#include "qt/font_cache.hpp"
#include "qt/font_resolver.hpp"
#include "qt/font_source.hpp"
#include "terminal/font_grid.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "qt/bundled_fonts.hpp"
#include "qt/terminal_font.hpp"
#include <QByteArray>
#include <QFile>
#include <QFont>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QObject>
#include <QRawFont>
#include <QString>
#include <QStringLiteral>
#include <QtCore/qiodevicebase.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <native/font.h>
#include <new>
#include <stdexcept>
#include <vector>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

class FontResolverTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void fallbackFacesCanBeRasterized() {
    std::size_t checked = 0;
    for (const auto *text : {"λ", "á", "漢", "字", "中"}) {
      const auto query = fonts::FontQuery::create(text);
      if (!query) {
        QFAIL("Fallback fixture must contain a valid grapheme");
      }

      fonts::FontMatch native{};
      if (telar_gui_find_fallback_font(query->codepoints(), &native) != TELAR_FONT_FOUND) {
        continue;
      }

      const auto data = loadFallbackFontData(*query);
      if (!data) {
        QFAIL("An installed native fallback could not be replaced with a rasterizable face");
      }

      const fonts::Face face{telar::byteView({data->bytes.constData(), static_cast<std::size_t>(data->bytes.size())}), data->match};
      QVERIFY(face.monochrome());
      QVERIFY(fonts::FontCoverage::covers(face, text));
      ++checked;
    }

    QVERIFY(checked > 0);
  }

  Q_SLOT static void nativeFallbackHonorsClientValidation() {
    fonts::FontMatch expected{};
    QVERIFY(telar_gui_find_fallback_font("λ", &expected) == TELAR_FONT_FOUND);
    fonts::FontMatch accepted{};
    const auto allow = [](const telar_font_match *, void *) -> int { return TELAR_FONT_FOUND; };
    QCOMPARE(telar_gui_find_validated_fallback_font("λ", &accepted, allow, nullptr), TELAR_FONT_FOUND);
    QVERIFY(fonts::sameFontMatch(expected, accepted));
    std::size_t rejected = 0;
    const auto reject = [](const telar_font_match *, void *context) -> int {
      ++*static_cast<std::size_t *>(context);

      return TELAR_FONT_FAMILY_NOT_FOUND;
    };
    QCOMPARE(telar_gui_find_validated_fallback_font("λ", &accepted, reject, &rejected), TELAR_FONT_FAMILY_NOT_FOUND);
    QVERIFY(rejected > 0);
  }

  Q_SLOT static void preservesPhysicalBaseline() {
    SystemAllocator memory;
    const FontConfiguration configuration;
    const FontSource source{memory, configuration};
    fonts::Face face{source.bytes(), source.match()};
    const auto height = FontGrid::pixelHeight(configuration, 1);
    const auto grid = FontGrid::resolve(face.metrics(height), configuration, 1);
    const auto font = FontResolver::resolve(memory, configuration, 1).font;
    QCOMPARE(font.cell.width(), static_cast<qreal>(grid.width));
    QCOMPARE(font.cell.height(), static_cast<qreal>(grid.height));
    QCOMPARE(font.baseline, static_cast<qreal>(grid.baseline));
  }

  Q_SLOT static void preservesFractionalScaleAndLineSpacing() {
    SystemAllocator memory;
    FontConfiguration configuration;
    constexpr std::array sizes{6.0F, 7.5F, 15.0F, 18.5F, 48.0F, 96.0F};
    constexpr std::array scales{0.75, 1.0, 1.25, 1.5, 2.0, 4.0, 8.0};
    constexpr std::array line_heights{0.75F, 1.0F, 1.2F, 1.5F, 3.0F};
    const FontSource source{memory, configuration};
    fonts::Face face{source.bytes(), source.match()};
    for (const auto size : sizes) {
      configuration.size = size;
      for (const auto scale : scales) {
        for (const auto line_height : line_heights) {
          configuration.line_height = line_height;
          const auto resolved = FontResolver::resolve(face, configuration, scale);
          QCOMPARE(resolved.font.cell.width() * scale, static_cast<qreal>(resolved.grid.width));
          QCOMPARE(resolved.font.cell.height() * scale, static_cast<qreal>(resolved.grid.height));
          QCOMPARE(resolved.font.baseline * scale, static_cast<qreal>(resolved.grid.baseline));
        }
      }
    }
  }

  Q_SLOT static void respectsAllocatorOwnershipAndFailure() {
    SystemAllocator system;
    const FontConfiguration configuration;
    BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
    {
      const FontSource source{memory, FontConfiguration{}};
      QVERIFY(memory.liveBytes() >= source.bytes().size());
    }

    QCOMPARE(memory.liveBytes(), std::size_t{0});
    const auto resolved = FontResolver::resolve(memory, configuration, 1);
    QCOMPARE(memory.liveBytes(), std::size_t{0});
    QVERIFY(QRawFont::fromFont(resolved.font.faces.front()).supportsCharacter('M'));
    BudgetAllocator exhausted{system, std::size_t{0}};
    QVERIFY_THROWS_EXCEPTION(std::bad_alloc, static_cast<void>(FontResolver::resolve(exhausted, configuration, 1)));
    QCOMPARE(exhausted.liveBytes(), std::size_t{0});
  }

  Q_SLOT static void preservesShapingAndRasterAfterSizeCacheEviction() {
    SystemAllocator memory;
    const FontSource source{memory, FontConfiguration{}};
    fonts::Face face{source.bytes(), source.match()};
    constexpr std::uint16_t pixel_height = 13;
    constexpr auto label = "office · Telar";
    const auto initial = face.shape(label, pixel_height);
    const auto advance = initial.advance();
    Vector<fonts::ShapedGlyph, SystemAllocator> saved{AllocatorRef<fonts::ShapedGlyph, SystemAllocator>{memory}};
    for (std::size_t index = 0; index < initial.size(); ++index) {
      saved.push_back(initial.glyph(index));
    }

    QVERIFY(!saved.empty());
    const fonts::GlyphRasterRequest request{.index = saved.front().index, .pixel_height = pixel_height, .style = {}};
    const auto original = face.rasterize(request);
    const auto original_width = original.width;
    const auto original_height = original.height;
    const auto original_left = original.left;
    const auto original_top = original.top;
    Vector<std::uint8_t, SystemAllocator> pixels{AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
    for (std::uint32_t row = 0; row < original.height; ++row) {
      const auto coverage = original.row(row);
      pixels.insert(pixels.end(), coverage.begin(), coverage.end());
    }

    constexpr std::uint16_t pressure_height = 40;
    for (std::size_t index = 0; index <= fonts::Face::maximum_sizes; ++index) {
      static_cast<void>(face.shape(label, static_cast<std::uint16_t>(pressure_height + index)));
    }

    const auto restored = face.shape(label, pixel_height);
    QCOMPARE(restored.advance(), advance);
    QCOMPARE(restored.size(), saved.size());
    for (std::size_t index = 0; index < restored.size(); ++index) {
      QVERIFY(restored.glyph(index) == saved[index]);
    }

    const auto bitmap = face.rasterize(request);
    QCOMPARE(bitmap.width, original_width);
    QCOMPARE(bitmap.height, original_height);
    QCOMPARE(bitmap.left, original_left);
    QCOMPARE(bitmap.top, original_top);
    for (std::uint32_t row = 0; row < bitmap.height; ++row) {
      const auto coverage = bitmap.row(row);
      const auto offset = static_cast<std::size_t>(row) * bitmap.width;
      QVERIFY(std::equal(coverage.begin(), coverage.end(), pixels.begin() + static_cast<std::ptrdiff_t>(offset)));
    }
  }

  Q_SLOT static void retainsOneSourceAcrossPanelsAndScales() {
    SystemAllocator system;
    BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
    {
      FontCache cache{memory};
      FontConfiguration configuration;
      const auto initial = cache.resolve(configuration, 1);
      const auto allocations = memory.allocations();
      const auto live_bytes = memory.liveBytes();
      constexpr std::array scales{1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0, 7.0, 8.0, 1.0};
      for (const auto scale : scales) {
        const auto resolved = cache.resolve(configuration, scale);
        QCOMPARE(resolved.font.cell.width() * scale, static_cast<qreal>(resolved.grid.width));
        QCOMPARE(memory.allocations(), allocations);
      }

      configuration.thicken = true;
      configuration.thicken_strength = 0;
      QCOMPARE(cache.resolve(configuration, 1).font.cell, initial.font.cell);
      QCOMPARE(memory.allocations(), allocations);
      configuration.family.assign("Missing Telar Font Fixture");
      QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(cache.resolve(configuration, 1)));
      QCOMPARE(memory.liveBytes(), live_bytes);
      configuration.family.assign("");
      QCOMPARE(cache.resolve(configuration, 1).font.faces, initial.font.faces);
    }

    QCOMPARE(memory.liveBytes(), std::size_t{0});
  }

  Q_SLOT static void matchesCaseInsensitiveBundledNames() {
    SystemAllocator memory;
    FontConfiguration configuration;
    const auto original = FontResolver::resolve(memory, configuration, 1);
    configuration.family.assign("jEtBrAiNs MoNo");
    configuration.style.assign("rEgUlAr");
    const auto resolved = FontResolver::resolve(memory, configuration, 1);
    QCOMPARE(resolved.font.cell, original.font.cell);
    QCOMPARE(resolved.font.baseline, original.font.baseline);
    QCOMPARE(resolved.font.faces, original.font.faces);
    configuration.style.assign("Not An Installed Style");
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(FontResolver::resolve(memory, configuration, 1)));
  }

  Q_SLOT static void appliesVariableMetricsAndNamedInstances() {
    const FontConfiguration configuration;
    QFile file{QStringLiteral(":/telar/test-fonts/metrics-variable.ttf")};
    QVERIFY(file.open(QIODeviceBase::ReadOnly));
    const auto data = file.readAll();
    QVERIFY(QFontDatabase::addApplicationFontFromData(data) >= 0);
    const std::vector<std::uint8_t> bytes{data.cbegin(), data.cend()};
    fonts::Face original{bytes};
    constexpr std::uint16_t physical_height = 30;
    constexpr std::uint32_t width_axis = 0x77647468;
    constexpr float wide_coordinate = 200;
    fonts::FontMatch match{};
    match.variation.count = 1;
    match.variation.tags[0] = width_axis;
    match.variation.values[0] = wide_coordinate;
    fonts::Face wide{bytes, match};
    const auto narrow_metrics = original.metrics(physical_height);
    const auto wide_metrics = wide.metrics(physical_height);
    QVERIFY(narrow_metrics.ascender != wide_metrics.ascender);
    QVERIFY(narrow_metrics.line_height != wide_metrics.line_height);
    QVERIFY(narrow_metrics.box_stroke != wide_metrics.box_stroke);
    const auto resolved = FontResolver::resolve(wide, configuration, 2);
    QCOMPARE(resolved.grid.box_stroke, wide_metrics.box_stroke);
    QCOMPARE(resolved.font.faces.front().variableAxisValue("wdth"), wide_coordinate);
    const auto wide_raw = QRawFont::fromFont(resolved.font.faces.front());
    QVERIFY(!wide_raw.fontTable("MVAR").isEmpty());
    const auto narrow = FontResolver::resolve(original, configuration, 2);
    const auto narrow_raw = QRawFont::fromFont(narrow.font.faces.front());
    const auto wide_glyph = wide_raw.glyphIndexesForString(QStringLiteral("M"));
    const auto narrow_glyph = narrow_raw.glyphIndexesForString(QStringLiteral("M"));
    QVERIFY(wide_raw.advancesForGlyphIndexes(wide_glyph).front().x() > narrow_raw.advancesForGlyphIndexes(narrow_glyph).front().x());
    constexpr unsigned named_instance_shift = 16;
    constexpr unsigned wide_instance_index = 2;
    constexpr auto wide_instance = static_cast<std::int32_t>(wide_instance_index << named_instance_shift);
    match = {};
    match.face_index = wide_instance;
    fonts::Face named{bytes, match};
    QCOMPARE(named.variation().values[0], wide_coordinate);
    QCOMPARE(named.metrics(physical_height).line_height, wide_metrics.line_height);
    match.variation.count = 1;
    match.variation.tags[0] = width_axis;
    match.variation.values[0] = std::numeric_limits<float>::quiet_NaN();
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, (fonts::Face{bytes, match}));
  }

  Q_SLOT static void selectsCollectionFacesAndRejectsMissingNames() {
    QFile file{QStringLiteral(":/telar/test-fonts/metrics-collection.ttc")};
    QVERIFY(file.open(QIODeviceBase::ReadOnly));
    const auto data = file.readAll();
    const std::vector<std::uint8_t> bytes{data.cbegin(), data.cend()};
    fonts::FontMatch match{};
    match.face_index = 1;
    const fonts::Face indexed{bytes, match};
    QCOMPARE(indexed.family(), std::string_view{"Telar Metrics Fixture"});
    match.face_index = -1;
    constexpr std::string_view postscript = "TelarMetricsFixture-Regular";
    std::ranges::copy(postscript, std::begin(match.postscript));
    const fonts::Face named{bytes, match};
    QCOMPARE(named.family(), indexed.family());
    match.postscript[0] = 'X';
    QVERIFY_THROWS_EXCEPTION(std::runtime_error, (fonts::Face{bytes, match}));
    match = {};
    std::ranges::fill(match.postscript, 'x');
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, (fonts::Face{bytes, match}));
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  bundledFonts();
  FontResolverTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "font_resolver_test.moc"
