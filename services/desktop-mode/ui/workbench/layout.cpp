#include "layout.hpp"
#include "../../trace.hpp"
#include <QJsonArray>
#include <algorithm>
#include <cmath>
#include <optional>
#include <tuple>

namespace workbench {
  namespace {
    constexpr double minimum_share = 0.05;
    // Frames are laid out at whole points with a gap between neighbours; half a point absorbs
    // the rounding of their edges.
    constexpr double edge_tolerance = 0.5;

    QRectF constrained(QRectF frame, const Constraints &limits) {
      frame.setWidth(std::min(frame.width(), limits.maximum.width()));
      frame.setHeight(std::min(frame.height(), limits.maximum.height()));

      if (limits.aspect > 0) {
        if (frame.width() > frame.height() * limits.aspect) {
          frame.setWidth(frame.height() * limits.aspect);
        } else {
          frame.setHeight(frame.width() / limits.aspect);
        }
      }

      return frame;
    }

    bool horizontal(Direction direction) {
      return direction == Direction::left || direction == Direction::right;
    }

    bool forward(Direction direction) {
      return direction == Direction::right || direction == Direction::down;
    }

    // How far a candidate lies in a direction from the focused frame: the gap between their
    // facing edges, then how far apart their centres are across the direction.
    struct Reach {
      double edge = 0;
      double offset = 0;
    };

    // Nothing when the candidate does not start past the frame's edge in that direction.
    std::optional<Reach> reach(const QRectF &from, const QRectF &to, Direction direction) {
      double edge = 0;
      switch (direction) {
      case Direction::left:
        edge = from.left() - to.right();
        break;
      case Direction::right:
        edge = to.left() - from.right();
        break;
      case Direction::up:
        edge = from.top() - to.bottom();
        break;
      case Direction::down:
        edge = to.top() - from.bottom();
        break;
      }

      if (edge < -edge_tolerance) {
        return std::nullopt;
      }

      const auto across = horizontal(direction) ? to.center().y() - from.center().y()
                                                : to.center().x() - from.center().x();
      return Reach{
          .edge = std::max(0.0, edge),
          .offset = std::abs(across),
      };
    }
  } // namespace

  Layout::Index Layout::find(const QString &id) const {
    const auto found = indices_.constFind(id);
    return found == indices_.cend() ? none : *found;
  }

  Layout::Index Layout::allocate() {
    Index node = none;

    if (free_ != none) {
      node = free_;
      free_ = nodes_[node].next;
    } else if (used_ < node_capacity) {
      node = used_++;
    } else {
      return none;
    }

    nodes_[node] = Node{};
    return node;
  }

  void Layout::release(Index node) {
    nodes_[node] = Node{};
    nodes_[node].next = free_;
    free_ = node;
  }

  void Layout::attach(Index parent, Index after, Index child) {
    auto &value = nodes_[child];
    value.parent = parent;
    value.previous = after;

    if (after == none) {
      value.next = nodes_[parent].first;
      nodes_[parent].first = child;
    } else {
      value.next = nodes_[after].next;
      nodes_[after].next = child;
    }

    if (value.next != none) {
      nodes_[value.next].previous = child;
    }
  }

  void Layout::detach(Index node) {
    auto &value = nodes_[node];

    if (value.previous != none) {
      nodes_[value.previous].next = value.next;
    } else if (value.parent != none) {
      nodes_[value.parent].first = value.next;
    }

    if (value.next != none) {
      nodes_[value.next].previous = value.previous;
    }

    value.parent = none;
    value.previous = none;
    value.next = none;
  }

  // The new node takes the old one's place among its siblings, and its share with it.
  void Layout::replace(Index old_node, Index new_node) {
    auto &previous = nodes_[old_node];
    auto &current = nodes_[new_node];
    current.parent = previous.parent;
    current.previous = previous.previous;
    current.next = previous.next;
    current.weight = previous.weight;

    if (previous.previous != none) {
      nodes_[previous.previous].next = new_node;
    } else if (previous.parent != none) {
      nodes_[previous.parent].first = new_node;
    } else {
      root_ = new_node;
    }

    if (previous.next != none) {
      nodes_[previous.next].previous = new_node;
    }

    previous.parent = none;
    previous.previous = none;
    previous.next = none;
  }

