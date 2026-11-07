#include "element_layout.hpp"

#include "window_animation_clock.hpp"

#include <QQuickWindow>
#include <QVariantMap>

#include <algorithm>
#include <cmath>
#include <limits>
#include <QList>

namespace telar::gui::qt {

namespace {

constexpr int align_center = 1;
constexpr int align_end = 2;
constexpr int align_stretch = 3;
constexpr int justify_center = 1;
constexpr int justify_end = 2;
constexpr int justify_between = 3;
constexpr int easing_linear = 1;
constexpr int easing_in_out = 2;
constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;

qreal number(const QVariantMap &element, const char *name, qreal fallback) {
  const auto value = element.value(QLatin1StringView{name});

  return value.isValid() ? value.toReal() : fallback;
}

qreal eased(qreal progress, int easing) {
  if (easing == easing_linear) {
    return progress;
  }

  if (easing == easing_in_out) {
    return progress < 0.5 ? 4 * progress * progress * progress : 1 - std::pow(-2 * progress + 2, 3) / 2;
  }

  return 1 - std::pow(1 - progress, 3);
}

qreal mix(qreal from, qreal to, qreal amount) {
  return from + ((to - from) * amount);
}

struct Child {
  QQuickItem *item = nullptr;
  QVariantMap element;
  qreal main = 0;
  qreal cross = 0;
  qreal grow = 0;
  bool fixed_main = false;
};

}

ElementLayout::ElementLayout(QQuickItem *parent)
    : QQuickItem(parent) {
  setFlag(ItemHasContents, false);
}

ElementLayout::~ElementLayout() {
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }
}

int ElementLayout::direction() const noexcept {
  return direction_;
}

void ElementLayout::setDirection(int direction) {
  if (direction != direction_) {
    direction_ = direction;
    emit layoutChanged();
    polish();
  }
}

qreal ElementLayout::gap() const noexcept {
  return gap_;
}

void ElementLayout::setGap(qreal gap) {
  if (gap != gap_) {
    gap_ = gap;
    emit layoutChanged();
    polish();
  }
}

QVariantList ElementLayout::padding() const {
  return {padding_[0], padding_[1], padding_[2], padding_[3]};
}

void ElementLayout::setPadding(const QVariantList &padding) {
  for (qsizetype index = 0; index < 4; ++index) {
    padding_[index] = index < padding.size() ? padding[index].toReal() : 0;
  }

  emit layoutChanged();
  polish();
}

int ElementLayout::align() const noexcept {
  return align_;
}

void ElementLayout::setAlign(int align) {
  if (align != align_) {
    align_ = align;
    emit layoutChanged();
    polish();
  }
}

int ElementLayout::justify() const noexcept {
  return justify_;
}

void ElementLayout::setJustify(int justify) {
  if (justify != justify_) {
    justify_ = justify;
    emit layoutChanged();
    polish();
  }
}

qreal ElementLayout::ratio() const noexcept {
  return ratio_;
}

void ElementLayout::setRatio(qreal ratio) {
  if (ratio != ratio_) {
    ratio_ = ratio;
    emit layoutChanged();
    polish();
  }
}

bool ElementLayout::eligible() const noexcept {
  return isVisible() && window() != nullptr;
}

std::optional<std::uint64_t> ElementLayout::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
  return frame_requested_ ? std::nullopt : next_sample_ns_;
}

void ElementLayout::sample(std::uint64_t now_ns) {
  if (!frame_requested_ && next_sample_ns_ && now_ns >= *next_sample_ns_) {
    frame_requested_ = true;
    polish();
  }
}

void ElementLayout::itemChange(ItemChange change, const ItemChangeData &value) {
  if (change == ItemChildAddedChange) {
    watch(value.item);
    polish();
  } else if (change == ItemChildRemovedChange) {
    polish();
  } else if (change == ItemSceneChange) {
    bindClock();
  }

  QQuickItem::itemChange(change, value);
}

void ElementLayout::geometryChange(const QRectF &next, const QRectF &previous) {
  QQuickItem::geometryChange(next, previous);
  if (next.size() != previous.size()) {
    polish();
  }
}

