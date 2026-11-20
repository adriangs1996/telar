module telar.runtime.traffic.proxy.authenticate;

import telar.sys.posix;
import telar.base.memory.sensitive;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The bits of a byte's low hexadecimal digit.
    constexpr unsigned low_nibble_mask = 0x0FU;

    // text.substr(offset, count) without its throw: an offset past the end gives an empty view.
    constexpr std::string_view substring(std::string_view text, std::size_t offset, std::size_t count = std::string_view::npos) noexcept {
      text.remove_prefix(std::min(offset, text.size()));
      text.remove_suffix(text.size() - std::min(count, text.size()));
      return text;
    }

    tbc::val_a<std::string_view> textOf(tbc::val_a<std::span<const std::uint8_t>> bytes) noexcept {
      return {reinterpret_cast<const char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): char may alias the bytes, and no cast-free view reads bytes as text
    }

  }

  tbc::val_a<std::span<char>> charsOf(tbc::val_a<std::span<std::uint8_t>> bytes) noexcept {
#pragma clang unsafe_buffer_usage begin
    return {reinterpret_cast<char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): char may alias the bytes, and no cast-free view writes bytes as text
#pragma clang unsafe_buffer_usage end
  }

  ProxySecret ProxySecret::generate() noexcept {
    ProxySecret secret;

    randomBytes(secret.bytes_.dataMut(), secret.bytes_.size());
    return secret;
  }

  ds::Option<ProxySecret> ProxySecret::fromHexadecimal(std::string_view text) noexcept {
    if (text.size() != hexadecimal_bytes) {
      return ds::none;
    }

    ProxySecret secret;

    for (std::size_t index = 0; index < byte_count; ++index) {
      const auto high = digit(text[index * 2]);
      const auto low = digit(text[(index * 2) + 1]);
      if (!high || !low) {
        return ds::none;
      }

      secret.bytes_.atMut(index) = static_cast<std::uint8_t>((*high << 4U) | *low);
    }

    return secret;
  }

  ProxySecret::~ProxySecret() {
    eraseSensitive(bytes_.dataMut(), bytes_.size());
  }

  bool ProxySecret::matches(const ProxySecret& other) const noexcept {
    volatile unsigned difference = 0;

    for (std::size_t index = 0; index < byte_count; ++index) {
      difference = difference | static_cast<unsigned>(bytes_[index] ^ other.bytes_[index]);
    }

    return difference == 0;
  }

  tbc::val_a<ds::Option<std::string_view>> ProxySecret::formatHexadecimal(tbc::val_a<std::span<char>> destination) const noexcept {
    if (destination.size() < hexadecimal_bytes) {
      return ds::none;
    }

    for (std::size_t index = 0; index < byte_count; ++index) {
      destination[index * 2] = hexadecimal[bytes_[index] >> 4U];
      destination[(index * 2) + 1] = hexadecimal[bytes_[index] & low_nibble_mask];
    }

    return std::string_view{destination.data(), hexadecimal_bytes};
  }

  tbc::val_a<ds::Option<std::string_view>> ProxySecret::formatUrl(tbc::val_a<std::span<char>> destination, std::uint16_t port) const noexcept {
    constexpr std::string_view prefix = "http://telar:";
    constexpr std::string_view address = "@127.0.0.1:";
    constexpr std::size_t port_digits = 5;
    if (destination.size() < prefix.size() + hexadecimal_bytes + address.size() + port_digits) {
      return ds::none;
    }

    std::ranges::copy(prefix, destination.begin());
    static_cast<void>(formatHexadecimal(destination.subspan(prefix.size(), hexadecimal_bytes)));
    std::ranges::copy(address, destination.subspan(prefix.size() + hexadecimal_bytes).begin());

    const auto digits = destination.subspan(prefix.size() + hexadecimal_bytes + address.size());
    const auto* const end = std::to_chars(digits.data(), std::to_address(digits.end()), port).ptr;

    return std::string_view{destination.data(), static_cast<std::size_t>(end - destination.data())};
  }

  ProxySecret::ProxySecret() noexcept = default;

  ds::Option<unsigned> ProxySecret::digit(char character) noexcept {
    const auto position = hexadecimal.find(asciiLower(character));

    return position == std::string_view::npos ? ds::none : ds::Option{static_cast<unsigned>(position)};
  }

  ds::Option<ProxySecret> ProxyAuthorization::parse(std::string_view head) noexcept {
    // A head presenting no credential, or more than one, authenticates nothing.
    const auto value = next(head);
    if (!value || next(head)) {
      return ds::none;
    }

    return credential(*value);
  }

  ds::Option<ProxySecret> ProxyAuthorization::credential(std::string_view value) noexcept {
    constexpr std::string_view scheme = "basic";
    // The scheme, the space after it and at least one character of credentials.
    constexpr std::size_t minimum_bytes = scheme.size() + 2;

    const auto authorization = trimText(value, " \t");
    if (authorization.size() < minimum_bytes || !asciiEqualIgnoreCase(substring(authorization, 0, scheme.size()), scheme) || authorization[scheme.size()] != ' ') {
      return ds::none;
    }

    SensitiveBuffer<decoded_capacity> decoded;
    const auto length = base64::decode(trimText(substring(authorization, scheme.size() + 1), " \t"), decoded.bytes());
    if (!length || *length != userinfo_prefix.size() + ProxySecret::hexadecimal_bytes) {
      return ds::none;
    }

    const auto userinfo = substring(textOf(decoded.bytes()), 0, *length);
    if (!userinfo.starts_with(userinfo_prefix)) {
      return ds::none;
    }

    return ProxySecret::fromHexadecimal(substring(userinfo, userinfo_prefix.size()));
  }

  bool ProxyAuthorization::present(std::string_view head) noexcept {
    return next(head).hasValue();
  }

  ds::Option<std::string_view> ProxyAuthorization::next(std::string_view& head) noexcept {
    constexpr std::string_view line_break = "\r\n";

    auto line_end = head.find(line_break);
    if (line_end == std::string_view::npos) {
      head = {};
      return ds::none;
    }

    head.remove_prefix(line_end + line_break.size());
    while (!head.empty()) {
      line_end = head.find(line_break);
      const auto line = substring(head, 0, line_end);
      const auto colon = line.find(':');
      if (colon != std::string_view::npos && asciiEqualIgnoreCase(substring(line, 0, colon), "proxy-authorization")) {
        return substring(line, colon + 1);
      }

      head.remove_prefix(line_end == std::string_view::npos ? head.size() : line_end + line_break.size());
    }

    return ds::none;
  }

  tbc::val_static<std::string_view> ProxyRejection::response() const noexcept {
    if (reason == Reason::invalid_target) {
      return "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
    }

    return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"telar\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  }

  template <Allocator Memory>
  tbc::val_a<ProxyDecision> authenticateProxy(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::val_a<std::string_view> head) noexcept {
    if (anonymous_tunnels && !ProxyAuthorization::present(head)) {
      const auto target = ProxyTarget::parse(head);
      if (!target) {
        return ProxyRejection{ProxyRejection::Reason::invalid_target};
      }

      if (policy.contains(target->hostname)) {
        return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
      }

      return ProxyAdmission{.target = *target, .authenticated = false};
    }

    const auto presented = ProxyAuthorization::parse(head);
    if (!presented) {
      return ProxyRejection{ProxyRejection::Reason::invalid_authorization};
    }

    if (!secret.matches(*presented)) {
      return ProxyRejection{ProxyRejection::Reason::unknown_credential};
    }

    const auto target = ProxyTarget::parse(head);
    if (!target) {
      return ProxyRejection{ProxyRejection::Reason::invalid_target};
    }

    return ProxyAdmission{.target = *target, .authenticated = true};
  }

  ds::Option<ProxySecret> ProxySecretFile::load(Memory& memory, int directory) {
    ErasingAllocator sensitive{memory};
    ds::Vec<unsigned char, decltype(sensitive)> bytes{sensitive};
    if (!readPrivateFile(directory, filename, bytes, maximum_file_bytes)) {
      return ds::none;
    }

    auto text = textOf(bytes.view());

    while (!text.empty() && (text.back() == '\r' || text.back() == '\n')) {
      text.remove_suffix(1);
    }

    const auto secret = ProxySecret::fromHexadecimal(text);
    if (!secret) {
      throw SystemError{"Invalid proxy secret", EINVAL};
    }

    return secret;
  }

  template <Allocator Memory>
  ProxySecret ProxySecretFile::ensure(Memory& memory, int directory) {
    if (const auto existing = load(memory, directory)) {
      return *existing;
    }

    const auto secret = ProxySecret::generate();
    SensitiveBuffer<ProxySecret::hexadecimal_bytes + 1> line;

    const auto bytes = line.bytes();

    static_cast<void>(secret.formatHexadecimal(charsOf(bytes).first(ProxySecret::hexadecimal_bytes)));
    bytes.back() = '\n';
    const auto failure = writePrivateFile(directory, filename, line.bytes(), PrivateFileMode::create_only);
    if (failure != 0) {
      throw SystemError{"Create proxy secret", failure};
    }

    return secret;
  }

  template tbc::val_a<ProxyDecision> authenticateProxy<Memory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<Memory>& policy, tbc::val_a<std::string_view> head) noexcept;
  template tbc::val_a<ProxyDecision> authenticateProxy<ConcurrentMemory>(const ProxySecret& secret, bool anonymous_tunnels, const ProxyHostPolicy<ConcurrentMemory>& policy, tbc::val_a<std::string_view> head) noexcept;
  template ProxySecret ProxySecretFile::ensure<Memory>(Memory& memory, int directory);
  template ProxySecret ProxySecretFile::ensure<ConcurrentMemory>(ConcurrentMemory& memory, int directory);

}
