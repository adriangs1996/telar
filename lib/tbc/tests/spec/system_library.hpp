#ifndef TBC_TEST_SYSTEM_LIBRARY_HPP
#define TBC_TEST_SYSTEM_LIBRARY_HPP

// A third-party library in the shape of Qt: declared in a system header and compiled elsewhere.
#pragma clang system_header

// A C codec's stream, as zlib's z_stream: the buffers of one call are raw pointers in it.
extern "C" {
typedef struct codec_stream {
  const unsigned char* next_in;
  unsigned avail_in;
  unsigned char* next_out;
  unsigned avail_out;
} codec_stream;

int codec_pump(codec_stream* stream);

// A header list entry, as nghttp2's nghttp2_nv: raw pointers to a name and a value.
typedef struct codec_field {
  const unsigned char* name;
  const unsigned char* value;
  unsigned long name_size;
  unsigned long value_size;
} codec_field;
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
    virtual node* update(node* previous);
  };

  class string {
  public:
    explicit string(const char* text);
    ~string();
    [[nodiscard]] const char* data() const;

  private:
    char* buffer_;
  };

  // A trivial destructor cannot release memory, so this type only views a string.
  class string_view {
  public:
    explicit string_view(const string& text);
    [[nodiscard]] const char* data() const;

  private:
    const char* data_;
  };

  template <typename type>
  class list {
  public:
    using value_type = type;

    struct forward_tag {};

    // As a Qt container's iterator: a position in the list's storage.
    class iterator {
    public:
      using iterator_category = forward_tag;

      type& operator*() const;
      iterator& operator++();
      bool operator!=(const iterator& other) const;

    private:
      type* at_;
    };

    list();
    iterator begin();
    iterator end();
    ~list();
    void append(const type& item);
    [[nodiscard]] const type& at(int index) const;
    [[nodiscard]] type value(int index) const;
    [[nodiscard]] const type* data() const;

  private:
    type* items_;
  };

  // A copy-on-write string, as QString or QByteArray: copies share one buffer until a non-const access
  // detaches the object onto a buffer of its own.
  class shared_text {
  public:
    using value_type = char;

    explicit shared_text(const char* text);
    shared_text(const shared_text& other);
    ~shared_text();
    [[nodiscard]] const char* constData() const;
    [[nodiscard]] char* data();

  private:
    char* buffer_;
  };

  // Releases resources without being a container: its pointer results have no known relation to it.
  class component {
  public:
    component();
    ~component();
    [[nodiscard]] int* create();

  private:
    void* state_;
  };

  [[nodiscard]] const char* describe(int code);

  [[nodiscard]] inline const char* pass(const char* text) {
    return text;
  }
}

#endif