void ElementLayout::watch(QQuickItem *child) {
  if (child == nullptr) {
    return;
  }

  // Connections end with the child; a removed child no longer matters to the layout.
  connect(child, &QQuickItem::implicitWidthChanged, this, &ElementLayout::relayout);
  connect(child, &QQuickItem::implicitHeightChanged, this, &ElementLayout::relayout);
  connect(child, &QQuickItem::visibleChanged, this, &ElementLayout::relayout);
  if (child->metaObject()->indexOfSignal("elementChanged()") >= 0) {
    connect(child, SIGNAL(elementChanged()), this, SLOT(relayout()));
  }
}

void ElementLayout::relayout() {
  polish();
}

void ElementLayout::bindClock() {
  if (!clock_.isNull()) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (!clock_.isNull()) {
    clock_->attach(*this);
  }
}

ElementLayout::Pose ElementLayout::animate(const QString &key, const Pose &target, qreal transition_ms, int easing, std::uint64_t now_ns) {
  if (key.isEmpty() || transition_ms <= 0 || clock_.isNull()) {
    motions_.remove(key);

    return target;
  }

  auto &motion = motions_[key];
  motion.seen = true;
  const bool fresh = motion.duration_ns == 0 && motion.start_ns == 0;
  const auto same = [](const Pose &left, const Pose &right) {
    return left.x == right.x && left.y == right.y && left.rotation == right.rotation && left.scale == right.scale && left.opacity == right.opacity;
  };
  if (fresh) {
    // A new element appears at its pose; only later changes ease.
    motion = {.from = target, .to = target, .shown = target, .start_ns = now_ns, .duration_ns = 1, .easing = easing, .seen = true};

    return target;
  }

  if (!same(motion.to, target)) {
    motion.from = motion.shown;
    motion.to = target;
    motion.start_ns = now_ns;
    motion.duration_ns = static_cast<std::uint64_t>(transition_ms) * nanoseconds_per_millisecond;
    motion.easing = easing;
  }

  const auto elapsed = now_ns > motion.start_ns ? now_ns - motion.start_ns : 0;
  const auto progress = motion.duration_ns == 0 ? 1.0 : std::min(1.0, static_cast<qreal>(elapsed) / static_cast<qreal>(motion.duration_ns));
  const auto amount = eased(progress, motion.easing);
  motion.shown = {
      .x = mix(motion.from.x, motion.to.x, amount),
      .y = mix(motion.from.y, motion.to.y, amount),
      .rotation = mix(motion.from.rotation, motion.to.rotation, amount),
      .scale = mix(motion.from.scale, motion.to.scale, amount),
      .opacity = mix(motion.from.opacity, motion.to.opacity, amount),
  };
  if (progress < 1 && clock_ != nullptr) {
    const auto next = now_ns + clock_->frameInterval();
    next_sample_ns_ = next_sample_ns_ ? std::min(*next_sample_ns_, next) : next;
  }

  return motion.shown;
}

