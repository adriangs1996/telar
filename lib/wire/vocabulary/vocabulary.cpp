module telar.wire.vocabulary;

import std;
import telar.base.diagnostics;
import telar.tbc;
import telar.base.ds;

namespace telar {

  namespace {

    constexpr std::size_t max_agent_session_bytes = 64;
    // The longest name macOS gives a POSIX shared memory object.
    constexpr std::size_t max_shared_image_name_bytes = 31;
    // Of all the tabs of a client's layout together.
    constexpr std::size_t max_client_layout_nodes = 511;

    // A percentage, and the byte a progress report sends for one it does not know.
    constexpr Byte whole_percent = 100;
    constexpr Byte unknown_percent = 255;

    // A cell's header byte: its text length in the low five bits, its width in the two above them and,
    // in the top bit, whether a style follows.
    constexpr unsigned cell_length_mask = 0x1f;
    constexpr unsigned cell_width_shift = 5;
    constexpr unsigned cell_width_mask = 0x3;
    constexpr unsigned cell_style_flag = 0x80;

    constexpr unsigned rowBit(RowFlag flag) noexcept {
      return std::to_underlying(flag);
    }

    // A row is a prompt's first line or a further line of it, never both.
    constexpr unsigned prompt_rows = rowBit(RowFlag::prompt) | rowBit(RowFlag::prompt_continuation);
    constexpr unsigned known_row_flags = rowBit(RowFlag::wrap) | rowBit(RowFlag::continuation) | rowBit(RowFlag::wide_padding) | rowBit(RowFlag::hyperlinks) | prompt_rows;

  }

#ifdef TELAR_DEBUG
  namespace debug {

    std::size_t columnWidth(std::size_t byte_count, const char* name, const char* value) {
      const auto length = [](const char* text) {
        return std::string_view{text}.size();
      };

      const auto bytes_width = byte_count == 0 ? 0 : (byte_count * 3) - 1;
      const auto name_width = length(name);
      const auto value_width = length(value);
      const auto width = bytes_width > name_width ? bytes_width : name_width;

      return width > value_width ? width : value_width;
    }

    void printBytes(std::span<const Byte> bytes, const char* name, const char* value, std::FILE* output, bool more) {
      for (std::size_t i = 0; i < bytes.size(); ++i) {
        std::print(output, "{}{:02x}", i == 0 ? "" : " ", bytes[i]);
      }

      if (more) {
        const auto bytes_width = bytes.empty() ? 0 : (bytes.size() * 3) - 1;
        const auto padding = columnWidth(bytes.size(), name, value) - bytes_width;

        std::print(output, "{:{}} | ", "", padding);
      }
    }

    void printText(const char* text, std::size_t width, std::FILE* output, const char* separator) {
      const std::string_view shown{text};

      std::print(output, "{}", shown);
      if (separator[0] != '\0') {
        std::print(output, "{:{}}{}", "", width - shown.size(), separator);
      }
    }

    void printLabel(std::size_t byte_count, const char* name, const char* value, std::FILE* output, bool more) {
      printText(name, columnWidth(byte_count, name, value), output, more ? "   " : "");
    }

    void printValue(std::size_t byte_count, const char* name, const char* value, std::FILE* output, bool more) {
      printText(value, columnWidth(byte_count, name, value), output, more ? " | " : "");
    }

  } // namespace debug
#endif

  void RequestRuntimeState::validate() const {
    if (client_identity == 0) {
      throw std::runtime_error{"Invalid client identity"};
    }
  }

  void SystemMetrics::validate() const {
    if (revision == 0 || cpu_percent > whole_percent) {
      throw std::runtime_error{"Invalid system metrics"};
    }

    if ((has_battery && battery_percent > whole_percent) || (!has_battery && battery_percent != 0)) {
      throw std::runtime_error{"Invalid battery metrics"};
    }
  }

  tbc::val_a<std::string_view> notificationLinkHost(tbc::val_a<std::string_view> link) noexcept {
    if (!link.starts_with(notification_link_scheme)) {
      return {};
    }

    auto host = link;

    host.remove_prefix(notification_link_scheme.size());
    host.remove_suffix(host.size() - std::min(host.find_first_of("/?#"), host.size()));
    return host;
  }

