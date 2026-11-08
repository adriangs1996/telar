#ifndef TBC_TEST_SYSTEM_LIBRARY_HPP
#define TBC_TEST_SYSTEM_LIBRARY_HPP

// A third-party library in the shape of Qt: declared in a system header and compiled elsewhere.
#pragma clang system_header

// A C codec's stream, as zlib's z_stream: the buffers of one call are raw pointers in it.
extern "C" {
typedef struct codec_stream {
  const unsigned char *next_in;
  unsigned avail_in;
  unsigned char *next_out;
  unsigned avail_out;
} codec_stream;
int codec_pump(codec_stream *stream);
}

namespace library {
  // A scene node an item updates through a virtual the library calls, as QQuickItem::updatePaintNode is.
  class node {
  public:
    virtual ~node();
  };

  class item {
  public:
    virtual ~item();
    virtual node *update(node *previous);
  };

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
