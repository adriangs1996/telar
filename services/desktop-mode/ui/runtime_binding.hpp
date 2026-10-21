#pragma once

#include <QVariantMap>
#include <cstdint>
#include <memory>

class RuntimeSession;
class DesktopSession;

namespace lua {
  struct Environment;
}

namespace ui {
  class RuntimeBinding final {
  public:
    RuntimeBinding(lua::Environment &environment, RuntimeSession &session, DesktopSession &desktop);
    ~RuntimeBinding();

    void activate();
    void deactivate();
    QVariantMap state() const;
    QVariantMap desktopState() const;
    std::uint64_t subscribe(int callback, bool desktop = false);
    void unsubscribe(std::uint64_t identifier);
    QString selectTab(const QVariant &tab);
    QString moveTab(const QVariant &tab, const QVariantMap &options);
    void activateSpace(const QVariant &space);
    void bindSpace(const QVariant &space, const QVariant &workspace);
    QString createSpace(const QVariantMap &options);
    QString removeSpace(const QVariant &space);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace ui