void ElementLayout::updatePolish() {
  frame_requested_ = false;
  next_sample_ns_.reset();
  const auto now_ns = clock_.isNull() ? std::uint64_t{0} : clock_->now();
  for (auto &motion : motions_) {
    motion.seen = false;
  }

  const bool row = direction_ == ElementLayout::row;
  const bool stack = direction_ == ElementLayout::stack;
  const auto scaled = [this](qreal value) {
    return value * ratio_;
  };
  const qreal left = scaled(padding_[0]);
  const qreal top = scaled(padding_[1]);
  const qreal right = scaled(padding_[2]);
  const qreal bottom = scaled(padding_[3]);
  const qreal gap = scaled(gap_);
  QList<Child> children;
  for (auto *item : childItems()) {
    const auto element = item->property("element").toMap();
    if (element.isEmpty() || !item->isVisible()) {
      continue;
    }

    const auto width = number(element, "width", -1);
    const auto height = number(element, "height", -1);
    const auto natural_width = std::clamp(width >= 0 ? scaled(width) : item->implicitWidth(), scaled(number(element, "minWidth", 0)), scaled(number(element, "maxWidth", std::numeric_limits<qreal>::max() / 4)));
    const auto natural_height = std::clamp(height >= 0 ? scaled(height) : item->implicitHeight(), scaled(number(element, "minHeight", 0)), scaled(number(element, "maxHeight", std::numeric_limits<qreal>::max() / 4)));
    children.append({
        .item = item,
        .element = element,
        .main = row ? natural_width : natural_height,
        .cross = row ? natural_height : natural_width,
        .grow = std::max<qreal>(0, number(element, "grow", 0)),
        .fixed_main = (row ? width : height) >= 0,
    });
  }

  const qreal inner_width = std::max<qreal>(0, width() - left - right);
  const qreal inner_height = std::max<qreal>(0, height() - top - bottom);
  qreal natural_main = 0;
  qreal natural_cross = 0;
  for (const auto &child : children) {
    natural_main = stack ? std::max(natural_main, child.main) : natural_main + child.main;
    natural_cross = std::max(natural_cross, child.cross);
  }

  if (!stack && !children.empty()) {
    natural_main += gap * static_cast<qreal>(children.size() - 1);
  }

  setImplicitWidth((row || stack ? natural_main : natural_cross) + left + right);
  setImplicitHeight((row || stack ? natural_cross : natural_main) + top + bottom);

  const qreal available_main = row || stack ? inner_width : inner_height;
  const qreal available_cross = row || stack ? inner_height : inner_width;
  qreal remaining = available_main - natural_main;
  qreal spacing = gap;
  qreal offset = 0;
  if (!stack) {
    qreal growth = 0;
    qreal flexible = 0;
    for (const auto &child : children) {
      growth += child.grow;
      flexible += child.fixed_main ? 0 : child.main;
    }

    if (remaining > 0 && growth > 0) {
      for (auto &child : children) {
        child.main += remaining * child.grow / growth;
      }

      remaining = 0;
    } else if (remaining < 0 && flexible > 0) {
      // Too little room: shrink the children without a set size, so their text elides.
      const auto factor = std::max<qreal>(0, (flexible + remaining) / flexible);
      for (auto &child : children) {
        if (!child.fixed_main) {
          child.main *= factor;
        }
      }

      remaining = 0;
    }

    if (remaining > 0) {
      if (justify_ == justify_center) {
        offset = remaining / 2;
      } else if (justify_ == justify_end) {
        offset = remaining;
      } else if (justify_ == justify_between && children.size() > 1) {
        spacing += remaining / static_cast<qreal>(children.size() - 1);
      }
    }
  }

  qreal cursor = offset;
  for (const auto &child : children) {
    const auto alignment = child.element.contains(QStringLiteral("alignSelf")) ? child.element.value(QStringLiteral("alignSelf")).toInt() : align_;
    // A child never overflows the cross axis: text inside it elides instead.
    const auto cross = alignment == align_stretch ? available_cross : std::min(child.cross, std::max<qreal>(0, available_cross));
    qreal cross_offset = 0;
    if (alignment == align_center) {
      cross_offset = (available_cross - cross) / 2;
    } else if (alignment == align_end) {
      cross_offset = available_cross - cross;
    }

    // A stack lays children over each other: `justify` places them along x, `align` along y.
    const auto main = stack && justify_ == justify_between ? available_main : child.main;
    qreal main_offset = stack ? 0 : cursor;
    if (stack) {
      if (justify_ == justify_center) {
        main_offset = (available_main - main) / 2;
      } else if (justify_ == justify_end) {
        main_offset = available_main - main;
      }
    }

    const auto item_width = row || stack ? main : cross;
    const auto item_height = row || stack ? cross : main;
    const Pose target{
        .x = left + (row || stack ? main_offset : cross_offset) + scaled(number(child.element, "x", 0)),
        .y = top + (row || stack ? cross_offset : main_offset) + scaled(number(child.element, "y", 0)),
        .rotation = number(child.element, "rotation", 0),
        .scale = number(child.element, "scale", 1),
        .opacity = number(child.element, "opacity", 1),
    };
    const auto shown = animate(child.element.value(QStringLiteral("key")).toString(), target, number(child.element, "transition", 0), child.element.value(QStringLiteral("easing")).toInt(), now_ns);
    child.item->setSize({std::max<qreal>(0, item_width), std::max<qreal>(0, item_height)});
    child.item->setPosition({shown.x, shown.y});
    child.item->setRotation(shown.rotation);
    child.item->setScale(shown.scale);
    child.item->setOpacity(shown.opacity);
    child.item->setZ(number(child.element, "z", 0));
    if (!stack) {
      cursor += child.main + spacing;
    }
  }

  motions_.removeIf([](const auto &entry) {
    return !entry.value().seen;
  });
  if (!clock_.isNull()) {
    clock_->requestSynchronization();
  }
}

}
