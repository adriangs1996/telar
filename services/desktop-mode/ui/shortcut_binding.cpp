#include "shortcut_binding.hpp"
#include "lua_environment.hpp"
#include "../trace.hpp"
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

      Shortcuts::Binding binding{entry.id, std::move(keys), [this, callback = entry.callback] {
                                   deliver(callback, false);
                                 }};

      if (entry.releasing) {
        binding.release = [this, callback = entry.callback] {
          deliver(callback, true);
        };
      }

      result.push_back(std::move(binding));
    }

    return result;
  }

  void ShortcutBinding::update(const std::string &prefix, const std::vector<Entry> &entries) {
    TELAR_TRACE("lua.shortcuts.update");
    const auto values = bindings(prefix, entries);

    if (active_) {
      shortcuts_.install(this, prefix, values);
    } else {
      shortcuts_.validate(prefix, values);
    }
  }

  void ShortcutBinding::activate(std::span<const Activation> activations) {
    TELAR_TRACE("lua.shortcuts.activate");
    if (activations.empty()) {
      return;
    }

    auto &shortcuts = activations.front().candidate->shortcuts_;
    std::vector<Shortcuts::Replacement> replacements;
    replacements.reserve(activations.size());

    for (const auto &activation : activations) {
      auto &candidate = *activation.candidate;

      if (&candidate.shortcuts_ != &shortcuts) {
        throw std::runtime_error("UI generations must share the shortcut service");
      }

      replacements.push_back({&candidate,
                              activation.previous,
                              candidate.prefix_,
                              candidate.bindings(candidate.prefix_, candidate.entries_)});
    }

    shortcuts.replace(replacements);

    for (const auto &activation : activations) {
      activation.candidate->active_ = true;
    }
  }

  void ShortcutBinding::deactivate() {
    TELAR_TRACE("lua.shortcuts.deactivate");
    if (active_) {
      shortcuts_.remove(this);
      active_ = false;
    }
  }

  void ShortcutBinding::setPrefix(const QString &prefix) {
    TELAR_TRACE("lua.shortcuts.set_prefix");
    const auto text = prefix.toStdString();
    update(text, entries_);
    prefix_ = text;
  }

  std::uint64_t
  ShortcutBinding::bind(const QVariantList &keys, bool global, int callback, bool releasing) {
    const auto limit = global ? 1 : keybindings::maxSequenceLength - 1;

    if (keys.empty() || static_cast<std::size_t>(keys.size()) > limit ||
        entries_.size() == keybindings::maxBindings) {
      throw std::runtime_error(
          "Shortcuts accept 1–4 suffix keys, or one global chord; maximum 256 bindings");
    }

    if (releasing && !global) {
      throw std::runtime_error("Only a global shortcut can wait for its modifiers to come up");
    }

    Entry entry{shortcuts_.nextId(), {}, global, callback, releasing};

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

  void ShortcutBinding::deliver(int callback, bool released) {
    TELAR_TRACE("lua.shortcuts.deliver");
    if (!active_) {
      return;
    }

    struct Delivery {
      int callback;
      bool released;
    } delivery{callback, released};

    try {
      environment_.withState(
          [](lua_State *state) -> int {
            const auto &delivery = *static_cast<Delivery *>(lua_touserdata(state, 1));
            lua_pushcfunction(state, lua::Environment::traceback);
            lua_rawgeti(state, LUA_REGISTRYINDEX, delivery.callback);
            lua_pushboolean(state, delivery.released);

            if (lua_pcall(state, 1, 0, 2) != 0) {
              return lua_error(state);
            }

            return 0;
          },
          &delivery);
    } catch (const std::exception &error) {
      qWarning() << "Desktop shortcut callback failed:" << error.what();
    }
  }
} // namespace ui
