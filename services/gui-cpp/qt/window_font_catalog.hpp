#pragma once

#include "core/configuration.hpp"
#include "font_asset.hpp"
#include "font_collection.hpp"
#include "fonts/font_query.hpp"
#include "fonts/font_requests.hpp"
#include "fonts/font_role.hpp"
#include <QFutureWatcher>
#include <QHash>
#include <QObject>
#include <QQuickWindow>
#include <QtCore/qtmetamacros.h>
#include <cstdint>
#include <memory>
#include <optional>
#include <string_view>

namespace telar::gui::qt {

class WindowFontCatalog final : public QObject {
  Q_OBJECT

public:
  explicit WindowFontCatalog(QQuickWindow &window);
  ~WindowFontCatalog() override;
  WindowFontCatalog(const WindowFontCatalog &) = delete;
  WindowFontCatalog &operator=(const WindowFontCatalog &) = delete;
  WindowFontCatalog(WindowFontCatalog &&) = delete;
  WindowFontCatalog &operator=(WindowFontCatalog &&) = delete;
  [[nodiscard]] static WindowFontCatalog &forWindow(QQuickWindow &window);
  [[nodiscard]] const std::shared_ptr<const FontCollection> &collection() const noexcept;
  [[nodiscard]] std::shared_ptr<const FontCollection> collectionFor(const std::shared_ptr<const FontAsset> &primary);
  [[nodiscard]] bool busy() const noexcept;
  void configure(const FontConfiguration &font);
  void request(std::string_view text, fonts::FontRole preferred, const std::shared_ptr<const FontCollection> &collection = {});

signals:
  void fontsChanged();

private:
  struct Discovery {
    fonts::FontQuery query;
    std::shared_ptr<const FontAsset> source;
    std::uint64_t generation = 0;
  };

  [[nodiscard]] static Discovery discover(fonts::FontQuery query, std::uint64_t generation);
  [[nodiscard]] bool adopt(const Discovery &result);
  void start();
  void complete();

  std::shared_ptr<const FontCollection> collection_;
  QHash<const FontAsset *, std::weak_ptr<const FontCollection>> primary_collections_;
  fonts::FontRequests requests_;
  QFutureWatcher<Discovery> task_;
  std::uint64_t generation_ = 0;
  bool running_ = false;
};

}