  void BodySchema<TerminalSize>::validate(const TerminalSize& value) {
    const auto cells = static_cast<std::uint32_t>(value.cols) * value.rows;
    if (value.cols == 0 || value.rows == 0 || cells > max_cells) {
      throw EncodingError{"Invalid terminal dimensions"};
    }
  }

  std::size_t BodySchema<HistoryScopeValue>::encodedSize(const HistoryScopeValue& value, HistoryScope scope) {
    EnumByte<HistoryScope, 3>::validate(scope);
    switch (scope) {
    case HistoryScope::global:
      if (std::holds_alternative<std::monostate>(value)) {
        return 0;
      }

      break;
    case HistoryScope::cwd:
    case HistoryScope::workspace:
      if (const auto* path = std::get_if<std::string_view>(&value)) {
        return PathCodec::encodedSize(*path);
      }

      break;
    case HistoryScope::pane:
      if (const auto* id = std::get_if<std::uint64_t>(&value)) {
        NonzeroU64::validate(*id);
        return NonzeroU64::width;
      }

      break;
    }

    throw EncodingError{"History scope and value do not match"};
  }

  void BodySchema<HistoryScopeValue>::encodeBody(const HistoryScopeValue& value, std::span<Byte>& output, HistoryScope scope) {
    (void)encodedSize(value, scope);
    switch (scope) {
    case HistoryScope::global:
      break;
    case HistoryScope::cwd:
    case HistoryScope::workspace:
      PathCodec::encode(std::get<std::string_view>(value), output);
      break;
    case HistoryScope::pane:
      NonzeroU64::encode(std::get<std::uint64_t>(value), output);
      break;
    }
  }

  void BodySchema<HistoryScopeValue>::decodeBody(DecodeInput input, tbc::mut_a<HistoryScopeValue> value, DecodeStorage& /*storage*/, HistoryScope scope) {
    EnumByte<HistoryScope, 3>::validate(scope);
    switch (scope) {
    case HistoryScope::global:
      value = std::monostate{};
      break;
    case HistoryScope::cwd:
    case HistoryScope::workspace:
      value = PathCodec::decode(input);
      break;
    case HistoryScope::pane:
      value = NonzeroU64::decode(input);
      break;
    }
  }

  void BodySchema<CoordinatorReference>::validate(const CoordinatorReference& value) {
    for (const auto byte : value.session_id) {
      if (byte != 0) {
        return;
      }
    }

    throw EncodingError{"Missing coordinator session identity"};
  }

  void BodySchema<EnvironmentEntry>::validate(const EnvironmentEntry& value) {
    if (value.name.contains('=')) {
      throw EncodingError{"Invalid environment name"};
    }
  }

  void BodySchema<Launch>::validate(const Launch& value) {
    if (value.arguments.empty() || value.arguments.size() > maximum_arguments ||
        value.arguments.front().empty() || value.environment.size() > maximum_environment) {
      throw EncodingError{"Invalid launch collections"};
    }

    std::size_t arguments = 0;

    for (const auto argument : value.arguments) {
      arguments = checkedWireSize(arguments, argument.size());
    }

    std::size_t environment = 0;

    for (const auto& entry : value.environment) {
      environment = checkedWireSize(environment, entry.name.size());
      environment = checkedWireSize(environment, entry.value.size());
    }

    if (arguments > maximum_argument_bytes || environment > maximum_environment_bytes) {
      throw EncodingError{"Launch byte budget exceeded"};
    }
  }

  void BodySchema<PaneListEntry>::validate(const PaneListEntry& value) {
    if (std::ranges::adjacent_find(value.ports, std::ranges::greater_equal{}) != value.ports.end()) {
      throw EncodingError{"Listening ports must ascend without repeats"};
    }
  }

