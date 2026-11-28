module telar.gui.ui.design.elements;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.scene;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

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

    qreal number(const QVariantMap& element, const char* name, qreal fallback) {
      const auto value = element.value(QLatin1StringView{name});

      return value.isValid() ? value.toReal() : fallback;
    }

    ElementLayout::Easing easingOf(int code) {
      if (code == easing_linear) {
        return ElementLayout::Easing::linear;
      }

      return code == easing_in_out ? ElementLayout::Easing::in_out : ElementLayout::Easing::out;
    }

    qreal eased(qreal progress, ElementLayout::Easing easing) {
      if (easing == ElementLayout::Easing::linear) {
        return progress;
      }

      if (easing == ElementLayout::Easing::in_out) {
        constexpr qreal in_out_midpoint = 0.5;

        return progress < in_out_midpoint ? 4 * progress * progress * progress : 1 - (std::pow((-2 * progress) + 2, 3) / 2);
      }

      return 1 - std::pow(1 - progress, 3);
    }

    qreal mix(qreal start, qreal end, qreal amount) {
      return start + ((end - start) * amount);
    }

    struct Child {
      QQuickItem* item = nullptr;
      QVariantMap element;
      qreal main = 0;
      qreal cross = 0;
      qreal grow = 0;
      bool fixed_main = false;
    };

    // What one pass reads from the layout, with lengths in device pixels. The main axis is the
    // flow's; a stack's runs along x.
    struct LayoutPass {
      bool row = false;
      bool stack = false;
      qreal ratio = 1;
      qreal left = 0;
      qreal top = 0;
      qreal right = 0;
      qreal bottom = 0;
      qreal gap = 0;
      int align = 0;
      int justify = 0;
      qreal available_main = 0;
      qreal available_cross = 0;

      [[nodiscard]] bool horizontal() const noexcept {
        return row || stack;
      }

      [[nodiscard]] qreal scaled(qreal value) const noexcept {
        return value * ratio;
      }
    };

    // A child's length along one axis and its offset inside the padding.
    struct AxisSpan {
      qreal length = 0;
      qreal offset = 0;
    };

    // Where the children start along the main axis and the room between neighbours.
    struct Spread {
      qreal offset = 0;
      qreal spacing = 0;
    };

    struct NaturalSize {
      qreal main = 0;
      qreal cross = 0;
    };

    // The children reach their items raw, so the list borrows nothing.
    tbc::val_static<QList<Child>> measure(const QList<QQuickItem*>& items, const LayoutPass& pass) {
      QList<Child> children;

      for (auto* item : items) {
        const auto element = item->property("element").toMap();
        if (element.isEmpty() || !item->isVisible()) {
          continue;
        }

        const auto width = number(element, "width", -1);
        const auto height = number(element, "height", -1);
        const auto natural_width = std::clamp(width >= 0 ? pass.scaled(width) : item->implicitWidth(), pass.scaled(number(element, "minWidth", 0)), pass.scaled(number(element, "maxWidth", std::numeric_limits<qreal>::max() / 4)));
        const auto natural_height = std::clamp(height >= 0 ? pass.scaled(height) : item->implicitHeight(), pass.scaled(number(element, "minHeight", 0)), pass.scaled(number(element, "maxHeight", std::numeric_limits<qreal>::max() / 4)));

        // The items stay Qt's, owned by this item; the list only reaches them by address.
        children.append({
            .item = tbc::raw(item),
            .element = element,
            .main = pass.row ? natural_width : natural_height,
            .cross = pass.row ? natural_height : natural_width,
            .grow = std::max<qreal>(0, number(element, "grow", 0)),
            .fixed_main = (pass.row ? width : height) >= 0,
        });
      }

      return children;
    }

    NaturalSize naturalSize(const QList<Child>& children, const LayoutPass& pass) {
      NaturalSize natural;

      for (const auto& child : children) {
        natural.main = pass.stack ? std::max(natural.main, child.main) : natural.main + child.main;
        natural.cross = std::max(natural.cross, child.cross);
      }

      if (!pass.stack && !children.empty()) {
        natural.main += pass.gap * static_cast<qreal>(children.size() - 1);
      }

      return natural;
    }

    // Grows or shrinks a row's or column's children into `remaining`, then justifies what is left.
    Spread distribute(QList<Child>& children, const LayoutPass& pass, qreal remaining) {
      qreal growth = 0;
      qreal flexible = 0;

      for (const auto& child : children) {
        growth += child.grow;
        flexible += child.fixed_main ? 0 : child.main;
      }

      if (remaining > 0 && growth > 0) {
        for (auto& child : children) {
          child.main += remaining * child.grow / growth;
        }

        remaining = 0;
      } else if (remaining < 0 && flexible > 0) {
        // Too little room: shrink the children without a set size, so their text elides.
        const auto factor = std::max<qreal>(0, (flexible + remaining) / flexible);

        for (auto& child : children) {
          if (!child.fixed_main) {
            child.main *= factor;
          }
        }

        remaining = 0;
      }

      Spread spread{.offset = 0, .spacing = pass.gap};

      if (remaining > 0) {
        if (pass.justify == justify_center) {
          spread.offset = remaining / 2;
        } else if (pass.justify == justify_end) {
          spread.offset = remaining;
        } else if (pass.justify == justify_between && children.size() > 1) {
          spread.spacing += remaining / static_cast<qreal>(children.size() - 1);
        }
      }

      return spread;
    }

    AxisSpan crossSpan(const Child& child, const LayoutPass& pass) {
      const auto alignment = child.element.contains(u"alignSelf"_s) ? child.element.value(u"alignSelf"_s).toInt() : pass.align;
      // A child never overflows the cross axis: text inside it elides instead.
      const auto cross = alignment == align_stretch ? pass.available_cross : std::min(child.cross, std::max<qreal>(0, pass.available_cross));

      if (alignment == align_center) {
        return {.length = cross, .offset = (pass.available_cross - cross) / 2};
      }

      if (alignment == align_end) {
        return {.length = cross, .offset = pass.available_cross - cross};
      }

      return {.length = cross, .offset = 0};
    }

    // A stack lays children over each other: `justify` places them along x, `align` along y.
    AxisSpan mainSpan(const Child& child, const LayoutPass& pass, qreal cursor) {
      const auto main = pass.stack && pass.justify == justify_between ? pass.available_main : child.main;

      if (!pass.stack) {
        return {.length = main, .offset = cursor};
      }

      if (pass.justify == justify_center) {
        return {.length = main, .offset = (pass.available_main - main) / 2};
      }

      if (pass.justify == justify_end) {
        return {.length = main, .offset = pass.available_main - main};
      }

      return {.length = main, .offset = 0};
    }

  }

  ElementLayout::ElementLayout(QQuickItem* parent)
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
      layoutChanged();
      polish();
    }
  }

  qreal ElementLayout::gap() const noexcept {
    return gap_;
  }

  void ElementLayout::setGap(qreal gap) {
    if (!std::equal_to<>{}(gap, gap_)) {
      gap_ = gap;
      layoutChanged();
      polish();
    }
  }

  QVariantList ElementLayout::padding() const {
    return {padding_[0], padding_[1], padding_[2], padding_[3]};
  }

  void ElementLayout::setPadding(const QVariantList& padding) {
    for (qsizetype index = 0; index < 4; ++index) {
      padding_.atMut(static_cast<std::size_t>(index)) = index < padding.size() ? padding[index].toReal() : 0;
    }

    layoutChanged();
    polish();
  }

  int ElementLayout::align() const noexcept {
    return align_;
  }

  void ElementLayout::setAlign(int align) {
    if (align != align_) {
      align_ = align;
      layoutChanged();
      polish();
    }
  }

  int ElementLayout::justify() const noexcept {
    return justify_;
  }

  void ElementLayout::setJustify(int justify) {
    if (justify != justify_) {
      justify_ = justify;
      layoutChanged();
      polish();
    }
  }

  qreal ElementLayout::ratio() const noexcept {
    return ratio_;
  }

  void ElementLayout::setRatio(qreal ratio) {
    if (!std::equal_to<>{}(ratio, ratio_)) {
      ratio_ = ratio;
      layoutChanged();
      polish();
    }
  }

  bool ElementLayout::eligible() const noexcept {
    return isVisible() && window() != nullptr;
  }

  ds::Option<std::uint64_t> ElementLayout::deadline([[maybe_unused]] std::uint64_t now_ns) const noexcept {
    return frame_requested_ ? ds::none : next_sample_ns_;
  }

  void ElementLayout::sample(std::uint64_t now_ns) {
    if (!frame_requested_ && next_sample_ns_ && now_ns >= *next_sample_ns_) {
      frame_requested_ = true;
      polish();
    }
  }

  void ElementLayout::itemChange(ItemChange change, const ItemChangeData& value) {
    if (change == ItemChildAddedChange) {
      // Qt's item, which its parent owns, by address.
      watch(tbc::raw(value.item)); // NOLINT(cppcoreguidelines-pro-type-union-access): Qt hands the added child only through this union.
      polish();
    } else if (change == ItemChildRemovedChange) {
      polish();
    } else if (change == ItemSceneChange) {
      bindClock();
    }

    QQuickItem::itemChange(change, value);
  }

  void ElementLayout::geometryChange(const QRectF& next, const QRectF& previous) {
    QQuickItem::geometryChange(next, previous);
    if (next.size() != previous.size()) {
      polish();
    }
  }

  void ElementLayout::watch(QQuickItem* child) {
    if (child == nullptr) {
      return;
    }

    // Connections end with the child; a removed child no longer matters to the layout.
    connect(child, &QQuickItem::implicitWidthChanged, this, &ElementLayout::relayout);
    connect(child, &QQuickItem::implicitHeightChanged, this, &ElementLayout::relayout);
    connect(child, &QQuickItem::visibleChanged, this, &ElementLayout::relayout);
    if (const int signal_index = child->metaObject()->indexOfSignal("elementChanged()"); signal_index >= 0) {
      const int slot_index = metaObject()->indexOfSlot("relayout()");

      connect(child, child->metaObject()->method(signal_index), this, metaObject()->method(slot_index));
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

  ElementLayout::Pose ElementLayout::animate(const QString& key, const Pose& target, qreal transition_ms, Easing easing, std::uint64_t now_ns) {
    if (key.isEmpty() || transition_ms <= 0 || clock_.isNull()) {
      motions_.remove(key);

      return target;
    }

    auto& motion = motions_[key];

    motion.seen = true;
    const bool fresh = motion.duration_ns == 0 && motion.start_ns == 0;
    const auto same = [](const Pose& left, const Pose& right) {
      const std::equal_to<> equal;

      return equal(left.x, right.x) && equal(left.y, right.y) && equal(left.rotation, right.rotation) && equal(left.scale, right.scale) && equal(left.opacity, right.opacity);
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

    for (auto& motion : motions_) {
      motion.seen = false;
    }

    LayoutPass pass{
        .row = std::cmp_equal(direction_, std::to_underlying(Direction::row)),
        .stack = std::cmp_equal(direction_, std::to_underlying(Direction::stack)),
        .ratio = ratio_,
        .left = padding_[0] * ratio_,
        .top = padding_[1] * ratio_,
        .right = padding_[2] * ratio_,
        .bottom = padding_[3] * ratio_,
        .gap = gap_ * ratio_,
        .align = align_,
        .justify = justify_,
    };

    auto children = measure(childItems(), pass);

    // Read before the implicit size changes, which an item without a set size follows.
    const qreal inner_width = std::max<qreal>(0, width() - pass.left - pass.right);
    const qreal inner_height = std::max<qreal>(0, height() - pass.top - pass.bottom);
    const auto natural = naturalSize(children, pass);

    setImplicitWidth((pass.horizontal() ? natural.main : natural.cross) + pass.left + pass.right);
    setImplicitHeight((pass.horizontal() ? natural.cross : natural.main) + pass.top + pass.bottom);
    pass.available_main = pass.horizontal() ? inner_width : inner_height;
    pass.available_cross = pass.horizontal() ? inner_height : inner_width;

    const auto spread = pass.stack ? Spread{.offset = 0, .spacing = pass.gap} : distribute(children, pass, pass.available_main - natural.main);
    qreal cursor = spread.offset;

    for (const auto& child : children) {
      QQuickItem* const item = child.item;
      const auto main = mainSpan(child, pass, cursor);
      const auto cross = crossSpan(child, pass);
      const Pose target{
          .x = pass.left + (pass.horizontal() ? main.offset : cross.offset) + pass.scaled(number(child.element, "x", 0)),
          .y = pass.top + (pass.horizontal() ? cross.offset : main.offset) + pass.scaled(number(child.element, "y", 0)),
          .rotation = number(child.element, "rotation", 0),
          .scale = number(child.element, "scale", 1),
          .opacity = number(child.element, "opacity", 1),
      };

      const auto shown = animate(child.element.value(u"key"_s).toString(), target, number(child.element, "transition", 0), easingOf(child.element.value(u"easing"_s).toInt()), now_ns);

      item->setSize({std::max<qreal>(0, pass.horizontal() ? main.length : cross.length), std::max<qreal>(0, pass.horizontal() ? cross.length : main.length)});
      item->setPosition({shown.x, shown.y});
      item->setRotation(shown.rotation);
      item->setScale(shown.scale);
      item->setOpacity(shown.opacity);
      item->setZ(number(child.element, "z", 0));
      if (!pass.stack) {
        cursor += child.main + spread.spacing;
      }
    }

    motions_.removeIf([](const auto& entry) {
      return !entry.value().seen;
    });

    if (!clock_.isNull()) {
      clock_->requestSynchronization();
    }
  }

}
