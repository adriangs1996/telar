export module telar.runtime.traffic.http1.head;

import std;

import telar.base.ds;

// Interface: http1/framing.cppm
export {
  namespace telar::runtime {

    struct Http1Framing {
      enum class Kind : std::uint8_t {
        none,
        content_length,
        chunked,
        until_close,
      };

      Kind kind = Kind::none;
      std::size_t length = 0;

      [[nodiscard]] bool hasBody() const noexcept;
    };

  }
}

// Interface: http1/number.cppm
export {
  namespace telar::runtime {

    // The bases HTTP writes its numbers in: lengths in decimal, chunk sizes in hexadecimal.
    inline constexpr unsigned http_decimal = 10;
    inline constexpr unsigned http_hexadecimal = 16;

    // The status codes HTTP's framing rules name (RFC 9110 15).
    struct HttpStatus {
      static constexpr std::uint16_t minimum = 100;
      static constexpr std::uint16_t switching_protocols = 101;
      static constexpr std::uint16_t first_success = 200;
      static constexpr std::uint16_t no_content = 204;
      static constexpr std::uint16_t reset_content = 205;
      static constexpr std::uint16_t not_modified = 304;
      static constexpr std::uint16_t maximum = 599;
    };

    template <unsigned Base>
    ds::Option<std::size_t> parseHttpNumber(std::string_view text) noexcept;
    extern template ds::Option<std::size_t> parseHttpNumber<http_decimal>(std::string_view text) noexcept;
    extern template ds::Option<std::size_t> parseHttpNumber<http_hexadecimal>(std::string_view text) noexcept;

    // A status code as both HTTP versions write it: three digits, 100 to 599.
    ds::Option<std::uint16_t> parseHttpStatus(std::string_view text) noexcept;

    // Whether a response with `status` carries no body (RFC 9110 6.4.1), as one to HEAD never does.
    constexpr bool bodylessResponse(std::uint16_t status, bool to_head) noexcept {
      return to_head || status < HttpStatus::first_success || status == HttpStatus::no_content || status == HttpStatus::reset_content || status == HttpStatus::not_modified;
    }

    // Whether a Content-Type names a server-sent event stream, whatever its parameters.
    bool isEventStream(std::string_view content_type) noexcept;

  }
}

// Interface: http1/head.cppm
export {
  namespace telar::runtime {

    struct Http1Head {
      static constexpr std::size_t capacity = std::size_t{64} * 1024;

      Http1Framing framing;
      std::uint16_t status = 0;
      bool head_request = false;
      bool informational = false;
      bool upgrade = false;
      bool closes = false;

      static ds::Option<Http1Head> analyze(std::string_view bytes, bool response, bool response_to_head = false) noexcept;

    private:
      static ds::Option<Http1Framing> bodyFraming(std::string_view bytes, bool response, bool bodyless) noexcept;

      static bool connectionCloses(std::string_view bytes) noexcept;

      static ds::Option<std::uint16_t> parseStatus(std::string_view line) noexcept;
    };

  }
}