  void BodySchema<TabDescriptor>::validate(const TabDescriptor& value) {
    if (value.panes.size() > value.pane_count) {
      throw EncodingError{"Too many tab pane entries"};
    }

    for (std::size_t i = 0; i < value.panes.size(); ++i) {
      for (std::size_t j = 0; j < i; ++j) {
        if (value.panes[i].pane_id == value.panes[j].pane_id) {
          throw EncodingError{"Duplicate tab pane"};
        }
      }
    }
  }

  void BodySchema<WorktreeListEntry>::validate(const WorktreeListEntry& value) {
    if (value.path.empty() || value.path.front() != '/') {
      throw EncodingError{"Worktree path must be absolute"};
    }
  }

  void BodySchema<AgentSnapshotEntry>::validate(const AgentSnapshotEntry& value) {
    if (value.expires_at_ms < value.observed_at_ms || value.plan_done > value.plan_total ||
        (value.status != AgentStatus::blocked &&
            value.blocked_reason != AgentBlockedReason::none)) {
      throw EncodingError{"Invalid agent state"};
    }

    switch (value.title_source) {
    case AgentTitleSource::telar:
      if (value.title_state == AgentTitleState::ready) {
        throw EncodingError{"Invalid agent title"};
      }

      break;
    case AgentTitleSource::generated:
    case AgentTitleSource::manual:
    case AgentTitleSource::agent:
      if (value.title_state != AgentTitleState::ready || value.session_title.empty()) {
        throw EncodingError{"Invalid agent title"};
      }

      break;
    case AgentTitleSource::terminal:
      if (value.session_title.empty()) {
        throw EncodingError{"Invalid agent title"};
      }

      break;
    }
  }

  std::size_t BodySchema<ClientLayoutNode>::encodedSize(const ClientLayoutNode& value) {
    if (const auto* pane = std::get_if<ClientLayoutPane>(&value)) {
      return 1 + ValueCodec<ClientLayoutPane>::encodedSize(*pane);
    }

    if (const auto* split = std::get_if<ClientLayoutSplit>(&value)) {
      return 1 + ValueCodec<ClientLayoutSplit>::encodedSize(*split);
    }

    throw EncodingError{"Invalid layout node"};
  }

  void BodySchema<ClientLayoutNode>::encodeBody(const ClientLayoutNode& value, std::span<Byte>& output) {
    if (const auto* pane = std::get_if<ClientLayoutPane>(&value)) {
      u8::encode(0, output);
      ValueCodec<ClientLayoutPane>::encode(*pane, output);
    } else if (const auto* split = std::get_if<ClientLayoutSplit>(&value)) {
      u8::encode(1, output);
      ValueCodec<ClientLayoutSplit>::encode(*split, output);
    } else {
      throw EncodingError{"Invalid layout node"};
    }
  }

  void BodySchema<ClientLayoutNode>::decodeBody(std::span<const Byte>& input, ClientLayoutNode& value, DecodeStorage& storage) {
    switch (u8::decode(input)) {
    case 0:
      value = ValueCodec<ClientLayoutPane>::decode(input, storage);
      break;
    case 1:
      value = ValueCodec<ClientLayoutSplit>::decode(input, storage);
      break;
    default:
      throw EncodingError{"Unknown layout node tag"};
    }
  }

  void BodySchema<ClientTabLayout>::validate(const ClientTabLayout& value) {
    if (value.nodes.empty() || value.nodes.size() > maximum_nodes) {
      throw EncodingError{"Invalid layout node count"};
    }

    ds::Array<std::uint64_t, maximum_panes> panes{};
    std::size_t pane_count = 0;
    std::size_t pending = 1;
    bool focused = false;

    for (const auto& node : value.nodes) {
      if (pending == 0) {
        throw EncodingError{"Invalid layout tree"};
      }

      --pending;
      if (const auto* pane = std::get_if<ClientLayoutPane>(&node)) {
        if (pane_count == panes.size()) {
          throw EncodingError{"Too many layout panes"};
        }

        if (std::ranges::contains(panes.view().first(pane_count), pane->pane_id)) {
          throw EncodingError{"Duplicate layout pane"};
        }

        panes.atMut(pane_count++) = pane->pane_id;
        focused = focused || pane->pane_id == value.focused_pane;
      } else {
        pending += 2;
      }
    }

    if (pending != 0 || !focused) {
      throw EncodingError{"Invalid layout tree or focus"};
    }
  }

