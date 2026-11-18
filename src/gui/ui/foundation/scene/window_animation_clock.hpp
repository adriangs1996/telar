#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/ds/values.hpp"
#include <QList>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QTimer>
#include <algorithm>
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <typeinfo>
#include <vector>

#pragma once

namespace telar::gui::qt {

  class WindowAnimationClock;

  // The items of one type in one window: the clock samples a lane per type, and each lane
  // walks its items with static calls.
  struct WindowAnimationLane {
    using Make = WindowAnimationLane (*)();
    using Sample = bool (*)(void* items, std::uint64_t timestamp, bool window_exposed, const QPointer<WindowAnimationClock>& alive);
    using Deadline = ds::Option<std::uint64_t> (*)(const void* items, std::uint64_t timestamp);

    template <typename Items>
    static WindowAnimationLane make();

    const std::type_info* tag;
    std::unique_ptr<void, void (*)(void*)> items;
    Sample sample;
    Deadline deadline;
  };

  // The default set of an item type; a type that keeps state per window declares its own
  // set as `Item::WindowAnimationSet`.
  template <typename Item>
  class WindowAnimationItems {
  public:
    void attach(Item& item) {
      items_.append(&item);
    }

    void detach(Item& item) {
      items_.removeAll(&item);
    }

    // Samples each eligible item; false once sampling destroyed the clock.
    template <typename Sample>
    [[nodiscard]] bool each(const QPointer<WindowAnimationClock>& alive, const Sample& sample) const {
      return std::ranges::all_of(QList<QPointer<Item>>{items_}, [&alive, &sample](const auto& item) {
        if (item && item->eligible()) {
          sample(*item);
        }

        return !alive.isNull();
      });
    }

    bool sample(std::uint64_t timestamp, [[maybe_unused]] bool window_exposed, const QPointer<WindowAnimationClock>& alive) {
      return each(alive, [timestamp](Item& item) {
        item.sample(timestamp);
      });
    }

    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t timestamp) const {
      ds::Option<std::uint64_t> earliest;

      for (const auto& item : items_) {
        if (item && item->eligible()) {
          const auto deadline = item->deadline(timestamp);
          if (deadline && (!earliest || *deadline < *earliest)) {
            earliest = deadline;
          }
        }
      }

      return earliest;
    }

  private:
    QList<QPointer<Item>> items_;
  };

  template <typename Item>
  struct WindowAnimationSetOf {
    using type = WindowAnimationItems<Item>;
  };

  template <typename Item>
    requires requires { typename Item::WindowAnimationSet; }
  struct WindowAnimationSetOf<Item> {
    using type = Item::WindowAnimationSet;
  };

  template <typename Item>
  using WindowAnimationSet = WindowAnimationSetOf<Item>::type;

  class WindowAnimationClock final : public QObject {
  public:
    explicit WindowAnimationClock(QQuickWindow& window);
    static WindowAnimationClock& forWindow(QQuickWindow& window);

    // Fixes the lanes, and their order, that every clock created afterwards starts with.
    // Without it a lane starts when the first item of its type attaches.
    template <typename... Items>
    static void compose() noexcept {
      static constexpr std::array<WindowAnimationLane::Make, sizeof...(Items)> lanes{&WindowAnimationLane::make<WindowAnimationSet<Items>>...};

      compose(lanes);
    }

    [[nodiscard]] std::uint64_t now() noexcept;
    [[nodiscard]] std::uint64_t frameInterval() const noexcept;
    void setMaximumFrameRate(ds::Option<std::uint16_t> maximum_fps);

    template <typename Item>
    void attach(Item& item) {
      lane<WindowAnimationSet<Item>>().attach(item);
      requestSynchronization();
    }

    template <typename Item>
    void detach(Item& item) {
      if (auto* items = find<WindowAnimationSet<Item>>()) {
        items->detach(item);
      }

      requestSynchronization();
    }

    void requestSynchronization();
    bool eventFilter(QObject* watched, QEvent* event) override;

  private:
    static void compose(std::span<const WindowAnimationLane::Make> lanes) noexcept;

    template <typename Items>
    [[nodiscard]] Items* find() const noexcept {
      for (const auto& entry : lanes_) {
        if (*entry.tag == typeid(Items)) {
          return static_cast<Items*>(entry.items.get());
        }
      }

      return nullptr;
    }

    template <typename Items>
    Items& lane() {
      if (auto* items = find<Items>()) {
        return *items;
      }

      return *static_cast<Items*>(lanes_.emplace_back(WindowAnimationLane::make<Items>()).items.get());
    }

    bool sampleVisible(std::uint64_t timestamp);
    void synchronize();

    QQuickWindow& window_;
    QTimer timer_;
    std::vector<WindowAnimationLane> lanes_;
    std::uint64_t now_ns_ = 0;
    ds::Option<std::uint64_t> deadline_ns_;
    ds::Option<std::uint16_t> maximum_fps_;
    bool synchronization_pending_ = false;
  };

  template <typename Items>
  WindowAnimationLane WindowAnimationLane::make() {
    const auto release = [](void* items) {
      const std::unique_ptr<Items> owned{static_cast<Items*>(items)};
    };

    return {
        .tag = &typeid(Items),
        .items = {new Items{}, release},
        .sample = [](void* items, std::uint64_t timestamp, bool window_exposed, const QPointer<WindowAnimationClock>& alive) {
          return static_cast<Items*>(items)->sample(timestamp, window_exposed, alive);
        },
        .deadline = [](const void* items, std::uint64_t timestamp) {
          return static_cast<const Items*>(items)->deadline(timestamp);
        },
    };
  }

}
