const std = @import("std");
const core = @import("telar-core");
const Position = @import("HistoryPosition.zig");
const ItemNormalizer = @import("ItemNormalizer.zig");
const history_page = @import("history_page.zig");
const Fixture = @import("HistoryFixture.zig");

const query: core.QueryAgentHistory = .{ .request_id = @enumFromInt(1), .pane_id = @enumFromInt(1), .pane_generation = 1, .view_generation = 1 };
const setup =
    \\while IFS= read -r line; do
    \\ id=${line#*'"id":'}; id=${id%%,*}
    \\ case "$line" in
    \\  *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\  *'"method":"thread/read"'*) printf '{"id":%s,"result":{"thread":{"id":"thread-1","historyMode":"paginated"}}}\n' "$id" ;;
    \\  *'"method":"thread/items/list"'*)
;
const finish = "\n;;\nesac\ndone\n";
const hundred = setup ++
    \\ older=1; case "$line" in *'"sortDirection":"asc"'*) older=0;; esac
    \\ if [ "$older" = 1 ]; then n=100; else n=1; fi
    \\ case "$line" in *'"cursor":"position-'*) n=${line#*'"cursor":"position-'}; n=${n%%\"*};; esac
    \\ next=null
    \\ if [ "$older" = 1 ] && [ "$n" -gt 1 ]; then next="\"position-$((n - 1))\""; fi
    \\ if [ "$older" = 0 ] && [ "$n" -lt 100 ]; then next="\"position-$((n + 1))\""; fi
    \\ printf '{"id":%s,"result":{"data":[{"turnId":"turn-1","item":{"id":"item-%s","type":"agentMessage","text":"message %s","phase":"final_answer"}}],"nextCursor":%s,"backwardsCursor":"position-%s"}}\n' "$id" "$n" "$n" "$next" "$n"
++ finish;

test "history reader pages backward and forward without losing or duplicating inclusive anchors" {
    var fixture = try Fixture.init(hundred);
    defer fixture.deinit();
    const tail = try fixture.read(query);
    defer std.testing.allocator.destroy(tail);
    try std.testing.expectEqual(@as(u8, 64), tail.snapshot.item_count);
    try std.testing.expectEqualStrings("item-37", tail.snapshot.items()[0].sourceId(&tail.snapshot));
    try std.testing.expectEqualStrings("item-100", tail.snapshot.items()[63].sourceId(&tail.snapshot));
    try std.testing.expect(tail.has_before);
    try std.testing.expect(!tail.has_after);
    var previous_query = query;
    previous_query.cursor = tail.before.slice();
    const previous = try fixture.read(previous_query);
    defer std.testing.allocator.destroy(previous);
    try std.testing.expectEqual(@as(u8, 36), previous.snapshot.item_count);
    try std.testing.expectEqualStrings("item-1", previous.snapshot.items()[0].sourceId(&previous.snapshot));
    try std.testing.expectEqualStrings("item-36", previous.snapshot.items()[35].sourceId(&previous.snapshot));
    try std.testing.expect(!previous.has_before);
    try std.testing.expect(previous.has_after);
    var next_query = query;
    next_query.cursor = previous.after.slice();
    next_query.direction = .newer;
    const next = try fixture.read(next_query);
    defer std.testing.allocator.destroy(next);
    try std.testing.expectEqual(@as(u8, 64), next.snapshot.item_count);
    try std.testing.expectEqualStrings("item-37", next.snapshot.items()[0].sourceId(&next.snapshot));
    try std.testing.expectEqualStrings("item-100", next.snapshot.items()[63].sourceId(&next.snapshot));
    try std.testing.expectEqual(tail.snapshot.items()[0].identity, next.snapshot.items()[0].identity);
    try fixture.expectReaped();
}

test "history pages containing tool output survive wire validation" {
    const script = setup ++
        \\ n=24
        \\ case "$line" in *'"cursor":"position-'*) n=${line#*'"cursor":"position-'}; n=${n%%\"*};; esac
        \\ text=$(awk 'BEGIN { for (i=0; i<12000; i++) printf "x" }')
        \\ printf '{"id":%s,"result":{"data":[{"turnId":"turn-1","item":{"id":"command-%s","type":"commandExecution","command":"check-part","cwd":"/tmp","status":"completed","exitCode":0,"aggregatedOutput":"%s"}}],"nextCursor":"position-%s","backwardsCursor":"position-%s"}}\n' "$id" "$n" "$text" "$((n - 1))" "$n"
    ++ finish;
    var fixture = try Fixture.init(script);
    defer fixture.deinit();
    const page = try fixture.read(query);
    defer std.testing.allocator.destroy(page);
    try std.testing.expect(page.snapshot.item_count > 1);
    const wire = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(wire);
    const decoded = (try core.decodeServer(try core.encodeAgentHistoryPage(wire, page))).agent_history_page;
    try decoded.snapshot.copyTo(&page.snapshot);
    for (page.snapshot.items()) |item| {
        try std.testing.expectEqualStrings("check-part\n/tmp", item.detail(&page.snapshot));
    }
}

test "history initial live anchor is excluded and unavailable anchor fails explicitly" {
    var fixture = try Fixture.init(hundred);
    defer fixture.deinit();
    var anchored = query;
    anchored.anchor = "item-50";
    anchored.anchor_turn = "turn-1";
    const page = try fixture.read(anchored);
    defer std.testing.allocator.destroy(page);
    try std.testing.expectEqual(@as(u8, 49), page.snapshot.item_count);
    try std.testing.expectEqualStrings("item-49", page.snapshot.items()[48].sourceId(&page.snapshot));
    anchored.anchor = "missing";
    try std.testing.expectError(error.HistoryAnchorUnavailable, fixture.read(anchored));
    try fixture.expectReaped();
}

test "history repeated item IDs in distinct turns survive pages anchors and direction changes" {
    const script = try std.mem.replaceOwned(u8, std.testing.allocator, hundred, "\"turnId\":\"turn-1\",\"item\":{\"id\":\"item-%s\"", "\"turnId\":\"turn-%s\",\"item\":{\"id\":\"shared\"");
    defer std.testing.allocator.free(script);
    var fixture = try Fixture.init(script);
    defer fixture.deinit();
    const tail = try fixture.read(query);
    defer std.testing.allocator.destroy(tail);
    try std.testing.expectEqual(@as(u8, 64), tail.snapshot.item_count);
    try std.testing.expectEqualStrings("shared", tail.snapshot.items()[0].sourceId(&tail.snapshot));
    try std.testing.expectEqualStrings("turn-37", tail.snapshot.items()[0].sourceTurn(&tail.snapshot));
    try std.testing.expectEqualStrings("turn-100", tail.snapshot.items()[63].sourceTurn(&tail.snapshot));
    try std.testing.expect(tail.snapshot.items()[0].identity != tail.snapshot.items()[1].identity);
    var navigation = query;
    navigation.cursor = tail.before.slice();
    const older = try fixture.read(navigation);
    defer std.testing.allocator.destroy(older);
    try std.testing.expectEqual(@as(u8, 36), older.snapshot.item_count);
    try std.testing.expectEqualStrings("turn-1", older.snapshot.items()[0].sourceTurn(&older.snapshot));
    try std.testing.expectEqualStrings("turn-36", older.snapshot.items()[35].sourceTurn(&older.snapshot));
    navigation.cursor = older.after.slice();
    navigation.direction = .newer;
    const forward = try fixture.read(navigation);
    defer std.testing.allocator.destroy(forward);
    try std.testing.expectEqual(tail.snapshot.items()[0].identity, forward.snapshot.items()[0].identity);
    navigation = query;
    navigation.anchor = "shared";
    navigation.anchor_turn = "turn-50";
    const anchored = try fixture.read(navigation);
    defer std.testing.allocator.destroy(anchored);
    try std.testing.expectEqual(@as(u8, 49), anchored.snapshot.item_count);
    try std.testing.expectEqualStrings("turn-49", anchored.snapshot.items()[48].sourceTurn(&anchored.snapshot));
    var incorrect = try Position.decode(tail.before.slice(), "thread-1");
    try incorrect.setSource("shared", "turn-other");
    const cursor = try incorrect.encode("thread-1");
    navigation = query;
    navigation.cursor = cursor.slice();
    try std.testing.expectError(error.HistoryAnchorUnavailable, fixture.read(navigation));
}

test "historical identity includes unambiguous turn and item boundaries" {
    var snapshot: core.AgentThreadSnapshot = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 };
    try std.testing.expect(try history_page.append(&snapshot, .{ .id = "c", .source_turn = "ab", .role = .assistant, .text = "first" }, .{ 0, 5 }));
    try std.testing.expect(try history_page.append(&snapshot, .{ .id = "bc", .source_turn = "a", .role = .assistant, .text = "second" }, .{ 0, 6 }));
    try std.testing.expect(snapshot.items()[0].identity != snapshot.items()[1].identity);
    try std.testing.expectEqualStrings("ab", snapshot.items()[0].sourceTurn(&snapshot));
    try std.testing.expectEqualStrings("a", snapshot.items()[1].sourceTurn(&snapshot));
}

