#pragma once

#include "shortcuts.hpp"
#include <QVariantMap>

namespace lua {
  struct Environment;
}

namespace ui {
  class ShortcutBinding final {
  public:
    struct Activation {
      ShortcutBinding *candidate;
      const ShortcutBinding *previous;
    };

    ShortcutBinding(lua::Environment &environment, Shortcuts &shortcuts);
    ~ShortcutBinding();
    static void activate(std::span<const Activation> activations);
    void deactivate();
    void setPrefix(const QString &prefix);
    // A releasing binding also calls back, with true, once its modifiers come up.
    std::uint64_t bind(const QVariantList &keys, bool global, int callback, bool releasing);
    void unbind(std::uint64_t id);
    QVariantMap state() const;

  private:
    struct Entry {
      std::uint64_t id;
      std::vector<std::string> keys;
      bool global;
      int callback;
      bool releasing;
    };

    lua::Environment &environment_;
    Shortcuts &shortcuts_;
    std::string prefix_ = "ctrl+b";
    std::vector<Entry> entries_;
    bool active_ = false;
    std::vector<Shortcuts::Binding> bindings(const std::string &prefix,
                                             const std::vector<Entry> &entries);
    void update(const std::string &prefix, const std::vector<Entry> &entries);
    void deliver(int callback, bool released);
  };
} // namespace ui
