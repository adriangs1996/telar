module telar.gui.links.cell_links;

import telar.wire.vocabulary;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;
import telar.gui.foundation.core;

namespace telar::gui {

  template <Allocator Memory>
  std::optional<LinkMatch> CellLinks::text(const Screen<Memory>& screen, CellPosition point) {
    return match({.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .scroll = screen.scroll(), .row_flags = {}}, point);
  }

  template <Allocator Memory>
  std::optional<LinkMatch> CellLinks::resolve(const Screen<Memory>& screen, CellPosition point) {
    const LinkGrid grid{.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .scroll = screen.scroll(), .row_flags = screen.rowFlags()};
    const auto index = grid.cellIndex(point);
    if (!index) {
      return {};
    }

    if (const auto* run = screen.linkRunAt(static_cast<std::uint32_t>(*index))) {
      const auto target = LinkTarget::fromUri(screen.linkAt(static_cast<std::uint32_t>(*index)));
      if (!target) {
        return {};
      }

      return LinkMatch{.target = *target, .start = grid.position(run->start), .end = grid.cellEnd(run->start + run->len - 1), .metadata_index = run->link_index};
    }

    if (screen.metadataStatus() != MetadataStatus::complete && (screen.rowFlags(*index / screen.columns()) & static_cast<Byte>(RowFlag::hyperlinks)) != 0) {
      return {};
    }

    return match(grid, point);
  }

