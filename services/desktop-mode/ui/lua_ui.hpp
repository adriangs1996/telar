#pragma once

#include <functional>
#include <memory>
#include <span>
#include <string_view>
#include <QVariantMap>

namespace ui {
  struct Services;
}

struct QuickSurface;
class QString;

namespace ui {
  class LuaUi final {
  public:
    explicit LuaUi(ui::Services &services, QuickSurface *surface = nullptr);
    ~LuaUi();

    LuaUi(const LuaUi &) = delete;
    LuaUi &operator=(const LuaUi &) = delete;

    void prepare(std::string_view source,
                 std::string_view chunk_name,
                 const QString &directory,
                 const QVariantMap &surface_config = {},
                 const QString &prefix = QStringLiteral("ctrl+b"));
    static void commit(std::span<LuaUi *const> environments);
    void discard();
    QVariantMap preparedSettings() const;
    QString preparedPrefix() const;
    void setReloadHandler(std::function<void()> handler);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace ui