test "history long UTF8 item has lossless exclusive fragments in both directions" {
    var fixture = try Fixture.init(setup ++
        \\ text=ñ; i=0; while [ "$i" -lt 16 ]; do text=$text$text; i=$((i + 1)); done
        \\ printf '{"id":%s,"result":{"data":[{"turnId":"turn-1","item":{"id":"long","type":"agentMessage","text":"%s"}}],"nextCursor":null,"backwardsCursor":"long-anchor"}}\n' "$id" "$text"
    ++ finish);
    defer fixture.deinit();
    const tail = try fixture.read(query);
    defer std.testing.allocator.destroy(tail);
    const tail_item = tail.snapshot.items()[0];
    try std.testing.expectEqual(@as(u32, 131072 - 49152), tail_item.fragment_offset);
    try std.testing.expect(tail.has_before);
    try std.testing.expect(!tail.has_after);
    try std.testing.expect(!tail_item.fragment_start);
    try std.testing.expect(tail_item.fragment_end);
    var previous_query = query;
    previous_query.cursor = tail.before.slice();
    const middle = try fixture.read(previous_query);
    defer std.testing.allocator.destroy(middle);
    const middle_item = middle.snapshot.items()[0];
    try std.testing.expectEqual(tail_item.fragment_offset, middle_item.fragment_offset + middle_item.text_len);
    try std.testing.expect(!middle_item.fragment_start);
    try std.testing.expect(!middle_item.fragment_end);
    previous_query.cursor = middle.before.slice();
    const first = try fixture.read(previous_query);
    defer std.testing.allocator.destroy(first);
    const first_item = first.snapshot.items()[0];
    try std.testing.expectEqual(@as(u32, 0), first_item.fragment_offset);
    try std.testing.expect(first_item.fragment_start);
    try std.testing.expect(!first.has_before);
    try std.testing.expectEqual(@as(u32, 131072), first_item.text_len + middle_item.text_len + tail_item.text_len);
    var next_query = query;
    next_query.direction = .newer;
    next_query.cursor = first.after.slice();
    const forward = try fixture.read(next_query);
    defer std.testing.allocator.destroy(forward);
    try std.testing.expectEqual(middle_item.fragment_offset, forward.snapshot.items()[0].fragment_offset);
    try std.testing.expectEqual(middle_item.text_len, forward.snapshot.items()[0].text_len);
    try std.testing.expectEqual(middle_item.identity, forward.snapshot.items()[0].identity);
    var wire: [96 * 1024]u8 = undefined;
    _ = try core.encodeAgentHistoryPage(&wire, forward);
    try fixture.expectReaped();
}

