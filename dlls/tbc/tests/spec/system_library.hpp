#ifndef TBC_TEST_SYSTEM_LIBRARY_HPP
#define TBC_TEST_SYSTEM_LIBRARY_HPP

// A third-party library in the shape of Qt: declared in a system header and compiled elsewhere.
#pragma clang system_header

namespace library {
  class string {
  public:
    explicit string(const char *text);
    ~string();
    [[nodiscard]] const char *data() const;

  private:
    char *buffer_;
  };

  // A trivial destructor cannot release memory, so this type only views a string.
  class string_view {
  public:
    explicit string_view(const string &text);
    [[nodiscard]] const char *data() const;

  private:
    const char *data_;
  };

  template <typename type>
  class list {
  public:
    using value_type = type;

    list();
    ~list();
    void append(const type &item);
    [[nodiscard]] const type &at(int index) const;
    [[nodiscard]] type value(int index) const;
    [[nodiscard]] const type *data() const;

  private:
    type *items_;
  };

  // Releases resources without being a container: its pointer results have no known relation to it.
  class component {
  public:
    component();
    ~component();
    [[nodiscard]] int *create();

  private:
    void *state_;
  };

  [[nodiscard]] const char *describe(int code);

  [[nodiscard]] inline const char *pass(const char *text) {
    return text;
  }
}

#endif
