const std = @import("std");
const core = @import("telar-core");
const Peer = @import("AgentRuntimePeer.zig");
const serve = @import("telar-backend").serve;

const provider =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\ case "$line" in
    \\ *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    \\ *'"method":"model/list"'*) printf '%s\n' '{"id":0,"result":{"data":[{"id":"fake-model","model":"fake-model","displayName":"Fake model","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low","isDefault":true}],"nextCursor":null}}' ;;
    \\ *'"method":"thread/start"'*) printf '%s' "$$" > provider.pid; printf '%s\n' '{"id":2,"result":{"thread":{"id":"integration-thread","name":"Initial provider session"},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' ;;
    \\ *'"method":"turn/start"'*) printf '%s\n' '{"method":"thread/name/updated","params":{"threadId":"integration-thread","threadName":"Updated provider session"}}' '{"method":"thread/name/updated","params":{"threadId":"different-thread","threadName":"Wrong session"}}' '{"id":3,"result":{"turn":{"id":"turn-1"}}}' '{"method":"item/agentMessage/delta","params":{"threadId":"integration-thread","itemId":"a","delta":"Retained across clients"}}' '{"method":"turn/completed","params":{"threadId":"integration-thread","turn":{"id":"turn-1","status":"completed"}}}' ;;
    \\ *'"method":"thread/read"'*) rid=${line#*'"id":'}; rid=${rid%%,*}; printf '{"id":%s,"result":{"thread":{"id":"integration-thread","historyMode":"paginated"}}}\n' "$rid" ;;
    \\ *'"method":"thread/items/list"'*)
    \\   rid=${line#*'"id":'}; rid=${rid%%,*}
    \\   index=100; step=-1
    \\   case "$line" in *'"sortDirection":"asc"'*) step=1; index=1 ;; esac
    \\   case "$line" in
    \\     *'"cursor":"position-'*) position=${line#*'"cursor":"position-'}; index=${position%%\"*} ;;
    \\   esac
    \\   if [ "$index" -lt 1 ] || [ "$index" -gt 100 ]; then
    \\     printf '{"id":%s,"result":{"data":[],"nextCursor":null,"backwardsCursor":null}}\n' "$rid"
    \\     continue
    \\   fi
    \\   next=$((index+step)); next_cursor=null
    \\   if [ "$next" -ge 1 ] && [ "$next" -le 100 ]; then next_cursor='"position-'$next'"'; fi
    \\   source="history-$index"; turn=turn-1; content="Historical message $index"
    \\   if [ "$index" -eq 99 ]; then source=a; turn=turn-2; fi
    \\   if [ "$index" -eq 100 ]; then source=a; content='Retained across clients'; fi
    \\   printf '{"id":%s,"result":{"data":[{"turnId":"%s","item":{"type":"agentMessage","id":"%s","text":"%s","phase":"final_answer"}}],"nextCursor":%s,"backwardsCursor":"position-%s"}}\n' "$rid" "$turn" "$source" "$content" "$next_cursor" "$index"
    \\   ;;
    \\ esac
    \\done
;

test "runtime agent pane IPC retains its conversation across clients and reaps its piped provider" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_storage[0..try temp.dir.realPath(io, &directory_storage)];
    const script = try temp.dir.createFile(io, "codex", .{ .permissions = .fromMode(0o700) });
    try script.writeStreamingAll(io, provider);
    script.close(io);
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("PATH", directory);
    try environment.put("HOME", directory);
    const inherited: std.process.Environ = .{ .block = try environment.createPosixBlock(gpa, .{}) };
    defer inherited.block.deinit(gpa);
    var socket_storage: [std.fs.max_path_bytes]u8 = undefined;
    const socket = try std.fmt.bufPrint(&socket_storage, "{s}/agent.sock", .{directory});
    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var server = try io.concurrent(serve, .{ io, gpa, .{ .endpoint = socket, .environment = inherited, .stop = &stop } });
    defer {
        stop.putOneUncancelable(io, 0) catch {};
        _ = server.await(io) catch {};
    }
    var first = try Peer.init(io, socket);
    defer first.deinit();
    try first.send(try core.encodeOpenPane(&first.send_buffer, .{
        .request_id = @enumFromInt(1),
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{ "/bin/sleep", "600" } },
    }));
    const initial = while (true) {
        switch (try first.receive()) {
            .pane_opened => |opened| break opened,
            else => {},
        }
    };
    try first.send(try core.encodeRequestRuntimeState(&first.send_buffer, .{ .client_identity = @enumFromInt(1) }));
    try first.send(try core.encodeCreateTab(&first.send_buffer, .{
        .request_id = @enumFromInt(2),
        .workspace = initial.location.workspace,
        .label = "Codex",
        .kind = .agent,
        .size = .{ .cols = 40, .rows = 8 },
        .launch = .{ .cwd = directory, .arguments = &.{} },
    }));
    const created = while (true) {
        switch (try first.receive()) {
            .tab_created => |tab| break tab,
            else => {},
        }
    };
    try std.testing.expectEqual(core.PaneKind.agent, created.kind);
    try std.testing.expect(created.pane_generation != 0);
    var ready = false;
    var options: core.AgentOptions = .{};
    var sidebar = false;
    while (!ready or !sidebar) {
        switch (try first.receive()) {
            .agent_thread_snapshot => |snapshot| {
                var owned: core.AgentThreadSnapshot = undefined;
                try snapshot.copyTo(&owned);
                if (owned.status == .ready) {
                    options = owned.options;
                }
                ready = ready or (snapshot.pane_id == created.root_pane_id and owned.status == .ready);
            },
            .agent_snapshot => |snapshot| {
                var entries = snapshot.entries();
                while (try entries.next()) |entry| {
                    if (entry.pane_id == created.root_pane_id and entry.provider == .codex) {
                        sidebar = std.mem.eql(u8, entry.session_title, "Initial provider session");
                    }
                }
            },
            else => {},
        }
    }
    var second = try Peer.init(io, socket);
    defer second.deinit();
    try second.send(try core.encodeQueryAgentThread(&second.send_buffer, .{
        .request_id = @enumFromInt(3),
        .pane_id = created.root_pane_id,
        .pane_generation = created.pane_generation,
    }));
    while (true) {
        if (try second.receive() == .agent_thread_snapshot) {
            break;
        }
    }
    first.deinit();
    try second.send(try core.encodeAgentPrompt(&second.send_buffer, .{
        .request_id = @enumFromInt(4),
        .pane_id = created.root_pane_id,
        .pane_generation = created.pane_generation,
        .text = "hello",
        .options = options,
    }));
    while (true) {
        switch (try second.receive()) {
            .request_completed => |reply| if (core.raw(reply.request_id) == 4) {
                break;
            },
            else => {},
        }
    }
    // Disconnect immediately after prompt admission. Provider progress must continue.
    second.deinit();
    var recovered = try Peer.init(io, socket);
    defer recovered.deinit();
    try recovered.send(try core.encodeOpenPane(&recovered.send_buffer, .{
        .request_id = @enumFromInt(5),
        .launch = null,
        .target = .{ .pane = created.root_pane_id },
        .size = .{ .cols = 40, .rows = 8 },
    }));
    while (true) {
        switch (try recovered.receive()) {
            .pane_opened => |opened| {
                try std.testing.expectEqual(core.PaneKind.agent, opened.kind);
                try std.testing.expectEqual(created.pane_generation, opened.pane_generation);
                break;
            },
            else => {},
        }
    }
    try recovered.send(try core.encodeRequestRuntimeState(&recovered.send_buffer, .{ .client_identity = @enumFromInt(2) }));
    var conversation: core.AgentThreadSnapshot = undefined;
    var conversation_ready = false;
    var title_ready = false;
    while (!conversation_ready or !title_ready) {
        switch (try recovered.receive()) {
            .agent_thread_snapshot => |snapshot| {
                try snapshot.copyTo(&conversation);
                conversation_ready = conversation.status == .ready and conversation.item_count >= 2;
            },
            .agent_snapshot => |snapshot| {
                var entries = snapshot.entries();
                while (try entries.next()) |entry| {
                    if (entry.pane_id == created.root_pane_id) {
                        title_ready = std.mem.eql(u8, entry.session_title, "Updated provider session");
                    }
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqualStrings("hello", conversation.items()[0].text(&conversation));
    try std.testing.expectEqualStrings("Retained across clients", conversation.items()[1].text(&conversation));
    const pid_text = try temp.dir.readFileAlloc(io, "provider.pid", gpa, .limited(64));
    defer gpa.free(pid_text);
    const process_id = try std.fmt.parseInt(std.c.pid_t, pid_text, 10);
    try std.testing.expect(process_id > 0);
    try verifyHistoryClients(.{ .io = io, .socket = socket, .pane_id = created.root_pane_id, .pane_generation = created.pane_generation });
    // Historical navigation must never replace the runtime's live conversation.
    try recovered.send(try core.encodeQueryAgentThread(&recovered.send_buffer, .{ .request_id = @enumFromInt(20), .pane_id = created.root_pane_id, .pane_generation = created.pane_generation }));
    while (true) {
        switch (try recovered.receive()) {
            .agent_thread_snapshot => |snapshot| {
                try snapshot.copyTo(&conversation);
                try std.testing.expectEqual(@as(u8, 2), conversation.item_count);
                try std.testing.expectEqualStrings("Retained across clients", conversation.items()[1].text(&conversation));
                break;
            },
            else => {},
        }
    }
    try recovered.send(try core.encodeClosePane(&recovered.send_buffer, .{ .request_id = @enumFromInt(6), .pane_id = created.root_pane_id }));
    while (true) {
        switch (try recovered.receive()) {
            .pane_exited => |exited| if (exited.pane_id == created.root_pane_id) {
                break;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(c_int, -1), std.c.kill(process_id, @enumFromInt(0)));
}

fn verifyHistoryClients(context: struct { io: std.Io, socket: []const u8, pane_id: core.PaneId, pane_generation: u64 }) !void {
    var older = try Peer.init(context.io, context.socket);
    defer older.deinit();
    var latest = try Peer.init(context.io, context.socket);
    defer latest.deinit();
    for ([_]*Peer{ &older, &latest }, 0..) |peer, index| {
        try peer.send(try core.encodeOpenPane(&peer.send_buffer, .{
            .request_id = @enumFromInt(index + 30),
            .launch = null,
            .target = .{ .pane = context.pane_id },
            .size = .{ .cols = 40, .rows = 8 },
        }));
        while (true) {
            if (try peer.receive() == .pane_opened) {
                break;
            }
        }
    }

    const first_query: core.QueryAgentHistory = .{ .request_id = @enumFromInt(10), .pane_id = context.pane_id, .pane_generation = context.pane_generation, .view_generation = 1 };
    var other_query = first_query;
    other_query.request_id = @enumFromInt(11);
    other_query.view_generation = 9;
    // Independent clients may read concurrently, with their own correlations.
    try older.send(try core.encodeQueryAgentHistory(&older.send_buffer, first_query));
    try latest.send(try core.encodeQueryAgentHistory(&latest.send_buffer, other_query));
    const first = try receiveHistory(&older, first_query);
    const other = try receiveHistory(&latest, other_query);
    try std.testing.expectEqual(@as(u8, 64), first.snapshot.item_count);
    try std.testing.expectEqualStrings("Historical message 37", first.snapshot.items()[0].text(&first.snapshot));
    try std.testing.expectEqualStrings("Retained across clients", first.snapshot.items()[63].text(&first.snapshot));
    try std.testing.expectEqualStrings(first.before.slice(), other.before.slice());
    try std.testing.expectEqualStrings("a", first.snapshot.items()[62].sourceId(&first.snapshot));
    try std.testing.expectEqualStrings("a", first.snapshot.items()[63].sourceId(&first.snapshot));
    try std.testing.expectEqualStrings("turn-2", first.snapshot.items()[62].sourceTurn(&first.snapshot));
    try std.testing.expectEqualStrings("turn-1", first.snapshot.items()[63].sourceTurn(&first.snapshot));
    try std.testing.expect(first.snapshot.items()[62].identity != first.snapshot.items()[63].identity);
    try std.testing.expect(first.has_before);
    try std.testing.expect(!first.has_after);
    var before_query = first_query;
    before_query.request_id = @enumFromInt(12);
    before_query.cursor = first.before.slice();
    try older.send(try core.encodeQueryAgentHistory(&older.send_buffer, before_query));
    const before = try receiveHistory(&older, before_query);
    try std.testing.expectEqual(@as(u8, 36), before.snapshot.item_count);
    try std.testing.expectEqualStrings("Historical message 1", before.snapshot.items()[0].text(&before.snapshot));
    try std.testing.expectEqualStrings("Historical message 36", before.snapshot.items()[35].text(&before.snapshot));
    try std.testing.expect(!before.has_before);
    try std.testing.expect(before.has_after);
    var after_query = first_query;
    after_query.request_id = @enumFromInt(13);
    after_query.direction = .newer;
    after_query.cursor = before.after.slice();
    try older.send(try core.encodeQueryAgentHistory(&older.send_buffer, after_query));
    const after = try receiveHistory(&older, after_query);
    try std.testing.expectEqualStrings("Historical message 37", after.snapshot.items()[0].text(&after.snapshot));
    try std.testing.expectEqualStrings("Retained across clients", after.snapshot.items()[63].text(&after.snapshot));
    // The live seam excludes its anchor, so no message repeats at that boundary.
    var anchored = first_query;
    anchored.request_id = @enumFromInt(14);
    anchored.anchor = "a";
    anchored.anchor_turn = "turn-1";
    try latest.send(try core.encodeQueryAgentHistory(&latest.send_buffer, anchored));
    const anchored_page = try receiveHistory(&latest, anchored);
    try std.testing.expectEqualStrings("Historical message 99", anchored_page.snapshot.items()[63].text(&anchored_page.snapshot));
    anchored.request_id = @enumFromInt(15);
    anchored.anchor_turn = "turn-2";
    try latest.send(try core.encodeQueryAgentHistory(&latest.send_buffer, anchored));
    const previous_turn = try receiveHistory(&latest, anchored);
    try std.testing.expectEqualStrings("Historical message 98", previous_turn.snapshot.items()[63].text(&previous_turn.snapshot));
}

fn receiveHistory(peer: *Peer, query: core.QueryAgentHistory) !core.AgentHistoryPage {
    while (true) {
        switch (try peer.receive()) {
            .agent_history_page => |view| {
                try std.testing.expectEqual(query.request_id, view.request_id);
                try std.testing.expectEqual(query.view_generation, view.view_generation);
                try std.testing.expectEqual(query.pane_id, view.snapshot.pane_id);
                try std.testing.expectEqual(query.pane_generation, view.snapshot.pane_generation);
                var owned: core.AgentHistoryPage = undefined;
                try view.copyTo(&owned);
                return owned;
            },
            else => {},
        }
    }
}
