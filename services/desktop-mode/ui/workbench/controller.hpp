#pragma once

#include <QObject>
#include <QVariantMap>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>

namespace ui {
  class DesktopUi;
}

namespace workbench {
  class Controller final : public QObject {
  public:
    explicit Controller(ui::DesktopUi &desktop);
    ~Controller() override;
    QVariantMap state() const;
    QVariant command(const QString &action, const QVariantMap &options);
    // The display the backstage switcher is open on, if it is open.
    std::optional<std::uint32_t> switcherDisplay() const;
    std::uint64_t subscribe(std::function<void()> callback);
    void unsubscribe(std::uint64_t identifier);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace workbench
