#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QTimer>
#include <concepts>
#include <tuple>

#pragma once


import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

class NativeAgentStatus;
class NativeTabActivity;
class NotificationLayout;
class NativePaneAttention;
class HistoryLoadingLayout;
class HistorySelectionLayout;
class ModalRevealLayout;
class TabStripLayout;
class PaneMotionLayout;

template <typename Item>
concept WindowAnimationItem = std::same_as<Item, NativeAgentStatus> || std::same_as<Item, NativeTabActivity> || std::same_as<Item, NotificationLayout> || std::same_as<Item, NativePaneAttention> || std::same_as<Item, HistoryLoadingLayout> || std::same_as<Item, HistorySelectionLayout> || std::same_as<Item, ModalRevealLayout> || std::same_as<Item, TabStripLayout> || std::same_as<Item, PaneMotionLayout>;

class WindowAnimationClock final : public QObject {
public:
  explicit WindowAnimationClock(QQuickWindow &window);
  static WindowAnimationClock &forWindow(QQuickWindow &window);
  [[nodiscard]] std::uint64_t now() noexcept;
  [[nodiscard]] std::uint64_t frameInterval() const noexcept;
  void setMaximumFrameRate(std::optional<std::uint16_t> maximum_fps);

  template <WindowAnimationItem Item>
  void attach(Item &item) {
    std::get<QList<QPointer<Item>>>(items_).append(&item);
    requestSynchronization();
  }

  template <WindowAnimationItem Item>
  void detach(Item &item) {
    std::get<QList<QPointer<Item>>>(items_).removeAll(&item);
    requestSynchronization();
  }

  void requestSynchronization();
  bool eventFilter(QObject *watched, QEvent *event) override;

private:
  friend class NativePaneAttention;
  [[nodiscard]] AttentionFrame sampleAttention(PaneAttentionKey key, std::uint64_t now_ns) noexcept;

  template <typename Item>
  bool sampleItems(const QList<QPointer<Item>> &items, std::uint64_t timestamp, bool window_exposed) {
    if constexpr (std::same_as<Item, NativePaneAttention>) {
      if (!window_exposed) {
        return true;
      }
    }

    const QPointer<WindowAnimationClock> alive{this};

    return std::ranges::all_of(QList<QPointer<Item>>{items}, [timestamp, &alive](const auto &item) {
      if (item && item->eligible()) {
        item->sample(timestamp);
      }

      return !alive.isNull();
    });
  }

  template <typename Item>
  static std::optional<std::uint64_t> nextDeadline(const QList<QPointer<Item>> &items, std::uint64_t timestamp) {
    std::optional<std::uint64_t> earliest;
    for (const auto &item : items) {
      if (item && item->eligible()) {
        const auto deadline = item->deadline(timestamp);
        if (deadline && (!earliest || *deadline < *earliest)) {
          earliest = deadline;
        }
      }
    }

    return earliest;
  }

  bool sampleVisible(std::uint64_t timestamp);
  void synchronize();

  QQuickWindow &window_;
  QTimer timer_;
  std::tuple<QList<QPointer<NativeAgentStatus>>, QList<QPointer<NativeTabActivity>>, QList<QPointer<NotificationLayout>>, QList<QPointer<NativePaneAttention>>, QList<QPointer<HistoryLoadingLayout>>, QList<QPointer<HistorySelectionLayout>>, QList<QPointer<ModalRevealLayout>>, QList<QPointer<TabStripLayout>>, QList<QPointer<PaneMotionLayout>>> items_;
  AttentionFades attention_;
  std::uint64_t now_ns_ = 0;
  std::optional<std::uint64_t> deadline_ns_;
  std::optional<std::uint16_t> maximum_fps_;
  bool synchronization_pending_ = false;
};

}