  // Keeps the tree normalized after a removal: a container with a single child gives
  // its place to that child, and a child splitting along its new parent's axis merges into it.
  void Layout::collapse(Index container) {
    const auto child = nodes_[container].first;

    if (child == none || nodes_[child].next != none) {
      return;
    }

    replace(container, child);
    release(container);
    const auto parent = nodes_[child].parent;

    if (nodes_[child].element == none && parent != none &&
        nodes_[parent].axis == nodes_[child].axis) {
      splice(child);
    }
  }

  void Layout::splice(Index container) {
    const auto parent = nodes_[container].parent;
    const auto share = nodes_[container].weight;
    auto after = nodes_[container].previous;
    auto child = nodes_[container].first;
    detach(container);

    while (child != none) {
      const auto next = nodes_[child].next;
      nodes_[child].weight *= share;
      attach(parent, after, child);
      after = child;
      child = next;
    }

    release(container);
  }

  void Layout::clear() {
    root_ = none;
    free_ = none;
    used_ = 0;
    std::fill(leaves_.begin(), leaves_.end(), none);
  }

  bool Layout::insert(Element element, Axis axis) {
    TELAR_TRACE("layout.insert");
    return insertAt(focused_ != none ? focused_ : root_, std::move(element), axis);
  }

  bool Layout::insertBesideLargest(Element element, const QRectF &area, double gap) {
    TELAR_TRACE("layout.insert_beside_largest");
    if (root_ == none || area.isEmpty()) {
      return insert(std::move(element));
    }

    Pass pass{.gap = gap};
    std::vector<Placement> placements;
    measure(root_, pass);
    place(root_, area, pass, placements);

    const auto extent = [](const Placement &placement) {
      return placement.frame.width() * placement.frame.height();
    };

    const auto largest = std::ranges::max_element(placements, {}, extent);
    if (largest == placements.end()) {
      return insert(std::move(element));
    }

    const auto axis =
        largest->frame.width() >= largest->frame.height() ? Axis::horizontal : Axis::vertical;

    return insertAt(leaves_[find(largest->id)], std::move(element), axis);
  }

  bool Layout::insertAt(Index target, Element element, Axis axis) {
    if (element.id.isEmpty() || contains(element.id) || elements_.size() >= capacity) {
      return false;
    }

    const auto parent = target == none ? none : nodes_[target].parent;
    const bool sibling = parent != none && nodes_[parent].axis == axis;

    const bool append =
        target != none && nodes_[target].element == none && nodes_[target].axis == axis;

    const auto leaf = allocate();
    const auto container = target == none || sibling || append ? none : allocate();

    if (leaf == none) {
      return false;
    }

    if (target != none && !sibling && !append && container == none) {
      release(leaf);
      return false;
    }

    const auto index = static_cast<Index>(elements_.size());
    element.order = next_order_++;
    indices_.insert(element.id, index);
    elements_.push_back(std::move(element));
    leaves_.push_back(leaf);
    nodes_[leaf].element = index;

    if (target == none) {
      root_ = leaf;
      focused_ = leaf;
    } else if (sibling) {
      nodes_[target].weight /= 2;
      nodes_[leaf].weight = nodes_[target].weight;
      attach(parent, target, leaf);
    } else if (append) {
      auto last = nodes_[target].first;
      float count = 1;

      while (nodes_[last].next != none) {
        last = nodes_[last].next;
        ++count;
      }

      for (auto child = nodes_[target].first; child != none; child = nodes_[child].next) {
        nodes_[child].weight *= count / (count + 1);
      }

      nodes_[leaf].weight = 1 / (count + 1);
      attach(target, last, leaf);
    } else {
      replace(target, container);
      nodes_[container].axis = axis;
      nodes_[target].weight = 0.5F;
      nodes_[leaf].weight = 0.5F;
      attach(container, none, target);
      attach(container, target, leaf);
    }

    return true;
  }

