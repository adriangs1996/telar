#include "window_font_catalog.hpp"
#include "core/configuration.hpp"
#include "font_asset.hpp"
#include "font_collection.hpp"
#include "font_source.hpp"
#include "fonts/face.hpp"
#include "fonts/font_coverage.hpp"
#include "fonts/font_query.hpp"
#include "fonts/font_requests.hpp"
#include "fonts/font_role.hpp"
#include "fonts/native_match.hpp"
#include "resident_fonts.hpp"
#include "text/grapheme_cursor.hpp"
#include <QFutureWatcher>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QString>
#include <QtConcurrent/QtConcurrentRun>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qtmetamacros.h>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

WindowFontCatalog::WindowFontCatalog(QQuickWindow &window)
    : QObject(&window),
      collection_(std::make_shared<const FontCollection>(FontCollection{.primary = ResidentFonts::resolveSource({}, {})})) {
  connect(&task_, &QFutureWatcher<Discovery>::finished, this, &WindowFontCatalog::complete);
}

WindowFontCatalog::~WindowFontCatalog() {
  task_.disconnect(this);
  if (running_) {
    task_.waitForFinished();
  }
}

WindowFontCatalog &WindowFontCatalog::forWindow(QQuickWindow &window) {
  auto *catalog = window.findChild<WindowFontCatalog *>(QString{}, Qt::FindDirectChildrenOnly);
  if (catalog == nullptr) {
    auto created = std::make_unique<WindowFontCatalog>(window);
    catalog = created.release();
  }

  return *catalog;
}

const std::shared_ptr<const FontCollection> &WindowFontCatalog::collection() const noexcept {
  return collection_;
}

std::shared_ptr<const FontCollection> WindowFontCatalog::collectionFor(const std::shared_ptr<const FontAsset> &primary) {
  if (!primary) {
    throw std::invalid_argument{"MissingPrimaryFontAsset"};
  }

  if (primary == collection_->primary || (primary->match().path[0] != '\0' && fonts::sameFontMatch(primary->match(), collection_->primary->match()))) {
    return collection_;
  }

  for (auto entry = primary_collections_.begin(); entry != primary_collections_.end();) {
    if (entry.value().expired()) {
      entry = primary_collections_.erase(entry);
    } else {
      ++entry;
    }
  }

  auto collection = primary_collections_.value(primary.get()).lock();
  if (!collection) {
    auto updated = std::make_shared<FontCollection>(*collection_);
    updated->primary = primary;
    collection = std::move(updated);
    primary_collections_.insert(primary.get(), collection);
  }

  return collection;
}

bool WindowFontCatalog::busy() const noexcept {
  return running_;
}

void WindowFontCatalog::configure(const FontConfiguration &font) {
  const auto primary = ResidentFonts::resolveSource(QString::fromUtf8(font.family.view()), QString::fromUtf8(font.style.view()));
  if (primary == collection_->primary) {
    return;
  }

  collection_ = std::make_shared<const FontCollection>(FontCollection{.primary = primary});
  primary_collections_.clear();
  requests_ = {};
  ++generation_;
  emit fontsChanged();
}

void WindowFontCatalog::request(std::string_view text, fonts::FontRole preferred, const std::shared_ptr<const FontCollection> &collection) {
  if (collection_->count == fonts::maximum_fallback_faces) {
    return;
  }

  const auto fonts = ResidentFonts::shared(collection ? collection : collection_);
  if (fonts::FontCoverage::covers(fonts->face(preferred), text)) {
    return;
  }

  GraphemeCursor cursor{text};
  while (const auto cluster = cursor.next()) {
    if (!fonts->source(*cluster, preferred)) {
      requests_.request(*cluster);
    }
  }

  start();
}

WindowFontCatalog::Discovery WindowFontCatalog::discover(fonts::FontQuery query, std::uint64_t generation) {
  Discovery result{.query = query, .source = {}, .generation = generation};
  try {
    const auto data = loadFallbackFontData(query);
    if (data) {
      auto source = std::make_shared<const FontAsset>(*data);
      const fonts::Face face{source->bytes(), source->match()};
      if (face.monochrome() && fonts::FontCoverage::covers(face, query.text())) {
        result.source = std::move(source);
      }
    }
  } catch (const std::exception &) {
    return result;
  }

  return result;
}

void WindowFontCatalog::start() {
  if (running_) {
    return;
  }

  const auto query = requests_.take();
  if (!query) {
    return;
  }

  try {
    const auto future = QtConcurrent::run([query = *query, generation = generation_] {
      return discover(query, generation);
    });
    running_ = true;
    task_.setFuture(future);
  } catch (const std::exception &) {
    static_cast<void>(requests_.finish(*query, false));
  }
}

bool WindowFontCatalog::adopt(const Discovery &result) {
  if (!result.source || collection_->count == fonts::maximum_fallback_faces) {
    return false;
  }

  for (std::size_t index = 0; index < collection_->count; ++index) {
    if (fonts::sameFontMatch(result.source->match(), collection_->fallback[index]->match())) {
      return false;
    }
  }

  auto updated = std::make_shared<FontCollection>(*collection_);
  updated->fallback[updated->count++] = result.source;
  collection_ = std::move(updated);
  primary_collections_.clear();

  return true;
}

void WindowFontCatalog::complete() {
  const QPointer<WindowFontCatalog> lifetime{this};
  running_ = false;
  const auto result = task_.result();
  if (result.generation == generation_) {
    bool changed = false;
    try {
      changed = adopt(result);
    } catch (const std::exception &) {
      changed = false;
    }

    if (requests_.finish(result.query, changed)) {
      emit fontsChanged();
    }
  }

  if (lifetime) {
    start();
  }
}

}