test "history empty item boundaries do not repeat zero-byte activities" {
    var fixture = try Fixture.init(setup ++
        \\ printf '{"id":%s,"result":{"data":[{"turnId":"turn-1","item":{"id":"compact","type":"contextCompaction"}}],"nextCursor":null,"backwardsCursor":"anchor"}}\n' "$id"
    ++ finish);
    defer fixture.deinit();
    const initial = try fixture.read(query);
    defer std.testing.allocator.destroy(initial);
    try std.testing.expectEqual(@as(u8, 1), initial.snapshot.item_count);
    var before = query;
    before.cursor = initial.before.slice();
    const older = try fixture.read(before);
    defer std.testing.allocator.destroy(older);
    try std.testing.expectEqual(@as(u8, 0), older.snapshot.item_count);
    var after = query;
    after.direction = .newer;
    after.cursor = initial.after.slice();
    const newer = try fixture.read(after);
    defer std.testing.allocator.destroy(newer);
    try std.testing.expectEqual(@as(u8, 0), newer.snapshot.item_count);
}

test "historical subagent status and unrecognized item stay visible" {
    var fixture = try Fixture.init(setup ++
        \\ case "$line" in
        \\ *'"cursor":null'*) printf '{"id":%s,"result":{"data":[{"turnId":"turn-1","item":{"id":"child-status","type":"subAgentActivity","agentPath":"/root/review","agentThreadId":"child-1","kind":"completed"}}],"nextCursor":"next","backwardsCursor":"child-anchor"}}\n' "$id" ;;
        \\ *) printf '{"id":%s,"result":{"data":[{"turnId":"turn-1","item":{"id":"unknown","type":"newActivity","publicResult":"Retained text"}}],"nextCursor":null,"backwardsCursor":"unknown-anchor"}}\n' "$id" ;;
        \\ esac
    ++ finish);
    defer fixture.deinit();
    const page = try fixture.read(query);
    defer std.testing.allocator.destroy(page);
    try std.testing.expectEqual(@as(u8, 2), page.snapshot.item_count);
    try std.testing.expect(std.mem.indexOf(u8, page.snapshot.items()[0].text(&page.snapshot), "Retained text") != null);
    const child = page.snapshot.items()[1];
    try std.testing.expectEqual(.subagent, child.kind);
    try std.testing.expectEqual(.idle, child.status);
    try std.testing.expectEqualStrings("child-1", child.reference(&page.snapshot));
}