  void Layout::remove(const QString &id) {
    TELAR_TRACE("layout.remove");
    const auto index = find(id);

    if (index == none) {
      return;
    }

    const auto leaf = leaves_[index];
    const auto parent = nodes_[leaf].parent;
    auto heir = none;

    if (parent == none) {
      root_ = none;
    } else {
      // A split inserts the new leaf right after the one it split, so giving the space to the
      // previous sibling undoes the latest split.
      heir = nodes_[leaf].previous != none ? nodes_[leaf].previous : nodes_[leaf].next;
      nodes_[heir].weight += nodes_[leaf].weight;
      detach(leaf);
    }

    while (heir != none && nodes_[heir].element == none) {
      heir = nodes_[heir].first;
    }

    release(leaf);

    if (parent != none) {
      collapse(parent);
    }

    if (focused_ == leaf) {
      focused_ = heir;
    }

    indices_.remove(id);
    const auto last = static_cast<Index>(elements_.size() - 1);

    if (index != last) {
      elements_[index] = std::move(elements_[last]);
      leaves_[index] = leaves_[last];
      nodes_[leaves_[index]].element = index;
      indices_.insert(elements_[index].id, index);
    }

    elements_.pop_back();
    leaves_.pop_back();
  }

  bool Layout::contains(const QString &id) const {
    return indices_.contains(id);
  }

  Element *Layout::element(const QString &id) {
    const auto index = find(id);
    return index == none ? nullptr : &elements_[index];
  }

  std::span<const Element> Layout::elements() const {
    return elements_;
  }

  const QString &Layout::focused() const {
    static const QString nothing;
    return focused_ == none ? nothing : elements_[nodes_[focused_].element].id;
  }

  bool Layout::focus(const QString &id) {
    TELAR_TRACE("layout.focus");
    const auto index = find(id);

    if (index == none || !elements_[index].focusable) {
      return false;
    }

    focused_ = leaves_[index];
    elements_[index].order = next_order_++;
    return true;
  }

  bool Layout::cycle(int step) {
    TELAR_TRACE("layout.cycle");
    std::array<Index, capacity> leaves;
    std::size_t count = 0;
    std::size_t current = 0;
    auto node = root_;

    // Leaves in reading order, walking up through parents instead of recursing.
    while (node != none) {
      if (nodes_[node].element == none) {
        node = nodes_[node].first;
        continue;
      }

      if (elements_[nodes_[node].element].focusable) {
        if (node == focused_) {
          current = count;
        }

        leaves[count++] = node;
      }

      while (node != none && nodes_[node].next == none) {
        node = nodes_[node].parent;
      }

      if (node != none) {
        node = nodes_[node].next;
      }
    }

    if (count == 0) {
      return false;
    }

    const auto size = static_cast<int>(count);
    const auto index = (static_cast<int>(current) + step % size + size) % size;
    return focus(elements_[nodes_[leaves[index]].element].id);
  }

  const Layout::Measure &Layout::measure(Index node, Pass &pass) const {
    auto &result = pass.measures[node];
    const auto &value = nodes_[node];

    if (value.element != none) {
      const auto &element = elements_[value.element];
      result = element.floating ? Measure{}
                                : Measure{.minimum = element.constraints.minimum, .tiled = true};
      return result;
    }

    const bool across = value.axis == Axis::horizontal;
    QSizeF size(0, 0);
    bool tiled = false;

    for (auto child = value.first; child != none; child = nodes_[child].next) {
      const auto &minimum = measure(child, pass);

      if (!minimum.tiled) {
        continue;
      }

      const auto gap = tiled ? pass.gap : 0;

      if (across) {
        size.rwidth() += minimum.minimum.width() + gap;
        size.rheight() = std::max(size.height(), minimum.minimum.height());
      } else {
        size.rwidth() = std::max(size.width(), minimum.minimum.width());
        size.rheight() += minimum.minimum.height() + gap;
      }

      tiled = true;
    }

    result = {
        .minimum = size,
        .tiled = tiled,
    };

    return result;
  }