  void BodySchema<NotificationBody>::validate(const NotificationBody& value) {
    const auto link = value.link;
    if (link.empty()) {
      return;
    }

    if (!link.starts_with(notification_link_scheme)) {
      throw EncodingError{"Notification link must use HTTPS"};
    }

    for (const auto character : link) {
      const auto byte = static_cast<Byte>(character);
      if (byte <= first_printable_byte || byte >= delete_byte || byte == '\\') {
        throw EncodingError{"Invalid notification link"};
      }
    }

    const auto host = notificationLinkHost(link);
    if (host.empty() || host.front() == '.' || host.front() == '-' || host.back() == '.') {
      throw EncodingError{"Invalid notification host"};
    }

    for (const auto byte : host) {
      const auto alphanumeric = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                                (byte >= '0' && byte <= '9');
      if (!alphanumeric && byte != '.' && byte != '-') {
        throw EncodingError{"Invalid notification host"};
      }
    }
  }

  void BodySchema<CompletionWord>::validate(const CompletionWord& value) {
    if (value.text.empty()) {
      throw EncodingError{"Empty completion word"};
    }
  }

  void BodySchema<CommandBlock>::validate(const CommandBlock& value) {
    if (value.rows == 0) {
      throw EncodingError{"Command block without rows"};
    }
  }

  void BodySchema<PathMatch>::validate(const PathMatch& value) {
    if (value.path.empty() || (value.kind == PathKind::directory) != (value.path.back() == '/')) {
      throw EncodingError{"Invalid path kind"};
    }

    std::size_t next = 0;

    for (const auto position : value.positions) {
      if (position < next || position >= value.path.size()) {
        throw EncodingError{"Invalid path match positions"};
      }

      next = static_cast<std::size_t>(position) + 1;
    }
  }

  void BodySchema<LimitReach>::validate(const LimitReach& value) {
    const auto alphanumeric = [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
             (byte >= '0' && byte <= '9');
    };

    for (const auto byte : value.name) {
      if (!alphanumeric(byte) && byte != '.' && byte != '_' && byte != '-') {
        throw EncodingError{"Invalid limit name"};
      }
    }

    for (const auto character : value.noun) {
      const auto byte = static_cast<Byte>(character);
      if (byte < first_printable_byte || byte >= delete_byte) {
        throw EncodingError{"Invalid limit noun"};
      }
    }

    for (const auto byte : value.route) {
      if (!alphanumeric(byte) && byte != '_') {
        throw EncodingError{"Invalid limit route"};
      }
    }
  }

  void BodySchema<ImageDescription>::validate(const ImageDescription& value) {
    const auto pixels = static_cast<std::uint64_t>(value.width) * value.height;
    const auto channels = value.format == ImageFormat::rgb ? 3U : 4U;
    constexpr std::uint64_t maximum = std::uint64_t{256} * 1024 * 1024;

    if (pixels > maximum / channels || value.byte_len != pixels * channels) {
      throw EncodingError{"Invalid image byte length"};
    }
  }