test "history reader rejects malformed legacy and oversized output without leaving a subprocess" {
    var legacy = try Fixture.init(
        \\while IFS= read -r line; do
        \\ id=${line#*'"id":'}; id=${id%%,*}
        \\ case "$line" in
        \\ *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
        \\ *'"method":"thread/read"'*) printf '{"id":%s,"result":{"thread":{"id":"thread-1","historyMode":"legacy"}}}\n' "$id" ;;
        \\ esac
        \\done
    );
    defer legacy.deinit();
    try std.testing.expectError(error.InvalidHistoryResponse, legacy.read(query));
    try legacy.expectReaped();
    var overflow = try Fixture.init("block=xxxxxxxxxxxxxxxx\nwhile [ ${#block} -lt 65536 ]; do block=$block$block; done\nwhile :; do printf '%s' \"$block\"; done");
    defer overflow.deinit();
    try std.testing.expectError(error.HistoryResponseTooLarge, overflow.read(query));
    try overflow.expectReaped();
}

test "history deadline includes provider startup and reaps a published process" {
    var fixture = try Fixture.init("trap '' TERM\nwhile IFS= read -r line; do :; done");
    defer fixture.deinit();
    fixture.timeout_ms = 1000;
    try std.testing.expectError(error.HistoryTimeout, fixture.read(query));
    try fixture.expectReapedIfPublished();
}