  // Shares the container's extent by weight. A child whose share falls below its minimum
  // is pinned to that minimum and the rest is shared again among the others.
  void
  Layout::place(Index node, const QRectF &area, Pass &pass, std::vector<Placement> &output) const {
    const auto &value = nodes_[node];

    if (value.element != none) {
      const auto &element = elements_[value.element];

      if (!element.floating) {
        output.push_back({element.id, constrained(area, element.constraints), true, element.order});
      }

      return;
    }

    const bool across = value.axis == Axis::horizontal;
    const auto main = [&](Index child) {
      const auto &minimum = pass.measures[child].minimum;
      return across ? minimum.width() : minimum.height();
    };

    std::size_t count = 0;
    double weights = 0;

    for (auto child = value.first; child != none; child = nodes_[child].next) {
      if (pass.measures[child].tiled) {
        pass.measures[child].fixed = false;
        weights += nodes_[child].weight;
        ++count;
      }
    }

    if (count == 0) {
      return;
    }

    auto remaining =
        (across ? area.width() : area.height()) - pass.gap * static_cast<double>(count - 1);
    bool pinned = true;

    while (pinned && weights > 0) {
      pinned = false;

      for (auto child = value.first; child != none; child = nodes_[child].next) {
        auto &measure = pass.measures[child];

        if (!measure.tiled || measure.fixed) {
          continue;
        }

        measure.extent = remaining * nodes_[child].weight / weights;

        if (measure.extent < main(child)) {
          measure.extent = main(child);
          measure.fixed = true;
          remaining -= measure.extent;
          weights -= nodes_[child].weight;
          pinned = true;
        }
      }
    }

    // Edges snap the exact running position, so rounding never accumulates across siblings.
    auto cursor = across ? area.x() : area.y();
    auto exact = cursor;
    const auto end = across ? area.right() : area.bottom();
    std::size_t placed = 0;

    for (auto child = value.first; child != none; child = nodes_[child].next) {
      if (!pass.measures[child].tiled) {
        continue;
      }

      ++placed;
      exact += pass.measures[child].extent;
      const auto edge = placed == count ? end : std::round(exact * pass.scale) / pass.scale;
      exact += pass.gap;
      auto frame = area;

      if (across) {
        frame.setLeft(cursor);
        frame.setRight(edge);
      } else {
        frame.setTop(cursor);
        frame.setBottom(edge);
      }

      place(child, frame, pass, output);
      cursor = edge + pass.gap;
    }
  }

  std::vector<Placement> Layout::arrange(const QRectF &area, double gap, double scale) const {
    TELAR_TRACE("layout.arrange");
    std::vector<Placement> result;

    if (area.isEmpty()) {
      return result;
    }

    Pass pass{
        .gap = gap,
        .scale = std::max(1.0, scale),
    };

    bool fits = true;

    if (root_ != none) {
      const auto &minimum = measure(root_, pass);
      fits = !minimum.tiled ||
             (area.width() >= minimum.minimum.width() && area.height() >= minimum.minimum.height());
    }

    if ((maximized_ || !fits) && focused_ != none) {
      const auto &element = elements_[nodes_[focused_].element];

      result.push_back({
          element.id,
          area,
          true,
          element.order,
      });

      return result;
    }

    if (root_ != none) {
      place(root_, area, pass, result);
    }

    for (const auto &value : elements_) {
      if (!value.floating) {
        continue;
      }

      const auto relative = value.floating_frame;

      const auto width =
          std::min(area.width(),
                   std::max(value.constraints.minimum.width(), relative.width() * area.width()));

      const auto height =
          std::min(area.height(),
                   std::max(value.constraints.minimum.height(), relative.height() * area.height()));

      const auto x = std::clamp(relative.x() * area.width(), 0.0, area.width() - width);
      const auto y = std::clamp(relative.y() * area.height(), 0.0, area.height() - height);

      result.push_back({
          value.id,
          constrained({area.x() + x, area.y() + y, width, height}, value.constraints),
          true,
          value.order,
      });
    }

    std::stable_sort(result.begin(), result.end(), [](const auto &first, const auto &second) {
      return first.order < second.order;
    });

    return result;
  }

