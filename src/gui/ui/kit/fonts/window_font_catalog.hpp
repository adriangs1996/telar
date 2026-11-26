#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "font_asset.hpp"
#include "font_collection.hpp"
#include "platform/font.h"
#include <QFutureWatcher>
#include <QHash>
#include <QObject>
#include <QQuickWindow>
#include <QtCore/qtmetamacros.h>
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <freetype/freetype.h>
#include <functional>
#include <hb.h>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>
#include <utility>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  class WindowFontCatalog final : public QObject {
    Q_OBJECT

  public:
    explicit WindowFontCatalog(QQuickWindow& window);
    ~WindowFontCatalog() override;
    WindowFontCatalog(const WindowFontCatalog&) = delete;
    WindowFontCatalog& operator=(const WindowFontCatalog&) = delete;
    WindowFontCatalog(WindowFontCatalog&&) = delete;
    WindowFontCatalog& operator=(WindowFontCatalog&&) = delete;
    [[nodiscard]] static WindowFontCatalog& forWindow(QQuickWindow& window);
    [[nodiscard]] const std::shared_ptr<const FontCollection>& collection() const noexcept;
    [[nodiscard]] std::shared_ptr<const FontCollection> collectionFor(const std::shared_ptr<const FontAsset>& primary);
    [[nodiscard]] bool busy() const noexcept;
    void configure(const FontConfiguration& font);
    void request(std::string_view text, fonts::FontRole preferred, const std::shared_ptr<const FontCollection>& collection = {});

  signals:
    void fontsChanged();

  private:
    struct Discovery {
      fonts::FontQuery query;
      std::shared_ptr<const FontAsset> source;
      std::uint64_t generation = 0;
    };

    [[nodiscard]] static Discovery discover(fonts::FontQuery query, std::uint64_t generation);
    [[nodiscard]] bool adopt(const Discovery& result);
    void start();
    void complete();

    std::shared_ptr<const FontCollection> collection_;
    QHash<const FontAsset*, std::weak_ptr<const FontCollection>> primary_collections_;
    fonts::FontRequests requests_;
    QFutureWatcher<Discovery> task_;
    std::uint64_t generation_ = 0;
    bool running_ = false;
  };

}
