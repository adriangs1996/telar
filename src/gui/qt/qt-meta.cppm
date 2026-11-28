export module telar.gui.qt:meta;

import std;

export namespace telar::qt {

  template <typename Read, typename Write = std::nullptr_t, typename Notify = std::nullptr_t, typename Reset = std::nullptr_t>
  struct [[tbc::shared]] PropertyDesc {
    const char* name = nullptr;
    Read read{};
    Write write = nullptr;
    Notify notify = nullptr;
    Reset reset = nullptr;
    bool is_constant = false;
    bool is_final = false;
    bool is_required = false;

    template <typename NewWrite>
    [[tbc::generic]] constexpr auto withWrite(NewWrite func) const noexcept {
      return PropertyDesc<Read, NewWrite, Notify, Reset>{name, read, func, notify, reset, is_constant, is_final, is_required};
    }

    template <typename NewNotify>
    [[tbc::generic]] constexpr auto withNotify(NewNotify func) const noexcept {
      return PropertyDesc<Read, Write, NewNotify, Reset>{name, read, write, func, reset, is_constant, is_final, is_required};
    }

    template <typename NewReset>
    [[tbc::generic]] constexpr auto withReset(NewReset func) const noexcept {
      return PropertyDesc<Read, Write, Notify, NewReset>{name, read, write, notify, func, is_constant, is_final, is_required};
    }

    [[tbc::generic]] constexpr auto constant() const noexcept {
      auto copy = *this;

      copy.is_constant = true;
      return copy;
    }

    [[tbc::generic]] constexpr auto finalProperty() const noexcept {
      auto copy = *this;

      copy.is_final = true;
      return copy;
    }

    [[tbc::generic]] constexpr auto required() const noexcept {
      auto copy = *this;

      copy.is_required = true;
      return copy;
    }
  };

  template <typename Read, typename Write = std::nullptr_t, typename Notify = std::nullptr_t, typename Reset = std::nullptr_t>
  [[tbc::generic, tbc::raw]] constexpr PropertyDesc<Read, Write, Notify, Reset> property(
      const char* name,
      Read read,
      Write write = nullptr,
      Notify notify = nullptr,
      Reset reset = nullptr
  ) noexcept {
    return {name, read, write, notify, reset, false, false, false};
  }

  template <typename... Props>
  struct [[tbc::shared]] PropertyList {};

  template <typename Head, typename... Tail>
  struct [[tbc::shared]] PropertyList<Head, Tail...> {
    Head head{};
    PropertyList<Tail...> tail{};
  };

  [[tbc::hot_path, tbc::raw]] constexpr PropertyList<> properties() noexcept {
    return {};
  }

  template <typename Head, typename... Tail>
  [[tbc::generic, tbc::raw]] constexpr PropertyList<Head, Tail...> properties(Head head, Tail... tail) noexcept {
    return {head, properties(tail...)};
  }

}