  // Moves the focus to the tiled element past the focused one's edge in the direction: the
  // nearest edge, then the best aligned, as the GUI's pane navigation does. Floating elements
  // are never a destination; cycle reaches them.
  bool Layout::navigate(Direction direction, const QRectF &area, double gap) {
    TELAR_TRACE("layout.navigate");
    const auto placements = arrange(area, gap, 1);
    if (placements.size() == 1 && elements_.size() > 1) {
      return cycle(forward(direction) ? 1 : -1);
    }

    const auto &focused_id = focused();
    const auto current = std::ranges::find(placements, focused_id, &Placement::id);
    if (current == placements.end()) {
      return cycle(1);
    }

    QString candidate;
    std::optional<Reach> best;
    for (const auto &placement : placements) {
      const auto &element = elements_[find(placement.id)];
      if (placement.id == focused_id || element.floating || !element.focusable) {
        continue;
      }

      const auto found = reach(current->frame, placement.frame, direction);
      if (found && (!best || std::tie(found->edge, found->offset) <
                                 std::tie(best->edge, best->offset))) {
        best = found;
        candidate = placement.id;
      }
    }

    return !candidate.isEmpty() && focus(candidate);
  }

  // Elements trade places; the floating state belongs to the place, not to the element.
  bool Layout::swap(const QString &first, const QString &second) {
    TELAR_TRACE("layout.swap");
    const auto a = find(first);
    const auto b = find(second);

    if (a == none || b == none) {
      return false;
    }

    const auto focused = focused_ == none ? none : nodes_[focused_].element;
    std::swap(nodes_[leaves_[a]].element, nodes_[leaves_[b]].element);
    std::swap(leaves_[a], leaves_[b]);
    std::swap(elements_[a].floating, elements_[b].floating);
    std::swap(elements_[a].floating_frame, elements_[b].floating_frame);

    if (focused != none) {
      focused_ = leaves_[focused];
    }

    return true;
  }

  // Moves the border next to the focused branch, inside the closest container along the
  // direction's axis. The border on the direction's side grows the branch, the other shrinks it.
  bool Layout::resize(Direction direction, double amount) {
    TELAR_TRACE("layout.resize");
    if (focused_ == none || !std::isfinite(amount)) {
      return false;
    }

    const auto axis = horizontal(direction) ? Axis::horizontal : Axis::vertical;
    auto child = focused_;
    auto parent = nodes_[child].parent;

    while (parent != none && nodes_[parent].axis != axis) {
      child = parent;
      parent = nodes_[parent].parent;
    }

    if (parent == none) {
      return false;
    }

    const auto next = nodes_[child].next;
    const auto previous = nodes_[child].previous;
    auto before = child;
    auto after = next;

    if (forward(direction) ? next == none : previous != none) {
      before = previous;
      after = child;
    }

    const double total = nodes_[before].weight + nodes_[after].weight;
    const auto sign = forward(direction) ? 1.0 : -1.0;
    const auto weight = std::clamp(nodes_[before].weight + sign * amount,
                                   total * minimum_share,
                                   total * (1 - minimum_share));

    nodes_[before].weight = static_cast<float>(weight);
    nodes_[after].weight = static_cast<float>(total - weight);
    return true;
  }

  void Layout::maximize() {
    maximized_ = !maximized_;
  }

  void Layout::floatElement(const QString &id, bool enabled) {
    TELAR_TRACE("layout.float_element");
    if (auto *value = element(id)) {
      value->floating = enabled;
    }
  }

  void Layout::setFloatingFrame(const QString &id, const QRectF &relative) {
    TELAR_TRACE("layout.set_floating_frame");
    if (auto *value = element(id); value && relative.isValid() && std::isfinite(relative.x()) &&
                                   std::isfinite(relative.y()) && std::isfinite(relative.width()) &&
                                   std::isfinite(relative.height())) {
      value->floating_frame = relative;
    }
  }

  QJsonObject Layout::encode(Index node) const {
    const auto &value = nodes_[node];

    if (value.element != none) {
      return {{"id", elements_[value.element].id}, {"weight", value.weight}};
    }

    QJsonArray children;

    for (auto child = value.first; child != none; child = nodes_[child].next) {
      children.append(encode(child));
    }

    return {{"axis", value.axis == Axis::horizontal ? "horizontal" : "vertical"},
            {"weight", value.weight},
            {"children", children}};
  }

