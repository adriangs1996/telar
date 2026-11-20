#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "resident_fonts.hpp"
#include "chrome_fonts.hpp"
#include "font_asset.hpp"
#include "font_collection.hpp"
#include "font_source.hpp"
#include "telar_base/ds/values.hpp"
#include <QHash>
#include <QString>
#include <QtCore/qstringliteral.h>
#include <array>
#include <cstddef>
#include <cstring>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui::qt {
  namespace {

    std::shared_ptr<const FontAsset> checkedPrimary(const std::shared_ptr<const FontCollection>& collection) {
      if (!collection || !collection->primary || collection->count > fonts::maximum_fallback_faces) {
        throw std::invalid_argument{"InvalidFontCollection"};
      }

      for (std::size_t index = 0; index < collection->count; ++index) {
        if (!collection->fallback[index]) {
          throw std::invalid_argument{"MissingFallbackFontAsset"};
        }
      }

      return collection->primary;
    }

    std::shared_ptr<const FontAsset> textSource() {
      [[clang::no_destroy]] static const auto source = std::make_shared<const FontAsset>(FontData{.bytes = loadFontBytes(QStringLiteral(":/telar/fonts/JetBrainsMono-Regular.ttf"))});

      return source;
    }

    std::shared_ptr<const FontAsset> symbolSource() {
      [[clang::no_destroy]] static const auto source = std::make_shared<const FontAsset>(FontData{.bytes = loadFontBytes(QStringLiteral(":/telar/fonts/SymbolsNerdFontMono-Regular.ttf"))});

      return source;
    }

    template <typename Cache>
    void forgetExpired(Cache& cache) {
      for (auto entry = cache.begin(); entry != cache.end();) {
        if (entry.value().expired()) {
          entry = cache.erase(entry);
        } else {
          ++entry;
        }
      }
    }

  }

  ResidentFonts::ResidentFonts(std::shared_ptr<const FontAsset> source)
      : primary_source_(std::move(source)),
        text_source_(textSource()),
        symbols_source_(symbolSource()),
        chrome_(ChromeFonts::shared()),
        primary_(primary_source_->bytes(), primary_source_->match()),
        text_(text_source_->bytes()),
        symbols_(symbols_source_->bytes()) {}

  ResidentFonts::ResidentFonts(std::shared_ptr<const FontCollection> collection)
      : ResidentFonts(checkedPrimary(collection)) {
    collection_ = std::move(collection);
    for (std::size_t index = 0; index < collection_->count; ++index) {
      const auto& source = *collection_->fallback[index];

      fallbacks_.atMut(index).emplace(source.bytes(), source.match());
    }
  }

  fonts::Face& ResidentFonts::face(fonts::FontRole role) {
    switch (role) {
    case fonts::FontRole::regular:
    case fonts::FontRole::emphasized:
      return chrome_->face(role);
    case fonts::FontRole::primary:
      return primary_;
    case fonts::FontRole::text:
      return text_;
    case fonts::FontRole::symbols:
      return symbols_;
    case fonts::FontRole::fallback_0:
    case fonts::FontRole::fallback_1:
    case fonts::FontRole::fallback_2:
    case fonts::FontRole::fallback_3:
    case fonts::FontRole::fallback_4:
    case fonts::FontRole::fallback_5:
    case fonts::FontRole::fallback_6:
    case fonts::FontRole::fallback_7:
      break;
    }

    // fallbackIndex rejects every role but a fallback one, a value outside the enum included.
    if (const auto index = fonts::fallbackIndex(role); index && *index < fallbackCount()) {
      auto& face = fallbacks_.atMut(*index);
      if (face) {
        return face.getMut();
      }
    }

    throw std::invalid_argument{"InvalidResidentFontRole"};
  }

  std::size_t ResidentFonts::fallbackCount() const noexcept {
    return collection_ ? collection_->count : 0;
  }

  const FontAsset& ResidentFonts::asset(fonts::FontRole role) const {
    switch (role) {
    case fonts::FontRole::primary:
      return *primary_source_;
    case fonts::FontRole::text:
      return *text_source_;
    case fonts::FontRole::symbols:
      return *symbols_source_;
    case fonts::FontRole::regular:
    case fonts::FontRole::emphasized:
    case fonts::FontRole::fallback_0:
    case fonts::FontRole::fallback_1:
    case fonts::FontRole::fallback_2:
    case fonts::FontRole::fallback_3:
    case fonts::FontRole::fallback_4:
    case fonts::FontRole::fallback_5:
    case fonts::FontRole::fallback_6:
    case fonts::FontRole::fallback_7:
      break;
    }

    // fallbackIndex rejects every role but a fallback one, a value outside the enum included.
    if (const auto index = fonts::fallbackIndex(role); index && *index < fallbackCount()) {
      return *collection_->fallback[*index];
    }

    throw std::invalid_argument{"MissingNativeFontAsset"};
  }

  ds::Option<fonts::FontRole> ResidentFonts::source(std::string_view text, fonts::FontRole preferred) {
    return fonts::FontCascade::source(*this, text, preferred);
  }

  std::shared_ptr<const FontAsset> ResidentFonts::resolveSource(const QString& family, const QString& style) {
// A thread that exits must drop its weak references, or the fonts' shared allocations leak with it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wexit-time-destructors"
    thread_local QHash<std::pair<QString, QString>, std::weak_ptr<const FontAsset>> sources;
#pragma clang diagnostic pop

    forgetExpired(sources);
    const std::pair key{family.isEmpty() ? QStringLiteral("Telar Forma") : family, style};
    auto source = sources.value(key).lock();
    if (!source) {
      FontConfiguration configuration;

      configuration.family.assign(key.first.toStdString());
      configuration.style.assign(style.toStdString());
      source = std::make_shared<const FontAsset>(loadFontData(configuration));
      sources.insert(key, source);
    }

    return source;
  }

  tbc::val_static<std::shared_ptr<ResidentFonts>> ResidentFonts::shared(const std::shared_ptr<const FontAsset>& source) {
// A thread that exits must drop its weak references, or the fonts' shared allocations leak with it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wexit-time-destructors"
    thread_local QHash<const FontAsset*, std::weak_ptr<ResidentFonts>> cached;
#pragma clang diagnostic pop

    forgetExpired(cached);
    auto fonts = cached.value(source.get()).lock();
    if (!fonts) {
      fonts = std::make_shared<ResidentFonts>(source);
      cached.insert(source.get(), fonts);
    }

    return fonts;
  }

  tbc::val_static<std::shared_ptr<ResidentFonts>> ResidentFonts::shared(const std::shared_ptr<const FontCollection>& collection) {
    if (!collection || !collection->primary || collection->count > fonts::maximum_fallback_faces) {
      throw std::invalid_argument{"InvalidFontCollection"};
    }

    if (collection->count == 0) {
      return shared(collection->primary);
    }

// A thread that exits must drop its weak references, or the fonts' shared allocations leak with it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wexit-time-destructors"
    thread_local QHash<const FontCollection*, std::weak_ptr<ResidentFonts>> cached;
#pragma clang diagnostic pop

    forgetExpired(cached);
    auto fonts = cached.value(collection.get()).lock();
    if (!fonts) {
      fonts = std::make_shared<ResidentFonts>(collection);
      cached.insert(collection.get(), fonts);
    }

    return fonts;
  }

}
