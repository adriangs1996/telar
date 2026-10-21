#pragma once

#include <QHash>
#include <QJsonObject>
#include <QRectF>
#include <QString>
#include <array>
#include <bitset>
#include <cstdint>
#include <limits>
#include <span>
#include <vector>

namespace workbench {
  enum class Direction {
    left,
    right,
    up,
    down
  };

  enum class Axis : std::uint8_t {
    horizontal,
    vertical
  };

  enum class ContentKind {
    terminal,
    view,
    external
  };

  struct Constraints {
    static constexpr double maximum_extent = 16777215;
    QSizeF minimum{80, 60};
    QSizeF maximum{maximum_extent, maximum_extent};
    double aspect = 0;
  };

  struct Element {
    QString id;
    ContentKind kind = ContentKind::terminal;
    QString title;
    Constraints constraints;
    bool focusable = true;
    bool floating = false;
    QRectF floating_frame{0.1, 0.1, 0.6, 0.6};
    int order = 0;
  };

  struct Placement {
    QString id;
    QRectF frame;
    bool visible = true;
    int order = 0;
  };

  // Logical coordinates. The backend alone converts these to native coordinates.
  // The tree only holds what is on screen: a pane that leaves the screen leaves the tree.
  class Layout final {
  public:
    static constexpr std::size_t capacity = 128;
    bool insert(Element element, Axis axis = Axis::horizontal);
    void remove(const QString &id);
    bool contains(const QString &id) const;
    Element *element(const QString &id);
    std::span<const Element> elements() const;
    const QString &focused() const;
    bool focus(const QString &id);
    bool navigate(Direction direction, const QRectF &area, double gap);
    bool cycle(int step);
    bool swap(const QString &first, const QString &second);
    bool resize(Direction direction, double amount);
    void maximize();
    void floatElement(const QString &id, bool enabled);
    void setFloatingFrame(const QString &id, const QRectF &relative);
    std::vector<Placement> arrange(const QRectF &area, double gap, double scale) const;
    QJsonObject save() const;
    void restore(const QJsonObject &value);

  private:
    using Index = std::uint8_t;
    static constexpr Index none = std::numeric_limits<Index>::max();
    // A container has at least two children, so n leaves need at most 2n - 1 nodes.
    static constexpr std::size_t node_capacity = capacity * 2 - 1;
    static_assert(node_capacity <= none, "Node indices must leave room for the none sentinel");

    // Siblings form a doubly linked list of indices. A leaf points at its element;
    // a container splits its parent's share along its axis by its children's weights.
    struct Node {
      float weight = 1;
      Index parent = none;
      Index first = none;
      Index next = none;
      Index previous = none;
      Index element = none;
      Axis axis = Axis::horizontal;
    };

    struct Measure {
      QSizeF minimum;
      double extent = 0;
      bool tiled = false;
      bool fixed = false;
    };

    // Scratch for one arrange call: minimums are measured bottom-up once, then read top-down.
    struct Pass {
      double gap = 0;
      double scale = 1;
      std::array<Measure, node_capacity> measures{};
    };

    std::array<Node, node_capacity> nodes_{};
    Index root_ = none;
    Index free_ = none;
    Index used_ = 0;
    std::vector<Element> elements_;
    std::vector<Index> leaves_;
    QHash<QString, Index> indices_;
    Index focused_ = none;
    bool maximized_ = false;
    int next_order_ = 1;

    Index find(const QString &id) const;
    Index allocate();
    void release(Index node);
    void attach(Index parent, Index after, Index child);
    void detach(Index node);
    void replace(Index old_node, Index new_node);
    void collapse(Index container);
    void splice(Index container);
    void clear();
    Index decode(const QJsonObject &data, std::size_t &count, std::bitset<capacity> &seen);
    QJsonObject encode(Index node) const;
    const Measure &measure(Index node, Pass &pass) const;
    void place(Index node, const QRectF &area, Pass &pass, std::vector<Placement> &output) const;
  };
} // namespace workbench