  QJsonObject Layout::save() const {
    TELAR_TRACE("layout.save");
    QJsonObject floating;
    for (const auto &element : elements_) {
      if (element.floating) {
        const auto r = element.floating_frame;
        floating[element.id] = QJsonArray{r.x(), r.y(), r.width(), r.height()};
      }
    }

    return {{"tree", root_ == none ? QJsonObject{} : encode(root_)},
            {"focused", focused()},
            {"maximized", maximized_},
            {"floating", floating}};
  }

  // Rebuilds a subtree normalized: invalid weights become even shares, containers left with
  // one child collapse into it, and children along their parent's axis merge into it.
  Layout::Index
  Layout::decode(const QJsonObject &data, std::size_t &count, std::bitset<capacity> &seen) {
    if (data.isEmpty() || ++count > node_capacity) {
      return none;
    }

    auto weight = data.value("weight").toDouble(1);

    if (!std::isfinite(weight) || weight <= 0) {
      weight = 1;
    }

    const auto id = data.value("id").toString();

    if (!id.isEmpty()) {
      const auto index = find(id);

      if (index == none || seen.test(index)) {
        return none;
      }

      const auto leaf = allocate();

      if (leaf == none) {
        return none;
      }

      seen.set(index);
      nodes_[leaf].element = index;
      nodes_[leaf].weight = static_cast<float>(weight);
      leaves_[index] = leaf;
      return leaf;
    }

    const auto container = allocate();

    if (container == none) {
      return none;
    }

    nodes_[container].axis =
        data.value("axis").toString() == "vertical" ? Axis::vertical : Axis::horizontal;
    nodes_[container].weight = static_cast<float>(weight);
    auto last = none;
    double total = 0;

    for (const auto &entry : data.value("children").toArray()) {
      const auto child = decode(entry.toObject(), count, seen);

      if (child != none) {
        attach(container, last, child);
        total += nodes_[child].weight;
        last = child;
      }
    }

    if (last == none) {
      release(container);
      return none;
    }

    for (auto child = nodes_[container].first; child != none;) {
      const auto next = nodes_[child].next;
      nodes_[child].weight = static_cast<float>(nodes_[child].weight / total);

      if (nodes_[child].element == none && nodes_[child].axis == nodes_[container].axis) {
        splice(child);
      }

      child = next;
    }

    const auto only = nodes_[container].first;

    if (nodes_[only].next == none) {
      detach(only);
      nodes_[only].weight = nodes_[container].weight;
      release(container);
      return only;
    }

    return container;
  }

  void Layout::restore(const QJsonObject &value) {
    TELAR_TRACE("layout.restore");
    const auto nodes = nodes_;
    const auto root = root_;
    const auto free_list = free_;
    const auto used = used_;
    const auto leaves = leaves_;
    const auto focused = focused_ == none ? none : nodes_[focused_].element;
    std::bitset<capacity> seen;
    std::size_t count = 0;

    clear();
    const auto restored = decode(value.value("tree").toObject(), count, seen);

    if (seen.count() == elements_.size()) {
      root_ = restored;

      if (root_ != none) {
        nodes_[root_].weight = 1;
      }

      focused_ = focused == none ? none : leaves_[focused];
    } else {
      nodes_ = nodes;
      root_ = root;
      free_ = free_list;
      used_ = used;
      leaves_ = leaves;
    }

    focus(value.value("focused").toString());
    maximized_ = value.value("maximized").toBool();
    const auto floating = value.value("floating").toObject();
    for (auto it = floating.begin(); it != floating.end(); ++it) {
      const auto rect = it.value().toArray();
      if (rect.size() == 4) {
        floatElement(it.key(), true);
        setFloatingFrame(
            it.key(),
            {rect[0].toDouble(), rect[1].toDouble(), rect[2].toDouble(), rect[3].toDouble()});
      }
    }
  }
} // namespace workbench
