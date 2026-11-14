module;

#include <cstddef>

#include <cstdint>

export module telar.runtime.http1.head;

import std;

import telar.base.text;

// Interface: http1/framing.cppm
export {
  namespace telar::runtime {

    struct Http1Framing {
      enum class Kind {
        none,
        content_length,
        chunked,
        until_close,
      };

      Kind kind = Kind::none;
      std::size_t length = 0;

      bool hasBody() const noexcept;
    };

  }
}

// Interface: http1/number.cppm
export {
  namespace telar::runtime {

    template <unsigned Base>
    std::optional<std::size_t> parseHttpNumber(std::string_view text) noexcept;
    extern template std::optional<std::size_t> parseHttpNumber<10>(std::string_view text) noexcept;
    extern template std::optional<std::size_t> parseHttpNumber<16>(std::string_view text) noexcept;

    // A status code as both HTTP versions write it: three digits, 100 to 599.
    std::optional<std::uint16_t> parseHttpStatus(std::string_view text) noexcept;

    // Whether a response with `status` carries no body (RFC 9110 6.4.1), as one to HEAD never does.
    constexpr bool bodylessResponse(std::uint16_t status, bool to_head) noexcept {
      return to_head || status < 200 || status == 204 || status == 205 || status == 304;
    }

    // Whether a Content-Type names a server-sent event stream, whatever its parameters.
    bool isEventStream(std::string_view content_type) noexcept;

  }
}

// Interface: http1/head.cppm
export {
  namespace telar::runtime {

    struct Http1Head {
      static constexpr std::size_t capacity = 64 * 1024;

      Http1Framing framing;
      std::uint16_t status = 0;
      bool head_request = false;
      bool informational = false;
      bool upgrade = false;
      bool closes = false;

      static std::optional<Http1Head> analyze(std::string_view bytes, bool response, bool response_to_head = false) noexcept;

    private:
      static std::optional<Http1Framing> bodyFraming(std::string_view bytes, bool response, bool bodyless) noexcept;

      static bool connectionCloses(std::string_view bytes) noexcept;

      static bool endsWithChunked(std::string_view value) noexcept;

      static std::optional<std::uint16_t> parseStatus(std::string_view line) noexcept;

      static bool equals(std::string_view actual, std::string_view lower) noexcept;
    };

  }
}