test "history cancellation reaps a provider after confirmed startup" {
    var fixture = try Fixture.init("trap '' TERM\nwhile IFS= read -r line; do :; done");
    defer fixture.deinit();
    fixture.timeout_ms = std.math.maxInt(u32);
    var future = try std.testing.io.concurrent(Fixture.read, .{ &fixture, query });
    defer if (future.cancel(std.testing.io)) |page| {
        std.testing.allocator.destroy(page);
    } else |_| {};
    _ = try fixture.awaitPid();
    try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
    try fixture.expectReaped();
}

test "history cursor binds opaque provider anchor and exact fragment boundary to one thread" {
    var position: Position = .{ .provider = try core.AgentHistoryCursor.init("{\"ordinal\":900,\"includeAnchor\":true}"), .offset = 49152, .after = true };
    try position.setSource("message-1", "turn-1");
    const cursor = try position.encode("thread-1");
    const decoded = try Position.decode(cursor.slice(), "thread-1");
    try std.testing.expectEqualStrings(position.provider.slice(), decoded.provider.slice());
    try std.testing.expectEqualStrings("message-1", decoded.source[0..decoded.source_len]);
    try std.testing.expectEqualStrings("turn-1", decoded.turn[0..decoded.turn_len]);
    try std.testing.expectEqual(position.offset, decoded.offset);
    try std.testing.expect(decoded.after);
    try std.testing.expectError(error.InvalidHistoryCursor, Position.decode(cursor.slice(), "another-thread"));
}

test "historical formatted tool output exceeds live scratch without truncation" {
    const output = try std.testing.allocator.alloc(u8, 100_000);
    defer std.testing.allocator.free(output);
    @memset(output, 'x');
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(.{ .type = "commandExecution", .id = "command-1", .command = "printf example", .aggregatedOutput = output, .exitCode = 0 }, .{}, &encoded.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded.written(), .{});
    defer parsed.deinit();
    const scratch = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(scratch);
    var normalizer: ItemNormalizer = .{ .body_buffer = scratch };
    const update = normalizer.item(parsed.value, true).?;
    try std.testing.expect(!update.truncated);
    try std.testing.expect(update.text.len > output.len);
    try std.testing.expect(std.mem.endsWith(u8, update.text, "Exit code: 0\n"));
    var page: core.AgentThreadSnapshot = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 };
    try std.testing.expect(try history_page.append(&page, update, .{ 0, 48 * 1024 }));
    try std.testing.expectEqualStrings("command-1", page.items()[0].sourceId(&page));
    try std.testing.expect(page.items()[0].fragment_start);
    try std.testing.expect(!page.items()[0].fragment_end);
    const first_identity = page.items()[0].identity;
    page.item_count = 0;
    page.text_len = 0;
    page.metadata_len = 0;
    try std.testing.expect(try history_page.append(&page, update, .{ 48 * 1024, 96 * 1024 }));
    try std.testing.expect(page.items()[0].identity != first_identity);
    try std.testing.expectEqual(@as(u32, 48 * 1024), page.items()[0].fragment_offset);
    try std.testing.expect(!page.items()[0].fragment_start);
}

test "historical dispatch retains every announced child status and result" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"id":"dispatch-1","type":"collabAgentToolCall","tool":"wait","prompt":"Review parser","receiverThreadIds":["reviewer"],"agentsStates":{"reviewer":{"status":"completed","message":"Parser reviewed"},"tester":{"status":"errored","message":"Test failed"}},"model":"provider-model","reasoningEffort":"high"}
    , .{});
    defer parsed.deinit();
    var normalizer: ItemNormalizer = .{ .include_history_details = true };
    const update = normalizer.item(parsed.value, true).?;
    try std.testing.expectEqual(.dispatch, update.kind.?);
    try std.testing.expect(!update.truncated);
    inline for (.{ "Review parser", "reviewer: completed", "Parser reviewed", "tester: errored", "Test failed", "provider-model", "high" }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, update.text, text) != null);
    }
}
