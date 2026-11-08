#ifndef TBC_TEST_SUPPORT_HPP
#define TBC_TEST_SUPPORT_HPP

#include "tbc/view.hpp"

#include <array>
#include <cstddef>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace spec {
  using text = tbc::view<std::string_view>;
  using text_a = tbc::view<std::string_view, tbc::lt::a>;
  using text_b = tbc::view<std::string_view, tbc::lt::b>;
  using bytes = tbc::view<std::span<const std::byte>>;
  using bytes_a = tbc::view<std::span<const std::byte>, tbc::lt::a>;
  using writable_bytes = tbc::view<std::span<std::byte>>;
  using writable_bytes_a = tbc::view<std::span<std::byte>, tbc::lt::a>;

  // A reader the checker cannot see, so it may read everything the object it is given borrows.
  void read(const void *object);

  template <typename type>
  void observe(tbc::view<const type &> value) {
    read(&value);
  }

  struct node {
    spec::text text;
    std::vector<node> children;
  };

  tbc::view<node, tbc::lt::a> parse(text_a source);
  std::string copyText(text input);

  struct byte_queue {
    bytes readable() const;
    void reserve(std::size_t capacity);
    void compact();
    writable_bytes appendUninitialized(std::size_t count);
  };

  struct retained_stream {
    bytes_a read(writable_bytes_a destination) const;
  };

  struct statement {
    spec::text text() const;
    void next();
    void reset();
    void bind(spec::text input);
  };

  struct arena {};

  struct allocation_deleter {
    tbc::view<arena *, tbc::lt::a> memory;
    void operator()(int *value) const noexcept;
  };

  using allocated_int = std::unique_ptr<int, allocation_deleter>;
  tbc::view<allocated_int, tbc::lt::a> makeOwned(tbc::view<arena &, tbc::lt::a> memory);

  struct request_queue {
    tbc::view<const std::string &> front() const;
    std::string take();
  };

  struct font_face {
    explicit font_face(bytes_a bytes);
    ~font_face();
    tbc::view<std::span<const int>> shape(spec::text text);
    bytes rasterize();

  private:
    bytes_a font_data_;
  };

  struct history_page {
    explicit history_page(tbc::view<std::span<const std::string_view>> rows);
    tbc::view<std::span<const std::string>> rows() const;
    void exchangeWith(history_page &other);
  };

  struct callback_context {};

  void enqueueBound(tbc::view<const callback_context &> context, std::function<void()> callback);
  void invokeNow(std::function<void()> callback);
  void enqueue(std::function<void()> callback);
  void initialize(writable_bytes output);
  tbc::view<const int &, tbc::lt::a> checkedAt(tbc::view<std::span<const int>, tbc::lt::a> values, std::size_t index);
}

#endif
