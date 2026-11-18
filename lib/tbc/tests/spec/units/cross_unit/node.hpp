#ifndef TBC_SPEC_CROSS_UNIT_NODE_HPP
#define TBC_SPEC_CROSS_UNIT_NODE_HPP

#include <cstddef>
#include <span>
#include <string>
#include <string_view>
#include <vector>

// Declarations whose bodies `node.cpp` defines, as a module interface declares what its
// implementation unit defines. The fixture that calls them sees no body.
namespace cross_unit {
  // A tree node instantiated in another unit, as `JsonNode<Memory>` is. A read is a const method and
  // mutable access has its own name, as Rust's `get` and `get_mut`, never a constness overload.
  template <typename memory>
  class node {
  public:
    std::span<const node> children() const noexcept;
    const node* find(std::string_view name) const noexcept;
    node* findMut(std::string_view name) noexcept;
    void append(node child);
    // Counts the nodes below this one, through itself.
    std::size_t count() const noexcept;
    // Drops the children `depth` levels below this one, through itself.
    void truncate(std::size_t depth);

  private:
    std::string name_;
    std::vector<node> children_;
  };

  extern template class node<int>;

  // Receives the nodes of a tree. A call through this type may reach any override.
  class visitor {
  public:
    virtual ~visitor();
    virtual void visit(const node<int>& target);
    virtual void prune(node<int>& target);
  };

  class counter final : public visitor {
  public:
    void visit(const node<int>& target) override;
    void prune(node<int>& target) override;

  private:
    std::size_t seen_ = 0;
  };
}

#endif
