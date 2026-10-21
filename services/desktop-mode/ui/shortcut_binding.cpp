#include "shortcut_binding.hpp"
#include "lua_environment.hpp"
#include <QDebug>
#include <algorithm>
#include <stdexcept>

namespace ui {
  ShortcutBinding::ShortcutBinding(lua::Environment &environment, Shortcuts &shortcuts)
      : environment_(environment),
        shortcuts_(shortcuts) {}

  ShortcutBinding::~ShortcutBinding() {
    deactivate();

    for (const auto &entry : entries_) {
      environment_.releaseReference(entry.callback);
    }
  }

  std::vector<Shortcuts::Binding> ShortcutBinding::bindings(const std::string &prefix,
                                                            const std::vector<Entry> &entries) {
    std::vector<Shortcuts::Binding> result;
    result.reserve(entries.size());

    for (const auto &entry : entries) {
      auto keys = entry.keys;

      if (!entry.global) {
        keys.insert(keys.begin(), prefix);
      }

      result.push_back({entry.id, std::move(keys), [this, callback = entry.callback] {
                          deliver(callback);
                        }});
    }

    return result;
  }

  void ShortcutBinding::update(const std::string &prefix, const std::vector<Entry> &entries) {
    const auto values = bindings(prefix, entries);

    if (active_) {
      shortcuts_.install(this, prefix, values);
    } else {
      shortcuts_.validate(prefix, values);
    }
  }

  void ShortcutBinding::activate(const ShortcutBinding *replacing) {
    // Reloading a surface without shortcuts must not reset another surface's pending prefix.
    if (!entries_.empty() || (replacing && !replacing->entries_.empty())) {
      shortcuts_.install(this, prefix_, bindings(prefix_, entries_), replacing);
    }

    active_ = true;
  }

  void ShortcutBinding::deactivate() {
    if (active_) {
      shortcuts_.remove(this);
      active_ = false;
    }
  }

  void ShortcutBinding::setPrefix(const QString &prefix) {
    const auto text = prefix.toStdString();
    update(text, entries_);
    prefix_ = text;
  }

  std::uint64_t ShortcutBinding::bind(const QVariantList &keys, bool global, int callback) {
    const auto limit = global ? 1 : keybindings::maxSequenceLength - 1;

    if (keys.empty() || static_cast<std::size_t>(keys.size()) > limit ||
        entries_.size() == keybindings::maxBindings) {
      throw std::runtime_error(
          "Shortcuts accept 1–4 suffix keys, or one global chord; maximum 256 bindings");
    }

    Entry entry{shortcuts_.nextId(), {}, global, callback};

    for (const auto &key : keys) {
      if (key.metaType().id() != QMetaType::QString) {
        throw std::runtime_error("Shortcut keys must be strings");
      }

      entry.keys.push_back(key.toString().toStdString());
    }

    auto candidate = entries_;
    candidate.push_back(entry);
    update(prefix_, candidate);
    entries_.swap(candidate);
    return entry.id;
  }

  void ShortcutBinding::unbind(std::uint64_t id) {
    const auto found = std::ranges::find(entries_, id, &Entry::id);

    if (found == entries_.end()) {
      return;
    }

    const int callback = found->callback;
    auto candidate = entries_;
    std::erase_if(candidate, [id](const auto &entry) {
      return entry.id == id;
    });
    update(prefix_, candidate);
    entries_.swap(candidate);
    environment_.releaseReference(callback);
  }

  QVariantMap ShortcutBinding::state() const {
    return {{"available", shortcuts_.status.available},
            {"error", QString::fromStdString(shortcuts_.status.error)},
            {"prefix", QString::fromStdString(prefix_)},
            {"pending", shortcuts_.pending()}};
  }

  void ShortcutBinding::deliver(int callback) {
    if (!active_) {
      return;
    }

    try {
      environment_.withState(
          [](lua_State *state) -> int {
            const auto reference = *static_cast<int *>(lua_touserdata(state, 1));
            lua_pushcfunction(state, lua::Environment::traceback);
            lua_rawgeti(state, LUA_REGISTRYINDEX, reference);

            if (lua_pcall(state, 0, 0, 2) != 0) {
              return lua_error(state);
            }

            return 0;
          },
          &callback);
    } catch (const std::exception &error) {
      qWarning() << "Desktop shortcut callback failed:" << error.what();
    }
  }
} // namespace ui