  void validateAgentSession(std::string_view session, bool empty_allowed) {
    if (session.empty()) {
      if (!empty_allowed) {
        throw EncodingError{"Missing agent session"};
      }

      return;
    }

    if (session.size() > max_agent_session_bytes || session.front() == '-') {
      throw EncodingError{"Invalid agent session"};
    }

    for (const auto character : session) {
      const auto byte = static_cast<Byte>(character);
      const auto allowed = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                           (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-' ||
                           byte == ':';
      if (!allowed) {
        throw EncodingError{"Invalid agent session"};
      }
    }
  }

  void validateWorkspaceClosure(const WorkspaceLocation& workspace, bool closed, ds::Option<std::uint64_t> previous) {
    if (previous && (!closed || workspace.kind != WorkspaceLocation::Kind::workspace ||
                        *previous == workspace.id)) {
      throw EncodingError{"Invalid previous workspace"};
    }
  }

  void validateSharedImageName(std::string_view name) {
    if (name.size() < 2 || name.size() > max_shared_image_name_bytes || name.front() != '/') {
      throw EncodingError{"Invalid shared image name"};
    }

    for (const auto byte : name.substr(1)) {
      const auto allowed = (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-';
      if (!allowed) {
        throw EncodingError{"Invalid shared image name"};
      }
    }
  }

  void validateLayoutCollection(ds::Option<TabLocation> active, std::span<const ClientTabLayout> tabs) {
    std::size_t nodes = 0;
    bool active_found = !active;

    for (std::size_t i = 0; i < tabs.size(); ++i) {
      nodes += tabs[i].nodes.size();
      for (std::size_t j = 0; j < i; ++j) {
        if (sameTab(tabs[i].location, tabs[j].location) ||
            (tabs[i].workspace_active && tabs[j].workspace_active &&
                sameWorkspace(tabs[i].location.workspace, tabs[j].location.workspace))) {
          throw EncodingError{"Duplicate client layout location"};
        }
      }

      if (active && sameTab(*active, tabs[i].location) && tabs[i].workspace_active) {
        active_found = true;
      }
    }

    if (nodes > max_client_layout_nodes || !active_found) {
      throw EncodingError{"Invalid active client layout"};
    }
  }

  std::size_t ScopedHistoryValue::encodedSize(const value_type& value, HistoryScope scope) {
    return BodySchema<HistoryScopeValue>::encodedSize(value, scope);
  }

  void ScopedHistoryValue::encode(const value_type& value, std::span<Byte>& output, HistoryScope scope) {
    BodySchema<HistoryScopeValue>::encodeBody(value, output, scope);
  }

  auto ScopedHistoryValue::decode(DecodeInput input, DecodeStorage& storage, HistoryScope scope) -> Decoded<value_type> {
    value_type value{};

    BodySchema<HistoryScopeValue>::decodeBody(input, value, storage, scope);
    return value;
  }

  std::size_t TargetLaunch::encodedSize(const value_type& value, const PaneTarget& target) {
    if ((target.kind == PaneTarget::Kind::default_target) != value.hasValue()) {
      throw EncodingError{"Launch and pane target do not match"};
    }

    return value ? ValueCodec<Launch>::encodedSize(*value) : 0;
  }

  void TargetLaunch::encode(const value_type& value, std::span<Byte>& output, const PaneTarget& target) {
    (void)encodedSize(value, target);
    if (value) {
      ValueCodec<Launch>::encode(*value, output);
    }
  }

  auto TargetLaunch::decode(DecodeInput input, DecodeStorage& storage, const PaneTarget& target) -> Decoded<value_type> {
    if (target.kind != PaneTarget::Kind::default_target) {
      return ds::none;
    }

    return ValueCodec<Launch>::decode(input, storage);
  }

  void BoolByte::encode(bool value, std::span<Byte>& output) {
    u8::encode(static_cast<Byte>(value), output);
  }

  bool BoolByte::decode(std::span<const Byte>& input) {
    const auto value = u8::decode(input);
    if (value > 1) {
      throw EncodingError{"Bool value decode must be 0 or 1\0"};
    }

    return value != 0;
  }

  void PercentSentinel::encode(value_type value, std::span<Byte>& output) {
    if (value && *value > whole_percent) {
      throw EncodingError{"Invalid progress percentage"};
    }

    u8::encode(value.valueOr(unknown_percent), output);
  }

  auto PercentSentinel::decode(std::span<const Byte>& input) -> value_type {
    const auto value = u8::decode(input);
    if (value == unknown_percent) {
      return ds::none;
    }

    if (value > whole_percent) {
      throw EncodingError{"Invalid progress percentage"};
    }

    return value;
  }

  void CellStyle::validate() const {
    // The attribute bits, three bits of underline style, and the link's; the bits above them
    // stay clear.
    constexpr unsigned underline_shift = 8;
    constexpr unsigned underline_mask = 0x7;
    constexpr unsigned reserved_flags = 0xf000;

    const unsigned bits = flags;
    if ((bits & reserved_flags) != 0 || ((bits >> underline_shift) & underline_mask) > std::to_underlying(UnderlineStyle::dashed)) {
      throw EncodingError{"Invalid cell style"};
    }
  }

  void Cell::validate() const {
    const auto raw_width = static_cast<Byte>(width);
    if (raw_width > 2 || text.size() > maximum_text_bytes || (raw_width == 0 ? !text.empty() : text.empty())) {
      throw EncodingError{"Invalid terminal cell"};
    }

    style.validate();
  }

  std::size_t BodySchema<CellColor>::encodedSize(const CellColor& value) {
    EnumByte<CellColor::Kind, 2>::validate(value.kind);
    if (value.kind == CellColor::Kind::default_color) {
      return 1;
    }

    return value.kind == CellColor::Kind::indexed ? 2 : 4;
  }

  void BodySchema<CellColor>::encodeBody(const CellColor& value, std::span<Byte>& output) {
    const auto size = encodedSize(value);

    EnumByte<CellColor::Kind, 2>::encode(value.kind, output);
    for (std::size_t i = 0; i < size - 1; ++i) {
      u8::encode(value.channels[i], output);
    }
  }

  void BodySchema<CellColor>::decodeBody(std::span<const Byte>& input, CellColor& value, DecodeStorage& /*storage*/) {
    value.kind = EnumByte<CellColor::Kind, 2>::decode(input);
    for (std::size_t i = 0; i < encodedSize(value) - 1; ++i) {
      value.channels.atMut(i) = u8::decode(input);
    }
  }

  void BodySchema<CellStyle>::validate(const CellStyle& value) {
    value.validate();
  }

  CellReader::CellReader(std::span<const Byte> bytes, std::uint32_t count)
      : input_{bytes},
        remaining_{count} {}

  ds::Option<Cell> CellReader::next() {
    if (remaining_ == 0) {
      if (!input_.empty()) {
        throw EncodingError{"Trailing cell bytes"};
      }

      return ds::none;
    }

    const unsigned header = u8::decode(input_);
    const std::size_t length = header & cell_length_mask;

    if ((header & cell_style_flag) != 0) {
      DecodeStorage storage{};

      previous_style_ = ValueCodec<CellStyle>::decode(input_, storage);
    } else if (!previous_style_) {
      throw EncodingError{"First cell needs a style"};
    }

    if (length > input_.size()) {
      throw EncodingError{"Truncated cell text"};
    }

    Cell cell{.width = static_cast<CellWidth>((header >> cell_width_shift) & cell_width_mask), .style = *previous_style_, .text = input_.first(length)};

    cell.validate();
    input_ = input_.subspan(length);
    --remaining_;
    if (remaining_ == 0 && !input_.empty()) {
      throw EncodingError{"Trailing cell bytes"};
    }

    return cell;
  }

  std::size_t CellRunCodec::encodedSize(std::span<const Cell> cells) {
    std::size_t size = 0;
    const CellStyle* previous = nullptr;

    for (const auto& cell : cells) {
      cell.validate();
      size = checkedWireSize(size, 1 + cell.text.size());
      if ((previous == nullptr) || !(*previous == cell.style)) {
        size = checkedWireSize(size, ValueCodec<CellStyle>::encodedSize(cell.style));
      }

      previous = &cell.style;
    }

    return size;
  }

  tbc::val_a<std::span<Byte>> CellRunCodec::encode(std::span<const Cell> cells, tbc::val_a<std::span<Byte>> buffer) {
    const auto size = encodedSize(cells);
    if (size > buffer.size()) {
      throw EncodingError{"Cell buffer too small"};
    }

    auto output = buffer.first(size);
    const CellStyle* previous = nullptr;

    for (const auto& cell : cells) {
      const auto changed = (previous == nullptr) || !(*previous == cell.style);

      const unsigned width = std::to_underlying(cell.width);

      u8::encode(static_cast<Byte>(cell.text.size() | (width << cell_width_shift) | (changed ? cell_style_flag : 0U)), output);
      if (changed) {
        ValueCodec<CellStyle>::encode(cell.style, output);
      }

      TailBytes<Cell::maximum_text_bytes>::encode(cell.text, output);
      previous = &cell.style;
    }

    return buffer.first(size);
  }

  void TextMetadata::validate(std::uint16_t cols, std::uint16_t rows) const {
    EnumByte<MetadataStatus, 2>::validate(status);
    if (row_flags.size() != rows || links.size() > maximum_links || runs.size() > maximum_runs ||
        uris.size() > maximum_uri_bytes ||
        (status == MetadataStatus::omitted &&
            (!links.empty() || !runs.empty() || !uris.empty()))) {
      throw EncodingError{"Invalid text metadata counts"};
    }

    for (const unsigned flags : row_flags) {
      const auto wide = (flags & rowBit(RowFlag::wide_padding)) != 0;
      if ((flags & ~known_row_flags) != 0 || (flags & prompt_rows) == prompt_rows || (wide && ((flags & rowBit(RowFlag::wrap)) == 0 || cols < 2))) {
        throw EncodingError{"Invalid text row flags"};
      }
    }

    std::size_t uri_end = 0;

    for (const auto& link : links) {
      if (link.offset != uri_end || link.len == 0 || link.len > maximum_link_bytes ||
          link.len > uris.size() - uri_end) {
        throw EncodingError{"Invalid metadata link"};
      }

      uri_end += link.len;
    }

    if (uri_end != uris.size()) {
      throw EncodingError{"Unreferenced URI bytes"};
    }

    std::uint64_t previous_end = 0;
    const auto cells = static_cast<std::uint32_t>(cols) * rows;

    for (const auto& run : runs) {
      const auto end = static_cast<std::uint64_t>(run.start) + run.len;
      if (cols == 0 || run.len == 0 || run.start < previous_end || end > cells ||
          run.link_index >= links.size() || run.start / cols != (end - 1) / cols) {
        throw EncodingError{"Invalid hyperlink run"};
      }

      previous_end = end;
    }
  }

  std::span<const Byte> TextMetadata::link(std::size_t index) const {
    if (index >= links.size()) {
      throw EncodingError{"Invalid hyperlink index"};
    }

    const auto& entry = links[index];
    if (entry.offset > uris.size() || entry.len > uris.size() - entry.offset) {
      throw EncodingError{"Invalid hyperlink bounds"};
    }

    return uris.subspan(entry.offset, entry.len);
  }

  std::size_t BodySchema<TextMetadata>::encodedSize(const TextMetadata& value) {
    if (value.row_flags.size() > TextMetadata::maximum_rows || value.links.size() > TextMetadata::maximum_links || value.runs.size() > TextMetadata::maximum_runs ||
        value.uris.size() > TextMetadata::maximum_uri_bytes) {
      throw EncodingError{"Text metadata exceeds capacity"};
    }

    return min_width + value.row_flags.size() + (value.links.size() * BodySchema<MetadataLink>::payload_size) + (value.runs.size() * BodySchema<MetadataRun>::payload_size) +
           value.uris.size();
  }

  void BodySchema<TextMetadata>::encodeBody(const TextMetadata& value, std::span<Byte>& output) {
    (void)encodedSize(value);
    EnumByte<MetadataStatus, 2>::encode(value.status, output);
    u16::encode(static_cast<std::uint16_t>(value.row_flags.size()), output);
    u16::encode(static_cast<std::uint16_t>(value.links.size()), output);
    u16::encode(static_cast<std::uint16_t>(value.runs.size()), output);
    u32::encode(static_cast<std::uint32_t>(value.uris.size()), output);
    TailBytes<TextMetadata::maximum_rows>::encode(value.row_flags, output);
    for (const auto& link : value.links) {
      ValueCodec<MetadataLink>::encode(link, output);
    }

    for (const auto& run : value.runs) {
      ValueCodec<MetadataRun>::encode(run, output);
    }

    TailBytes<TextMetadata::maximum_uri_bytes>::encode(value.uris, output);
  }

  void BodySchema<TextMetadata>::decodeBody(DecodeInput input, tbc::mut_a<TextMetadata> value, DecodeStorage& storage) {
    value.status = EnumByte<MetadataStatus, 2>::decode(input);
    const auto rows = u16::decode(input);
    const auto links = u16::decode(input);
    const auto runs = u16::decode(input);
    const auto uri_length = u32::decode(input);
    if (links > TextMetadata::maximum_links || runs > TextMetadata::maximum_runs || uri_length > TextMetadata::maximum_uri_bytes ||
        rows + (static_cast<std::size_t>(links) * BodySchema<MetadataLink>::payload_size) + (static_cast<std::size_t>(runs) * BodySchema<MetadataRun>::payload_size) +
                uri_length >
            input.size()) {
      throw EncodingError{"Invalid text metadata lengths"};
    }

    value.row_flags = input.first(rows);
    input = input.subspan(rows);
    auto link_storage = storage.allocate<MetadataLink>(links);
    auto run_storage = storage.allocate<MetadataRun>(runs);

    for (auto& link : link_storage) {
      link = ValueCodec<MetadataLink>::decode(input, storage);
    }

    for (auto& run : run_storage) {
      run = ValueCodec<MetadataRun>::decode(input, storage);
    }

    value.links = link_storage;
    value.runs = run_storage;
    value.uris = input.first(uri_length);
    input = input.subspan(uri_length);
  }

  std::size_t FrameMetadataCodec::encodedSize(const value_type& value) {
    return value ? 4 + BodySchema<TextMetadata>::encodedSize(*value) : 4;
  }

  void FrameMetadataCodec::encode(const value_type& value, std::span<Byte>& output) {
    u32::encode(static_cast<std::uint32_t>(encodedSize(value) - 4), output);
    if (value) {
      ValueCodec<TextMetadata>::encode(*value, output);
    }
  }

  auto FrameMetadataCodec::decode(DecodeInput input, DecodeStorage& storage) -> Decoded<value_type> {
    const auto length = u32::decode(input);
    if (length == 0) {
      return ds::none;
    }

    if (length > maximum_bytes || length > input.size()) {
      throw EncodingError{"Invalid frame metadata length"};
    }

    auto body = input.first(length);
    auto value = ValueCodec<TextMetadata>::decode(body, storage);

    if (!body.empty()) {
      throw EncodingError{"Trailing metadata bytes"};
    }

    input = input.subspan(length);
    return value;
  }

  CellReader FrameSpan::reader() const {
    return CellReader{cells, count};
  }

  void FrameBody::validate() const {
    const auto cells = static_cast<std::uint32_t>(cols) * rows;

    if (pane_id == 0 || frame_id == 0 || base_frame_id >= frame_id || cols == 0 || rows == 0 ||
        cells > BodySchema<TerminalSize>::max_cells || spans.size() > maximum_spans) {
      throw EncodingError{"Invalid frame header"};
    }

    if ((cursor.visible && (cursor.x >= cols || cursor.y >= rows)) ||
        (!cursor.visible && (cursor.x != 0 || cursor.y != 0)) || scroll.total_rows < rows ||
        scroll.offset > scroll.total_rows - rows) {
      throw EncodingError{"Invalid cursor or scroll"};
    }

    std::uint64_t previous_end = 0;

    for (const auto& span : spans) {
      const auto end = static_cast<std::uint64_t>(span.start) + span.count;

      if (span.count == 0 || span.start < previous_end || end > cells ||
          span.cells.size() < span.count) {
        throw EncodingError{"Invalid frame span"};
      }

      previous_end = end;
    }

    if (base_frame_id == 0 &&
        (!text_metadata || spans.size() != 1 || spans[0].start != 0 || spans[0].count != cells)) {
      throw EncodingError{"Invalid screen snapshot"};
    }

    if (text_metadata) {
      text_metadata->validate(cols, rows);
    }
  }

  void BodySchema<FrameBody>::validate(const FrameBody& frame) {
    frame.validate();
  }

}
