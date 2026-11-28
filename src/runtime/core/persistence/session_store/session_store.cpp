module telar.runtime.core.persistence.session_store;

import telar.wire.agents;
import telar.platform.error;
import telar.platform.fs;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime::checkpoint {

  namespace {

    // The versions that changed a record: titles, labels every tab has, the pane a resumed agent
    // ran in, its arguments' 32-bit length, a worktree's dispatcher and its coordinator, and
    // what kind of pane a pane is.
    constexpr std::uint16_t titled_version = 2;
    constexpr std::uint16_t labeled_version = 3;
    constexpr std::uint16_t dropped_pane_version = 4;
    constexpr std::uint16_t dispatched_version = 7;
    constexpr std::uint16_t in_pane_version = 8;
    constexpr std::uint16_t long_arguments_version = 9;
    constexpr std::uint16_t coordinator_version = 10;
    constexpr std::uint16_t kinds_version = 11;
    // Since when a pane's record ends with the windows of an explorer.
    constexpr std::uint16_t explorer_version = 13;
    // Since when the final message of the pane's agent follows them.
    constexpr std::uint16_t final_message_version = 14;

    constexpr std::size_t maximum_title_bytes = 96;

    // The permission bits of a file's group and of others, which a private file leaves clear.
    constexpr mode_t shared_permissions = 0077;

    // Writes `name` and `suffix` into `destination` as a C string; false when they do not fit.
    bool suffixedName(std::span<char> destination, std::string_view name, std::string_view suffix) noexcept {
      if (name.size() + suffix.size() >= destination.size()) {
        return false;
      }

      const auto rest = std::ranges::copy(name, destination.begin()).out;

      *std::ranges::copy(suffix, rest).out = '\0';
      return true;
    }

  }

  void validatePath(std::string_view path) {
    if (path.empty() || path.size() > maximum_path_bytes || path.contains('\0')) {
      throw EncodingError{"Invalid checkpoint directory"};
    }
  }

  void validateTitle(std::string_view title, AgentTitleSource source) {
    if (title.empty()) {
      if (source != AgentTitleSource::telar) {
        throw EncodingError{"Empty checkpoint title has a source"};
      }

      return;
    }

    DisplayText16<maximum_title_bytes, false>::validate(title);
    if (source != AgentTitleSource::generated && source != AgentTitleSource::manual && source != AgentTitleSource::agent) {
      throw EncodingError{"Checkpoint title is not durable"};
    }
  }

  template <Allocator Memory>
  FileStore<Memory>::FileStore(Memory& memory, std::string_view path)
      : parent_(openPrivateParent(path)),
        name_(memory, path.substr(path.rfind('/') + 1)) {}

  template <Allocator Memory>
  bool FileStore<Memory>::load(ds::Vec<Byte, Memory>& bytes) {
    return readPrivateFile(parent_.get(), name_, bytes, maximum_bytes);
  }

  template <Allocator Memory>
  FileDescriptor FileStore<Memory>::lock() const {
    ds::Array<char, NAME_MAX + 1> name{};
    if (!suffixedName(name.viewMut(), name_.view(), ".lock")) {
      throw SystemError{"Session lock path is too long", ENAMETOOLONG};
    }

    auto file = openLockFile(parent_.get(), name.data());
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0) {
      throw SystemError{"Open session lock"};
    }

    if (!S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || state.st_nlink != 1 || (state.st_mode & shared_permissions) != 0) {
      throw SystemError{"Unsafe session lock", EACCES};
    }

    while (::flock(file.get(), LOCK_EX) != 0) {
      if (sys::lastError() != EINTR) {
        throw SystemError{"Lock session"};
      }
    }

    return file;
  }

  template <Allocator Memory>
  FileStore<Memory>::Result FileStore<Memory>::observe(const Request& bytes) noexcept {
    return writePrivateFile(parent_.get(), name_, bytes, PrivateFileMode::replace);
  }

  template <Allocator Memory>
  void FileStore<Memory>::quarantine() noexcept {
    ds::Array<char, NAME_MAX + 1> destination{};
    if (suffixedName(destination.viewMut(), name_.view(), ".corrupt")) {
      ::renameat(parent_.get(), name_.data(), parent_.get(), destination.data());
    }
  }

  template <Allocator Memory>
  void FileStore<Memory>::stop() noexcept {}

  template <Allocator Memory>
  void FileStore<Memory>::setAside(Memory& memory, std::string_view path) {
    const auto parent = openPrivateParent(path);
    const ds::String<Memory> name{memory, path.substr(path.rfind('/') + 1)};
    ds::String<Memory> previous{memory, name};

    previous.append(".previous");
    if (::renameat(parent.get(), name.data(), parent.get(), previous.data()) != 0 && sys::lastError() != ENOENT) {
      throw SystemError{"Set previous session aside"};
    }
  }

  template class FileStore<SystemAllocator>;
  template class FileStore<ConcurrentMemory>;

  Reader::Reader(std::span<const Byte> bytes)
      : input_(bytes) {
    if (bytes.size() > maximum_bytes || text(magic.size()) != magic) {
      throw EncodingError{"Invalid checkpoint header"};
    }

    version_ = u16::decode(input_);
    if (version_ == 0 || version_ > current_version) {
      throw EncodingError{"Unsupported checkpoint version"};
    }

    counters = {.workspace = u64::decode(input_), .tab = u64::decode(input_), .pane = u64::decode(input_), .generation = u64::decode(input_)};
    if (counters.workspace == 0 || counters.tab == 0 || counters.pane == 0 || counters.generation == 0) {
      throw EncodingError{"Invalid checkpoint counters"};
    }
  }

  bool Reader::boolean() {
    const auto value = u8::decode(input_);
    if (value > 1) {
      throw EncodingError{"Invalid checkpoint boolean"};
    }

    return value != 0;
  }

  std::string_view Reader::text(std::size_t length) {
    if (length > input_.size()) {
      throw EncodingError{"Truncated checkpoint text"};
    }

    const auto result = textView(input_.first(length));

    input_ = input_.subspan(length);
    return result;
  }

  std::string_view Reader::text16() {
    return text(u16::decode(input_));
  }

  std::span<const Byte> Reader::bytes32() {
    return byteView(text(u32::decode(input_)));
  }

  WorkspaceRecord Reader::workspace() {
    const WorkspaceRecord record{.id = u64::decode(input_), .path = text16(), .name = text16(), .first_tab = u64::decode(input_), .first_label = text16()};

    validatePath(record.path);
    if (record.name.size() > maximum_name_bytes || record.first_label.size() > maximum_label_bytes || (version_ < labeled_version && record.first_label.empty())) {
      throw EncodingError{"Invalid checkpoint workspace label"};
    }

    return record;
  }

  TabRecord Reader::tab() {
    const TabRecord record{.workspace = u64::decode(input_), .id = u64::decode(input_), .label = text16()};
    if (record.label.size() > maximum_label_bytes || (version_ < labeled_version && record.label.empty())) {
      throw EncodingError{"Invalid checkpoint tab label"};
    }

    return record;
  }

  PlacesRecord Reader::places() {
    const PlacesRecord record{.payload = bytes32()};
    if (record.payload.empty() || record.payload.size() > maximum_places_bytes) {
      throw EncodingError{"Invalid checkpoint places size"};
    }

    return record;
  }

  LayoutRecord Reader::layout() {
    const LayoutRecord record{.identity = u64::decode(input_), .last_used = u64::decode(input_), .payload = bytes32()};
    if (record.payload.empty() || record.payload.size() > maximum_layout_bytes) {
      throw EncodingError{"Invalid checkpoint layout size"};
    }

    return record;
  }

  bool Reader::accepted(const WorktreeRecord& record) {
    try {
      validatePath(record.registration.path);
      if (record.id == 0) {
        throw EncodingError{"Invalid checkpoint worktree identity"};
      }

      Codec::encodedSize(record.registration);
    } catch (const EncodingError&) {
      ++skipped_worktrees_;
      return false;
    }

    return true;
  }

  EncodedBlocksRecord Reader::blocks() {
    EncodedBlocksRecord record{.pane = u64::decode(input_), .count = u16::decode(input_)};
    if (record.count > PaneBlocks::capacity) {
      throw EncodingError{"Checkpoint has too many blocks"};
    }

    // Read once here, so a malformed block fails the checkpoint as any record does.
    BlockReader blocks{input_};

    for (std::size_t index = 0; index < record.count; ++index) {
      static_cast<void>(blocks.next());
    }

    const auto length = blocks.consumed(input_);

    record.encoded = input_.first(length);
    input_ = input_.subspan(length);
    return record;
  }

  BlockReader::BlockReader(tbc::val_a<std::span<const Byte>> bytes) noexcept
      : input_(bytes) {}

  tbc::val_a<CommandBlockRecord> BlockReader::next() {
    CommandBlockRecord block;
    const auto state = u8::decode(input_);

    block.status = static_cast<std::int32_t>(u32::decode(input_));
    block.duration_ms = u32::decode(input_);
    block.started_ms = static_cast<std::int64_t>(u64::decode(input_));
    block.lines = u16::decode(input_);
    const auto nest = u8::decode(input_);

    block.command = text16();
    block.directory = text16();
    block.host = text16();
    block.user = text16();
    block.branch = text16();
    if (state > std::to_underlying(CommandBlockState::background) || nest > std::to_underlying(CommandBlockNest::inside) || block.command.size() > CommandBlockRing::command_bytes || block.directory.size() > max_block_directory_bytes || block.host.size() > max_block_host_bytes || block.user.size() > max_block_user_bytes || block.branch.size() > max_branch_bytes) {
      throw EncodingError{"Invalid checkpoint block"};
    }

    block.state = static_cast<CommandBlockState>(state);
    block.nest = static_cast<CommandBlockNest>(nest);
    return block;
  }

  std::size_t BlockReader::consumed(std::span<const Byte> bytes) const noexcept {
    return bytes.size() - input_.size();
  }

  tbc::val_a<std::string_view> BlockReader::text16() {
    const auto length = u16::decode(input_);
    if (length > input_.size()) {
      throw EncodingError{"Truncated checkpoint block"};
    }

    const auto text = textView(input_.first(length));

    input_ = input_.subspan(length);
    return text;
  }

  ds::Option<PaneRecord> Reader::pane() {
    PaneRecord record{.id = u64::decode(input_), .workspace = u64::decode(input_), .tab = u64::decode(input_), .cwd = text16(), .columns = u16::decode(input_), .rows = u16::decode(input_), .argument_count = u16::decode(input_), .arguments = {}};

    record.arguments = version_ >= long_arguments_version ? text(u32::decode(input_)) : text16();
    validatePath(record.cwd);
    if (record.argument_count > maximum_arguments || record.arguments.size() > maximum_argument_bytes || std::ranges::count(record.arguments, '\0') != record.argument_count) {
      throw EncodingError{"Invalid checkpoint launch arguments"};
    }

    record.provider = static_cast<AgentProvider>(u8::decode(input_));
    record.session = text16();
    if (!record.session.empty()) {
      validateAgentSession(record.session, false);
    }

    if (version_ >= titled_version) {
      record.title = text16();
      record.title_source = static_cast<AgentTitleSource>(u8::decode(input_));
    }

    validateTitle(record.title, record.title_source);

    record.in_pane = version_ >= in_pane_version && boolean();
    if (version_ == dropped_pane_version && boolean()) {
      return ds::none;
    }

    if (version_ >= kinds_version) {
      const auto kind = u8::decode(input_);

      // A pane of a kind this runtime does not run is passed over; the rest of the session is
      // restored without it.
      const bool known = kind == std::to_underlying(PaneKind::terminal) || kind == std::to_underlying(PaneKind::nvim) || kind == std::to_underlying(PaneKind::explorer);

      // Read whatever the kind: the record after this one starts past them.
      if (version_ >= explorer_version) {
        record.explorer = bytes32();
        if (record.explorer.size() > maximum_explorer_bytes) {
          throw EncodingError{"Invalid checkpoint explorer size"};
        }
      }

      if (version_ >= final_message_version) {
        record.final_message = text16();
        MessageText16<agent_report_message_bytes>::validate(record.final_message);
      }

      if (!known) {
        return ds::none;
      }

      record.kind = static_cast<PaneKind>(kind);
    }

    if (record.argument_count == 0) {
      throw EncodingError{"Checkpoint launch has no arguments"};
    }

    if (++pane_count_ > maximum_panes) {
      throw EncodingError{"Checkpoint has too many panes"};
    }

    return record;
  }

  WorktreeRecord Reader::worktree() {
    WorktreeRecord record{};

    record.id = u64::decode(input_);
    auto& registration = record.registration;

    registration.request_id = 1;
    registration.source = u64::decode(input_);
    record.workspace = u64::decode(input_);
    const auto created_by = u64::decode(input_);
    if (created_by != 0) {
      registration.created_by = created_by;
    }

    registration.origin = static_cast<WorktreeOrigin>(u8::decode(input_));
    registration.path = text16();
    registration.branch = text16();
    registration.base = text16();
    registration.title = text16();
    registration.brief = text16();
    if (version_ >= dispatched_version) {
      registration.dispatched_from = text16();
    }

    if (version_ >= coordinator_version && boolean()) {
      CoordinatorReference coordinator;
      const auto session = text(coordinator.session_id.size());

      std::ranges::copy(session, coordinator.session_id.viewMut().begin());
      coordinator.pane_id = u64::decode(input_);
      coordinator.pane_generation = u64::decode(input_);
      registration.coordinator = coordinator;
    }

    return record;
  }

  Writer::Writer(tbc::val_a<std::span<Byte>> buffer, Counters counters)
      : buffer_(buffer),
        remaining_(buffer.empty() ? buffer : buffer.first(buffer.size() - 1)) {
    constexpr std::size_t header_bytes = magic.size() + sizeof(current_version) + (4 * sizeof(std::uint64_t));
    if (buffer.size() <= header_bytes) {
      throw EncodingError{"Checkpoint buffer cannot hold its header"};
    }

    raw(magic);
    integer(current_version);
    integer(counters.workspace);
    integer(counters.tab);
    integer(counters.pane);
    integer(counters.generation);
  }

  template <typename Record>
  void Writer::append(const Record& record) {
    if (dropped_ != 0) {
      ++dropped_;
      return;
    }

    const auto previous = remaining_;

    try {
      write(record);
    } catch (const CapacityReached&) {
      remaining_ = previous;
      dropped_ = 1;
    } catch (const EncodingError&) {
      // A record that cannot be written, such as a path holding a NUL, is left out alone: the
      // reader skips what refers to it, and the checkpoint keeps the rest.
      remaining_ = previous;
      ++invalid_;
    }
  }

  std::size_t Writer::dropped() const noexcept {
    return dropped_ + invalid_;
  }

  tbc::val_a<std::span<const Byte>> Writer::finish() {
    const auto count = buffer_.size() - remaining_.size() - 1;

    buffer_[count] = static_cast<Byte>(Kind::end);
    return buffer_.first(count + 1);
  }

  void Writer::require(std::size_t count) {
    if (count > remaining_.size()) {
      throw CapacityReached{};
    }
  }

  template <std::unsigned_integral Integer>
  void Writer::integer(Integer value) {
    require(sizeof(value));
    LittleEndian<Integer>::encode(value, remaining_);
  }

  void Writer::raw(std::string_view value) {
    require(value.size());
    std::ranges::copy(value, remaining_.begin());
    remaining_ = remaining_.subspan(value.size());
  }

  void Writer::text16(std::string_view value) {
    if (value.size() > std::numeric_limits<std::uint16_t>::max()) {
      throw EncodingError{"Checkpoint text exceeds its length field"};
    }

    integer(static_cast<std::uint16_t>(value.size()));
    raw(value);
  }

  void Writer::text32(std::string_view value) {
    if (value.size() > maximum_bytes) {
      throw EncodingError{"Checkpoint data exceeds file limit"};
    }

    integer(static_cast<std::uint32_t>(value.size()));
    raw(value);
  }

  void Writer::kind(Kind value) {
    integer(static_cast<Byte>(value));
  }

  void Writer::write(const WorkspaceRecord& record) {
    validatePath(record.path);
    if (record.name.size() > maximum_name_bytes || record.first_label.size() > maximum_label_bytes) {
      throw EncodingError{"Invalid checkpoint workspace label"};
    }

    kind(Kind::workspace);
    integer(record.id);
    text16(record.path);
    text16(record.name);
    integer(record.first_tab);
    text16(record.first_label);
  }

  void Writer::write(const TabRecord& record) {
    kind(Kind::tab);
    integer(record.workspace);
    integer(record.id);
    text16(record.label);
  }

  void Writer::write(const PaneRecord& record) {
    validatePath(record.cwd);
    validateTitle(record.title, record.title_source);
    MessageText16<agent_report_message_bytes>::validate(record.final_message);
    if (record.argument_count == 0 || record.argument_count > maximum_arguments || record.arguments.size() > maximum_argument_bytes || record.session.size() > maximum_session_bytes || record.explorer.size() > maximum_explorer_bytes) {
      throw EncodingError{"Invalid checkpoint launch record"};
    }

    kind(Kind::pane);
    integer(record.id);
    integer(record.workspace);
    integer(record.tab);
    text16(record.cwd);
    integer(record.columns);
    integer(record.rows);
    integer(record.argument_count);
    text32(record.arguments);
    integer(static_cast<Byte>(record.provider));
    text16(record.session);
    text16(record.title);
    integer(static_cast<Byte>(record.title_source));
    integer(static_cast<Byte>(record.in_pane));
    integer(static_cast<Byte>(record.kind));
    text32(textView(record.explorer));
    text16(record.final_message);
  }

  void Writer::write(const WorktreeRecord& record) {
    const auto& registration = record.registration;
    auto checked = registration;

    checked.request_id = 1;
    Codec::encodedSize(checked);
    if (record.id == 0) {
      throw EncodingError{"Invalid checkpoint worktree identity"};
    }

    kind(Kind::worktree);
    integer(record.id);
    integer(registration.source);
    integer(record.workspace);
    integer(registration.created_by.valueOr(0));
    integer(static_cast<Byte>(registration.origin));
    text16(registration.path);
    text16(registration.branch);
    text16(registration.base);
    text16(registration.title);
    text16(registration.brief);
    text16(registration.dispatched_from);
    integer(static_cast<Byte>(registration.coordinator.hasValue()));
    if (registration.coordinator) {
      const auto& coordinator = *registration.coordinator;

      raw(textView(coordinator.session_id.view()));
      integer(coordinator.pane_id);
      integer(coordinator.pane_generation);
    }
  }

  void Writer::write(const BlocksRecord& record) {
    if (record.blocks.size() > PaneBlocks::capacity) {
      throw EncodingError{"Invalid checkpoint block count"};
    }

    kind(Kind::blocks);
    integer(record.pane);
    integer(static_cast<std::uint16_t>(record.blocks.size()));
    for (const auto& block : record.blocks) {
      integer(static_cast<Byte>(block.state));
      integer(static_cast<std::uint32_t>(block.status));
      integer(block.duration_ms);
      integer(static_cast<std::uint64_t>(block.started_ms));
      integer(block.lines);
      integer(static_cast<Byte>(block.nest));
      text16(block.command);
      text16(block.directory);
      text16(block.host);
      text16(block.user);
      text16(block.branch);
    }
  }

  void Writer::write(const PlacesRecord& record) {
    if (record.payload.empty() || record.payload.size() > maximum_places_bytes) {
      throw EncodingError{"Invalid checkpoint places size"};
    }

    kind(Kind::places);
    text32(textView(record.payload));
  }

  void Writer::write(const LayoutRecord& record) {
    if (record.payload.empty() || record.payload.size() > maximum_layout_bytes) {
      throw EncodingError{"Invalid checkpoint layout size"};
    }

    kind(Kind::layout);
    integer(record.identity);
    integer(record.last_used);
    text32(textView(record.payload));
  }

  template void Writer::append<WorkspaceRecord>(const WorkspaceRecord& record);
  template void Writer::append<TabRecord>(const TabRecord& record);
  template void Writer::append<PaneRecord>(const PaneRecord& record);
  template void Writer::append<WorktreeRecord>(const WorktreeRecord& record);
  template void Writer::append<LayoutRecord>(const LayoutRecord& record);
  template void Writer::append<PlacesRecord>(const PlacesRecord& record);
  template void Writer::append<BlocksRecord>(const BlocksRecord& record);

}