  template std::optional<LinkMatch> CellLinks::text<telar::Memory>(const Screen<telar::Memory>& screen, CellPosition point);
  template std::optional<LinkMatch> CellLinks::text<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen, CellPosition point);
  template std::optional<LinkMatch> CellLinks::resolve<telar::Memory>(const Screen<telar::Memory>& screen, CellPosition point);
  template std::optional<LinkMatch> CellLinks::resolve<telar::ConcurrentMemory>(const Screen<telar::ConcurrentMemory>& screen, CellPosition point);

  template <std::size_t Capacity>
  BoundedText<Capacity> FilePath::decode(std::string_view text, EscapePolicy policy) {
    BoundedText<Capacity> decoded;

    while (!text.empty()) {
      if (!text.starts_with('%')) {
        decoded.append(text.substr(0, 1));
        text.remove_prefix(1);
        continue;
      }

      const auto character = escapedByte(text, policy);
      if (!character) {
        if (policy == EscapePolicy::strict) {
          throw std::invalid_argument{"InvalidFileLink"};
        }

        decoded.append(text.substr(0, 1));
        text.remove_prefix(1);
        continue;
      }

      decoded.append({&*character, 1});
      text.remove_prefix(escape_bytes);
    }

    return decoded;
  }

  std::optional<UriView> UriView::parse(std::string_view text) {
    const auto colon = text.find(':');
    if (colon == std::string_view::npos || colon == 0) {
      return {};
    }

    UriView result{.scheme = text.substr(0, colon), .path = {}};
    const auto rest = text.substr(colon + 1);
    auto path_start = std::size_t{0};

    if (rest.starts_with("//")) {
      path_start = std::min(rest.find_first_of("/?#", 2), rest.size());
      if (!result.authority(rest.substr(2, path_start - 2), rest.substr(2).starts_with('/'))) {
        return {};
      }
    }

    const auto path_end = std::min(rest.find_first_of("?#", path_start), rest.size());

    result.path = rest.substr(path_start, path_end - path_start);
    auto suffix = rest.substr(path_end);
    if (suffix.starts_with('?')) {
      const auto query_end = std::min(suffix.find('#', 1), suffix.size());

      result.query = suffix.substr(1, query_end - 1);
      suffix.remove_prefix(query_end);
    }

    if (suffix.starts_with('#')) {
      result.fragment = suffix.substr(1);
    }

    return result;
  }

  std::optional<std::uint16_t> UriView::parsePort(std::string_view text) noexcept {
    const auto negative = text.starts_with('-');
    if (text.starts_with('+') || negative) {
      text.remove_prefix(1);
    }

    const auto value = runtime::unsignedDecimal<std::uint16_t>(text);

    return !value || (negative && *value != 0) ? std::nullopt : value;
  }

  bool UriView::authority(tbc::view<std::string_view, tbc::lt::a> text, bool empty_authority_has_path) {
    if (text.empty()) {
      return empty_authority_has_path;
    }

    std::size_t host_start = 0;

    if (const auto user_info_end = text.find('@'); user_info_end != std::string_view::npos) {
      host_start = user_info_end + 1;
      const auto info = text.substr(0, user_info_end);
      const auto separator = info.find(':');

      user = info.substr(0, separator);
      if (separator != std::string_view::npos && separator + 1 < info.size()) {
        password = info.substr(separator + 1);
      }
    }

    if (host_start >= text.size()) {
      return true;
    }

    if (text[host_start] == ']') {
      return false;
    }

    auto host_end = text.size();

    if (text[host_start] == '[') {
      const auto bracket = text.rfind(']');
      if (bracket == std::string_view::npos) {
        return false;
      }

      host_end = bracket + 1;
    }

    const auto colon = text.rfind(':');
    const auto has_port = colon != std::string_view::npos && colon >= (text[host_start] == '[' ? host_end : host_start);
    if (has_port) {
      port = parsePort(text.substr(colon + 1));
      if (!port) {
        return false;
      }

      host_end = std::min(host_end, colon);
    }

    if (host_start >= host_end) {
      return false;
    }

    host = text.substr(host_start, host_end - host_start);

    return true;
  }

  std::optional<LinkScheme> UriRecognizer::classify(std::string_view text) {
    if (text.empty() || text.size() > LinkText::maximum_uri_bytes || std::ranges::any_of(text, LinkText::separator) || !LinkText::validUtf8(text)) {
      return {};
    }

    const auto uri = UriView::parse(text);
    if (!uri) {
      return {};
    }

    for (const auto& prefix : prefixes) {
      const auto name = prefix.text.substr(0, prefix.text.find(':'));
      if (!runtime::asciiEqualIgnoreCase(uri->scheme, name)) {
        continue;
      }

      switch (prefix.scheme) {
      case LinkScheme::http:
      case LinkScheme::https:
        return uri->host ? std::optional{prefix.scheme} : std::nullopt;
      case LinkScheme::file:
        return uri->path.starts_with('/') ? std::optional{prefix.scheme} : std::nullopt;
      case LinkScheme::external:
        if (text.size() <= uri->scheme.size() + 1 || (text.substr(uri->scheme.size() + 1).starts_with("//") && !uri->host)) {
          return {};
        }

        return prefix.scheme;
      case LinkScheme::path:
        return {};
      }
    }

    return {};
  }

  std::optional<LinkTextMatch> UriRecognizer::extract(std::string_view line, std::size_t byte_offset) {
    if (byte_offset >= line.size()) {
      return {};
    }

    const auto lower = byte_offset - std::min(byte_offset, LinkText::maximum_uri_bytes - 1);
    auto index = byte_offset + 1;

    while (index > lower) {
      --index;
      const auto prefix = prefixAt(line.substr(index));
      if (!prefix || !validStart(line, index)) {
        continue;
      }

      const auto limit = index + std::min(line.size() - index, LinkText::maximum_uri_bytes + 1);
      auto end = index;

      while (end < limit && !LinkText::separator(line[end])) {
        ++end;
      }

      if (end < line.size() && !LinkText::separator(line[end])) {
        continue;
      }

      end = index + trimEnd(line.substr(index, end - index));
      if (byte_offset >= end || classify(line.substr(index, end - index)) != prefix->scheme) {
        continue;
      }

      return LinkTextMatch{.scheme = prefix->scheme, .extent = {.start = index, .end = end}, .destination = {.start = index, .end = end}};
    }

    return {};
  }

  std::optional<UriRecognizer::Prefix> UriRecognizer::prefixAt(std::string_view text) {
    for (const auto& prefix : prefixes) {
      if (text.size() >= prefix.text.size() && runtime::asciiEqualIgnoreCase(text.substr(0, prefix.text.size()), prefix.text)) {
        return prefix;
      }
    }

    return {};
  }

  bool UriRecognizer::validStart(std::string_view line, std::size_t index) noexcept {
    return index == 0 || (!LinkText::alphanumeric(line[index - 1]) && line[index - 1] != '_');
  }

  std::size_t UriRecognizer::trimEnd(std::string_view text) noexcept {
    constexpr std::string_view openers{"([{"};
    constexpr std::string_view closers{")]}"};
    constexpr std::size_t pair_count = 3;
    std::array<std::ptrdiff_t, pair_count> balance{};

    for (const auto byte : text) {
      if (const auto index = openers.find(byte); index < balance.size()) {
        --balance[index];
      } else if (const auto index = closers.find(byte); index != std::string_view::npos) {
        ++balance[index];
      }
    }

    auto end = text.size();

    while (end != 0) {
      const auto byte = text[end - 1];
      if (std::string_view{".,;:!?"}.contains(byte)) {
        --end;

        continue;
      }

      const auto pair = closers.find(byte);
      if (pair == std::string_view::npos || balance[pair] <= 0) {
        break;
      }

      --balance[pair];
      --end;
    }

    return end;
  }

  std::optional<LinkTarget> LinkTarget::fromUri(std::string_view text) {
    const auto scheme = UriRecognizer::classify(text);

    return scheme ? std::optional{LinkTarget{*scheme, text}} : std::nullopt;
  }

  std::optional<LinkTarget> LinkTarget::fromPath(std::string_view text) {
    if (text.empty() || text.size() > LinkText::maximum_uri_bytes || !LinkText::validUtf8(text) || std::ranges::any_of(text, LinkText::control)) {
      return {};
    }

    return LinkTarget{LinkScheme::path, text};
  }

  LinkScheme LinkTarget::scheme() const noexcept {
    return scheme_;
  }

  std::string_view LinkTarget::text() const noexcept {
    return text_.view();
  }

  bool LinkTarget::operator==(const LinkTarget& other) const noexcept {
    return scheme_ == other.scheme_ && text() == other.text();
  }

  LinkTarget::LinkTarget(LinkScheme scheme, std::string_view text)
      : scheme_(scheme) {
    text_.assign(text);
  }

  std::optional<LinkTextMatch> MarkdownLinks::extract(std::string_view line, std::size_t byte_offset) {
    if (byte_offset >= line.size()) {
      return {};
    }

    const auto lower = byte_offset - std::min(byte_offset, LinkText::maximum_span_bytes);
    auto index = byte_offset + 1;

    while (index > lower) {
      --index;
      if (line[index] != '[') {
        continue;
      }

      if (const auto found = parseAt(line, index)) {
        return byte_offset < found->extent.end ? found : std::nullopt;
      }
    }

    return {};
  }

  std::optional<LinkTextMatch> MarkdownLinks::parseAt(std::string_view line, std::size_t start) {
    constexpr std::size_t label_delimiters = 2;
    const auto label_limit = start + std::min(line.size() - start, label_delimiters + LinkText::maximum_label_bytes);
    auto label_end = start + 1;

    while (label_end < label_limit && line[label_end] != ']') {
      if (LinkText::control(line[label_end])) {
        return {};
      }

      ++label_end;
    }

    if (label_end >= label_limit || label_end + 1 >= line.size() || line[label_end] != ']' || line[label_end + 1] != '(') {
      return {};
    }

    const auto destination_start = label_end + label_delimiters;
    const auto limit = destination_start + std::min(line.size() - destination_start, LinkText::maximum_uri_bytes + 1);
    std::size_t depth = 0;
    auto end = destination_start;

    while (end < limit) {
      const auto byte = line[end];
      if (byte == '(') {
        ++depth;
      } else if (byte == ')') {
        if (depth == 0) {
          break;
        }

        --depth;
      } else if (LinkText::separator(byte)) {
        return {};
      }

      ++end;
    }

    if (end >= limit) {
      return {};
    }

    const auto scheme = UriRecognizer::classify(line.substr(destination_start, end - destination_start));
    if (!scheme) {
      return {};
    }

    return LinkTextMatch{.scheme = *scheme, .extent = {.start = start, .end = end + 1}, .destination = {.start = destination_start, .end = end}};
  }

  std::optional<LinkTextMatch> PathRecognizer::extract(std::string_view line, std::size_t byte_offset) {
    if (byte_offset >= line.size() || !tokenByte(line[byte_offset])) {
      return {};
    }

    auto start = byte_offset;

    while (start > 0 && tokenByte(line[start - 1])) {
      --start;
    }

    auto end = byte_offset + 1;

    while (end < line.size() && tokenByte(line[end])) {
      ++end;
    }

    if (end - start > LinkText::maximum_uri_bytes) {
      return {};
    }

    auto segment = start;

    while (segment < end) {
      const auto separator = std::min(line.substr(0, end).find(':', segment), end);
      const auto suffix_end = positionEnd(line.substr(0, end), separator);
      const auto first = segment + trimLeading(line.substr(segment, separator - segment));
      const auto last = suffix_end == separator ? first + trimTrailing(line.substr(first, separator - first)) : separator;
      const auto match_end = suffix_end == separator ? last : suffix_end;
      if (looksLikePath(line.substr(first, last - first), suffix_end != separator) && byte_offset >= first && byte_offset < match_end) {
        return LinkTextMatch{.scheme = LinkScheme::path, .extent = {.start = first, .end = match_end}, .destination = {.start = first, .end = match_end}};
      }

      segment = std::max(separator, suffix_end) + 1;
    }

    return {};
  }

  PathLocation PathRecognizer::locate(std::string_view text) {
    const auto separator = text.find(':');
    if (separator == std::string_view::npos) {
      return {.path = text};
    }

    PathLocation result{.path = text.substr(0, separator)};
    const auto line_digits = numberLength(text.substr(separator + 1));

    result.line = number(text.substr(separator + 1, line_digits));
    const auto column_start = separator + 1 + line_digits;
    if (line_digits != 0 && column_start < text.size() && text[column_start] == ':') {
      const auto column_digits = numberLength(text.substr(column_start + 1));

      result.column = number(text.substr(column_start + 1, column_digits));
    }

    return result;
  }

  std::optional<PathLocation> PathRecognizer::fragment(std::string_view text) {
    if (text.starts_with('L') || text.starts_with('l')) {
      text.remove_prefix(1);
    }

    const auto line_digits = numberLength(text);
    if (line_digits == 0) {
      return {};
    }

    PathLocation result{.path = {}, .line = number(text.substr(0, line_digits))};

    text.remove_prefix(line_digits);
    if (text.starts_with(':') || text.starts_with('C') || text.starts_with('c')) {
      const auto column_digits = numberLength(text.substr(1));
      if (column_digits == 0) {
        return {};
      }

      result.column = number(text.substr(1, column_digits));
      text.remove_prefix(1 + column_digits);
    }

    return text.empty() || text.starts_with('-') ? std::optional{result} : std::nullopt;
  }

  std::size_t PathRecognizer::numberLength(std::string_view text) noexcept {
    const auto* const end = std::ranges::find_if_not(text, LinkText::digit);
    const auto length = static_cast<std::size_t>(end - text.begin());

    return length > maximum_number_digits ? 0 : length;
  }

  std::uint32_t PathRecognizer::number(std::string_view text) noexcept {
    std::uint32_t result = 0;

    static_cast<void>(std::from_chars(text.data(), text.data() + text.size(), result));

    return result;
  }

  std::size_t PathRecognizer::positionEnd(std::string_view token, std::size_t colon) {
    if (colon >= token.size()) {
      return colon;
    }

    const auto line_digits = numberLength(token.substr(colon + 1));
    if (line_digits == 0) {
      return colon;
    }

    const auto line_end = colon + 1 + line_digits;
    if (line_end >= token.size() || token[line_end] != ':') {
      return line_end;
    }

    const auto column_digits = numberLength(token.substr(line_end + 1));

    return column_digits == 0 ? line_end : line_end + 1 + column_digits;
  }

  bool PathRecognizer::looksLikePath(std::string_view text, bool positioned) {
    if (text.size() < 2 || text.front() == '-' || text.front() == '+' || text.starts_with("//") || !std::ranges::any_of(text, LinkText::alphanumeric)) {
      return false;
    }

    if (text.starts_with('/') || text.starts_with("~/") || text.starts_with("./") || text.starts_with("../")) {
      return true;
    }

    const auto slash = text.rfind('/');
    if (slash == std::string_view::npos && !positioned) {
      return false;
    }

    const auto name = text.substr(slash == std::string_view::npos ? 0 : slash + 1);
    const auto dot = name.rfind('.');

    return dot != std::string_view::npos && dot != 0 && dot + 1 < name.size();
  }

  std::size_t PathRecognizer::trimLeading(std::string_view text) noexcept {
    std::size_t start = 0;

    while (start < text.size() && static_cast<unsigned char>(text[start]) >= LinkText::first_non_ascii) {
      ++start;
    }

    return start;
  }

  std::size_t PathRecognizer::trimTrailing(std::string_view text) noexcept {
    auto end = text.size();

    while (end != 0 && (text[end - 1] == '.' || static_cast<unsigned char>(text[end - 1]) >= LinkText::first_non_ascii)) {
      --end;
    }

    return end;
  }

  bool PathRecognizer::tokenByte(char byte) noexcept {
    return LinkText::alphanumeric(byte) || std::string_view{"/._-~+@%:"}.contains(byte) || static_cast<unsigned char>(byte) >= LinkText::first_non_ascii;
  }

  std::optional<LinkMatch> CellLinks::match(const LinkGrid& grid, CellPosition point) {
    const auto cursor = grid.cellIndex(point);
    if (!cursor) {
      return {};
    }

    const auto first = windowStart(grid, *cursor);
    if (!first) {
      return {};
    }

    std::array<char, window_bytes> storage{};
    const auto window = readWindow(grid, *first, *cursor, storage);
    if (!window) {
      return {};
    }

    const auto bytes = std::string_view{storage.data(), window->length};
    auto found = MarkdownLinks::extract(bytes, window->cursor);
    if (!found) {
      found = UriRecognizer::extract(bytes, window->cursor);
    }

    if (!found) {
      found = PathRecognizer::extract(bytes, window->cursor);
    }

    if (!found) {
      return {};
    }

    const auto extent = positions(grid, *first, found->extent);
    if (!extent || !grid.complete(extent->first, extent->second)) {
      return {};
    }

    const auto destination = found->destination.view(bytes);
    const auto target = found->scheme == LinkScheme::path ? LinkTarget::fromPath(destination) : LinkTarget::fromUri(destination);

    return target ? std::optional{LinkMatch{.target = *target, .start = extent->first, .end = extent->second}} : std::nullopt;
  }

  std::optional<std::size_t> CellLinks::windowStart(const LinkGrid& grid, std::size_t index) noexcept {
    std::size_t visited = 0;
    std::size_t bytes = 0;

    while (bytes <= LinkText::maximum_span_bytes) {
      if (visited++ == maximum_walk_cells) {
        return {};
      }

      const auto previous = grid.previous(index);
      if (!previous) {
        break;
      }

      index = *previous;
      bytes += grid.cells[index].utf8().size();
    }

    return index;
  }

  std::optional<CellLinks::Window> CellLinks::readWindow(const LinkGrid& grid, std::size_t index, std::size_t cursor, std::span<char> storage) noexcept {
    std::size_t visited = 0;
    std::size_t length = 0;
    std::optional<std::size_t> cursor_offset;

    while (true) {
      if (visited++ == maximum_walk_cells) {
        return {};
      }

      if (index == cursor) {
        cursor_offset = length;
      }

      const auto text = grid.cells[index].utf8();
      if (text.size() > storage.size() - length) {
        break;
      }

      std::ranges::copy(text, storage.subspan(length).begin());
      length += text.size();
      if (cursor_offset && length - *cursor_offset >= LinkText::maximum_span_bytes + CellValue::text_capacity) {
        break;
      }

      const auto next = grid.next(index);
      if (!next) {
        break;
      }

      index = *next;
    }

    return cursor_offset ? std::optional{Window{.length = length, .cursor = *cursor_offset}} : std::nullopt;
  }

  std::optional<std::pair<CellPosition, CellPosition>> CellLinks::positions(const LinkGrid& grid, std::size_t index, TextRange extent) noexcept {
    std::size_t offset = 0;
    std::optional<CellPosition> first;

    while (true) {
      const auto end = offset + grid.cells[index].utf8().size();
      if (!first && offset <= extent.start && end > extent.start) {
        first = grid.position(index);
      }

      if (end >= extent.end) {
        return first ? std::optional{std::pair{*first, grid.cellEnd(index)}} : std::nullopt;
      }

      offset = end;
      const auto next = grid.next(index);
      if (!next) {
        return {};
      }

      index = *next;
    }
  }

  FilePath FilePath::parse(const LinkTarget& target) {
    switch (target.scheme()) {
    case LinkScheme::file:
      return fromUri(target.text());
    case LinkScheme::path:
      return fromProse(target.text());
    default:
      throw std::invalid_argument{"NotFileLink"};
    }
  }

  std::string_view FilePath::text() const noexcept {
    return path_.view();
  }

  std::uint32_t FilePath::line() const noexcept {
    return line_;
  }

  std::uint32_t FilePath::column() const noexcept {
    return column_;
  }

  FilePath::FilePath(PathLocation location)
      : line_(location.line),
        column_(location.line == 0 ? 0 : location.column) {
    path_.assign(location.path);
  }

  FilePath FilePath::fromProse(std::string_view text) {
    const auto location = PathRecognizer::locate(text);
    if (location.path.empty() || location.path.starts_with('-')) {
      throw std::invalid_argument{"InvalidFileLink"};
    }

    return FilePath{location};
  }

  std::optional<char> FilePath::escapedByte(std::string_view text, EscapePolicy policy) noexcept {
    if (text.size() < escape_bytes) {
      return {};
    }

    unsigned byte = 0;
    const auto* const first = text.data() + (policy == EscapePolicy::tolerant && text[1] == '+' ? 2 : 1);
    const auto result = std::from_chars(first, text.data() + escape_bytes, byte, hexadecimal_base);
    if (result.ec == std::errc{} && result.ptr == text.data() + escape_bytes) {
      return static_cast<char>(byte);
    }

    return policy == EscapePolicy::tolerant && text[1] == '-' && text[2] == '0' ? std::optional{char{0}} : std::nullopt;
  }

  void FilePath::validateHost(std::string_view host) {
    if (host.empty() || runtime::asciiEqualIgnoreCase(host, "localhost")) {
      return;
    }

    if (!host.contains('%')) {
      throw std::invalid_argument{"RemoteFileLink"};
    }

    try {
      const auto decoded = decode<maximum_host_bytes>(host, EscapePolicy::tolerant);
      if (runtime::asciiEqualIgnoreCase(decoded.view(), "localhost")) {
        return;
      }
    } catch (const std::length_error&) {
      throw std::length_error{"NoSpaceLeft"};
    }

    throw std::invalid_argument{"RemoteFileLink"};
  }

  FilePath FilePath::fromUri(std::string_view text) {
    const auto parsed = UriView::parse(text);
    if (!parsed || parsed->user || parsed->password || parsed->port || parsed->query) {
      throw std::invalid_argument{"InvalidFileLink"};
    }

    PathLocation location{.path = {}};

    if (parsed->fragment) {
      const auto fragment = PathRecognizer::fragment(*parsed->fragment);
      if (!fragment) {
        throw std::invalid_argument{"InvalidFileLink"};
      }

      location = *fragment;
    }

    if (parsed->host) {
      validateHost(*parsed->host);
    }

    const auto decoded = decode<LinkText::maximum_uri_bytes>(parsed->path);
    if (!decoded.view().starts_with('/') || decoded.view().contains('\0')) {
      throw std::invalid_argument{"InvalidFileLink"};
    }

    location.path = decoded.view();

    return FilePath{location};
  }

}
