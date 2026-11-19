#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "platform/font.h"
#include "qt_case.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/fonts/font_cache.hpp"
#include "ui/foundation/fonts/font_resolver.hpp"
#include "ui/foundation/fonts/font_source.hpp"
#include "ui/foundation/fonts/resident_fonts.hpp"
#include "ui/foundation/fonts/terminal_font.hpp"
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
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {

  using namespace telar::gui;
  using namespace telar::gui::qt;

  std::uint64_t ink(fonts::GlyphBitmapView bitmap) {
    std::uint64_t coverage = 0;

    for (std::uint32_t row = 0; row < bitmap.height; ++row) {
      for (const auto value : bitmap.row(row)) {
        coverage += value;
      }
    }

    return coverage;
  }

  // The pixels a glyph covers only in part.
  std::uint64_t partial(fonts::GlyphBitmapView bitmap) {
    std::uint64_t count = 0;

    for (std::uint32_t row = 0; row < bitmap.height; ++row) {
      for (const auto value : bitmap.row(row)) {
        count += value != 0 && value != std::numeric_limits<std::uint8_t>::max() ? 1 : 0;
      }
    }

    return count;
  }

  class FontResolverTest final : public QObject {
    Q_OBJECT

  private:
    Q_SLOT static void initTestCase() {
      bundledFonts();
    }

    Q_SLOT static void fallbackFacesCanBeRasterized() {
      std::size_t checked = 0;

      for (const auto* text : {"λ", "á", "漢", "字", "中"}) {
        const auto query = fonts::FontQuery::create(text);
        if (!query) {
          QFAIL("Fallback fixture must contain a valid grapheme");
        }

        fonts::FontMatch native{};
        if (telarGuiFindFallbackFont(query->codepoints(), &native) != telar_font_found) {
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

      QVERIFY(telarGuiFindFallbackFont("λ", &expected) == telar_font_found);
      fonts::FontMatch accepted{};
      const auto allow = [](const telar_font_match*, void*) -> int {
        return telar_font_found;
      };

      QCOMPARE(telarGuiFindValidatedFallbackFont("λ", &accepted, allow, nullptr), telar_font_found);
      QVERIFY(fonts::sameFontMatch(expected, accepted));
      std::size_t rejected = 0;
      const auto reject = [](const telar_font_match*, void* context) -> int {
        ++*static_cast<std::size_t*>(context);

        return telar_font_family_not_found;
      };

      QCOMPARE(telarGuiFindValidatedFallbackFont("λ", &accepted, reject, &rejected), telar_font_family_not_found);
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
      constexpr telar::ds::Array sizes{6.0F, 7.5F, 15.0F, 18.5F, 48.0F, 96.0F};
      constexpr telar::ds::Array scales{0.75, 1.0, 1.25, 1.5, 2.0, 4.0, 8.0};
      constexpr telar::ds::Array line_heights{0.75F, 1.0F, 1.2F, 1.5F, 3.0F};
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
      telar::ds::Vec<fonts::ShapedGlyph, SystemAllocator> saved{memory};

      for (std::size_t index = 0; index < initial.size(); ++index) {
        saved.push(initial.glyph(index));
      }

      QVERIFY(!saved.empty());
      const fonts::GlyphRasterRequest request{.index = saved.front().index, .pixel_height = pixel_height, .style = {}};
      const auto original = face.rasterize(request);
      const auto original_width = original.width;
      const auto original_height = original.height;
      const auto original_left = original.left;
      const auto original_top = original.top;
      telar::ds::Vec<std::uint8_t, SystemAllocator> pixels{memory};

      for (std::uint32_t row = 0; row < original.height; ++row) {
        const auto coverage = original.row(row);

        pixels.extend(coverage);
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

    Q_SLOT static void thickeningChangesInkWithoutChangingShapingOrMetrics() {
      SystemAllocator memory;
      const FontSource source{memory, FontConfiguration{}};
      fonts::Face face{source.bytes(), source.match()};
      constexpr telar::ds::Array<std::uint16_t, 4> heights{13, 26, 39, 96};
      constexpr telar::ds::Array styles{fonts::GlyphStyle{.bold = false}, fonts::GlyphStyle{.bold = true}, fonts::GlyphStyle{.italic = true}, fonts::GlyphStyle{.bold = true, .italic = true}};
      constexpr std::uint8_t medium_strength = 128;

      for (const auto height : heights) {
        const auto shaped = face.shape("M", height);
        const auto glyph = shaped.glyph(0);
        const auto advance = shaped.advance();
        const auto metrics = face.metrics(height);

        for (const auto style : styles) {
          fonts::GlyphRasterRequest request{.index = glyph.index, .pixel_height = height, .style = style};
          const auto plain = ink(face.rasterize(request));

          request.thicken_strength = medium_strength;
          const auto medium = ink(face.rasterize(request));

          request.thicken_strength = FontConfiguration::maximum_thicken_strength;
          const auto strong = ink(face.rasterize(request));

          QVERIFY(medium > plain);
          QVERIFY(strong > medium);
          request.thicken_strength = 0;
          QCOMPARE(ink(face.rasterize(request)), plain);
        }

        // Grid fitting concentrates the crossbar and stems of "H" into whole pixels.
        const auto bar = face.shape("H", height).glyph(0).index;
        const auto native_partial = partial(face.rasterize({.index = bar, .pixel_height = height}));
        const auto full = face.rasterize({.index = bar, .pixel_height = height, .hinting = fonts::GlyphHinting::full});

        QVERIFY(ink(full) > 0);
        QVERIFY(partial(full) <= native_partial);

        const auto restored = face.shape("M", height);

        QVERIFY(restored.glyph(0) == glyph);
        QCOMPARE(restored.advance(), advance);
        QCOMPARE(face.metrics(height).maximum_advance, metrics.maximum_advance);
        QCOMPARE(face.metrics(height).line_height, metrics.line_height);
        QCOMPARE(face.metrics(height).ascender, metrics.ascender);
        const auto space = face.shape(" ", height).glyph(0).index;

        QCOMPARE(ink(face.rasterize({.index = space, .pixel_height = height, .style = {}, .thicken_strength = FontConfiguration::maximum_thicken_strength})), std::uint64_t{0});
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
        constexpr telar::ds::Array scales{1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 6.0, 7.0, 8.0, 1.0};

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

      configuration.family.assign("tElAr FoRmA");
      configuration.style.assign("rEgUlAr");
      const auto resolved = FontResolver::resolve(memory, configuration, 1);

      QCOMPARE(resolved.font.cell, original.font.cell);
      QCOMPARE(resolved.font.baseline, original.font.baseline);
      QCOMPARE(resolved.font.faces, original.font.faces);
      configuration.style.assign("Not An Installed Style");
      QVERIFY_THROWS_EXCEPTION(std::runtime_error, static_cast<void>(FontResolver::resolve(memory, configuration, 1)));

      configuration.family.assign("JetBrains Mono");
      configuration.style.assign("");
      const auto jetbrains = FontResolver::resolve(memory, configuration, 1);

      configuration.family.assign("jEtBrAiNs MoNo");
      configuration.style.assign("rEgUlAr");
      QCOMPARE(FontResolver::resolve(memory, configuration, 1).font.faces, jetbrains.font.faces);
    }

    Q_SLOT static void defaultsToBundledFormaAcrossRenderers() {
      const auto expected = loadFontBytes(QStringLiteral(":/telar/fonts/TelarForma-Regular.ttf"));
      const FontConfiguration configuration;

      QCOMPARE(loadFontData(configuration).bytes, expected);
      QCOMPARE(bundledFonts().front(), QStringLiteral("Telar Forma"));

      const auto source = ResidentFonts::resolveSource({}, {});

      QCOMPARE(source, ResidentFonts::resolveSource(QStringLiteral("Telar Forma"), {}));
      QVERIFY(std::ranges::equal(source->bytes(), telar::byteView({expected.constData(), static_cast<std::size_t>(expected.size())})));
      const auto resident = ResidentFonts::shared(source);

      QCOMPARE(resident->face(fonts::FontRole::primary).family(), std::string_view{"Telar Forma"});
      QCOMPARE(resident->face(fonts::FontRole::text).family(), std::string_view{"JetBrains Mono"});

      const auto terminal = TerminalFont::resolve({}, 1);

      QCOMPARE(QRawFont::fromFont(terminal.faces.front()).familyName(), QStringLiteral("Telar Forma"));

      SystemAllocator memory;
      const auto resolved = FontResolver::resolve(memory, configuration, 1);

      QCOMPARE(QRawFont::fromFont(resolved.font.faces.front()).familyName(), QStringLiteral("Telar Forma"));
    }

    Q_SLOT static void loadsBundledFormaFromResources() {
      const auto expected = loadFontBytes(QStringLiteral(":/telar/fonts/TelarForma-Regular.ttf"));

      QVERIFY(QFontDatabase::hasFamily(QStringLiteral("Telar Forma")));

      for (const auto* family : {"Telar Forma", "tElAr FoRmA"}) {
        FontConfiguration configuration;

        configuration.family.assign(family);

        for (const auto* style : {"", "Regular", "rEgUlAr"}) {
          configuration.style.assign(style);
          const auto data = loadFontData(configuration);

          QCOMPARE(data.bytes, expected);

          fonts::Face face{telar::byteView({data.bytes.constData(), static_cast<std::size_t>(data.bytes.size())}), data.match};

          QCOMPARE(face.family(), std::string_view{"Telar Forma"});
          QCOMPARE(face.style(), std::string_view{"Regular"});
          QVERIFY(face.fixedPitch());
          QVERIFY(fonts::FontCoverage::covers(face, "JSON July IJj J1l @J áéíóú ñ"));

          const auto resolved = FontResolver::resolve(face, configuration, 1);
          const auto raw = QRawFont::fromFont(resolved.font.faces.front());

          QCOMPARE(raw.familyName(), QStringLiteral("Telar Forma"));
          QVERIFY(resolved.font.fixed_pitch);
          QVERIFY(resolved.font.cell.width() > 0);
          QVERIFY(resolved.font.cell.height() > 0);
        }
      }
    }

    Q_SLOT static void rejectsUnavailableBundledFormaStyles() {
      FontConfiguration configuration;

      configuration.family.assign("Telar Forma");
      configuration.style.assign("SemiBold");

      try {
        static_cast<void>(loadFontData(configuration));
        QFAIL("A missing bundled style must not depend on installed fonts");
      } catch (const std::runtime_error& error) {
        QCOMPARE(QString::fromUtf8(error.what()), QStringLiteral("FontStyleNotFound"));
      }
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
      // The wide master scales every advance by 3/2; cells follow the variation's ASCII advances.
      constexpr std::uint16_t narrow_cell = 18;
      constexpr std::uint16_t wide_cell = 27;

      QCOMPARE(narrow_metrics.maximum_advance, narrow_cell);
      QCOMPARE(wide_metrics.maximum_advance, wide_cell);
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

    Q_SLOT static void sizesCellsByAsciiInsteadOfWidestGlyph() {
      QFile file{QStringLiteral(":/telar/test-fonts/metrics-wide-glyph.ttf")};

      QVERIFY(file.open(QIODeviceBase::ReadOnly));
      const auto data = file.readAll();
      const std::vector<std::uint8_t> bytes{data.cbegin(), data.cend()};
      fonts::Face face{bytes};
      // 600 of 1000 units at 30 px; the em dash's 1200 units must not double the cell.
      constexpr std::uint16_t height = 30;
      constexpr std::uint16_t cell = 18;

      QCOMPARE(face.metrics(height).maximum_advance, cell);
      QCOMPARE(FontGrid::resolve(face.metrics(height), FontConfiguration{}, 1).width, cell);
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

  using telar::gui::test::QtCase;

  const QtCase<FontResolverTest, "fallbackFacesCanBeRasterized"> case_fallback_faces_can_be_rasterized{"font_resolver.fallback_faces_can_be_rasterized"};
  const QtCase<FontResolverTest, "nativeFallbackHonorsClientValidation"> case_native_fallback_honors_client_validation{"font_resolver.native_fallback_honors_client_validation"};
  const QtCase<FontResolverTest, "preservesPhysicalBaseline"> case_preserves_physical_baseline{"font_resolver.preserves_physical_baseline"};
  const QtCase<FontResolverTest, "preservesFractionalScaleAndLineSpacing"> case_preserves_fractional_scale_and_line_spacing{"font_resolver.preserves_fractional_scale_and_line_spacing"};
  const QtCase<FontResolverTest, "respectsAllocatorOwnershipAndFailure"> case_respects_allocator_ownership_and_failure{"font_resolver.respects_allocator_ownership_and_failure"};
  const QtCase<FontResolverTest, "preservesShapingAndRasterAfterSizeCacheEviction"> case_preserves_shaping_and_raster_after_size_cache_eviction{"font_resolver.preserves_shaping_and_raster_after_size_cache_eviction"};
  const QtCase<FontResolverTest, "thickeningChangesInkWithoutChangingShapingOrMetrics"> case_thickening_changes_ink_without_changing_shaping_or_metrics{"font_resolver.thickening_changes_ink_without_changing_shaping_or_metrics"};
  const QtCase<FontResolverTest, "retainsOneSourceAcrossPanelsAndScales"> case_retains_one_source_across_panels_and_scales{"font_resolver.retains_one_source_across_panels_and_scales"};
  const QtCase<FontResolverTest, "matchesCaseInsensitiveBundledNames"> case_matches_case_insensitive_bundled_names{"font_resolver.matches_case_insensitive_bundled_names"};
  const QtCase<FontResolverTest, "defaultsToBundledFormaAcrossRenderers"> case_defaults_to_bundled_forma_across_renderers{"font_resolver.defaults_to_bundled_forma_across_renderers"};
  const QtCase<FontResolverTest, "loadsBundledFormaFromResources"> case_loads_bundled_forma_from_resources{"font_resolver.loads_bundled_forma_from_resources"};
  const QtCase<FontResolverTest, "rejectsUnavailableBundledFormaStyles"> case_rejects_unavailable_bundled_forma_styles{"font_resolver.rejects_unavailable_bundled_forma_styles"};
  const QtCase<FontResolverTest, "appliesVariableMetricsAndNamedInstances"> case_applies_variable_metrics_and_named_instances{"font_resolver.applies_variable_metrics_and_named_instances"};
  const QtCase<FontResolverTest, "sizesCellsByAsciiInsteadOfWidestGlyph"> case_sizes_cells_by_ascii_instead_of_widest_glyph{"font_resolver.sizes_cells_by_ascii_instead_of_widest_glyph"};
  const QtCase<FontResolverTest, "selectsCollectionFacesAndRejectsMissingNames"> case_selects_collection_faces_and_rejects_missing_names{"font_resolver.selects_collection_faces_and_rejects_missing_names"};

}

#include "font_resolver_test.moc"
#include "telar_base/ds/containers.hpp"
#include "telar_base/ds/values.hpp"
