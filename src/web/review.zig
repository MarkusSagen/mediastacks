//! Local web review surface for a reorganization Plan.
//!
//! Server-authoritative: the browser sends edit ops; `applyEdit` mutates
//! the in-memory Plan and recomputes destinations via the Zig template
//! engine (`core/naming`). The Plan stays the single contract. The HTTP
//! server (`serve`) is added in a later task.

const std = @import("std");
const plan = @import("../core/plan.zig");
const naming = @import("../core/naming.zig");
const config = @import("../core/config.zig");
const kind = @import("../core/kind.zig");

pub const Session = struct {
    arena: std.mem.Allocator,
    cfg: config.Config,
    plan: plan.Plan,
};

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn getInt(v: std.json.Value, key: []const u8) ?usize {
    const x = objGet(v, key) orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}
fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = objGet(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

fn recompute(s: *Session, g: usize, i: usize) !void {
    const grp = &s.plan.groups[g];
    var item = &grp.items[i];
    if (item.role == .primary or item.role == .sidecar) {
        if (item.fields) |f| item.dst = try naming.dstFor(s.arena, s.cfg, grp.kind, f);
    } else {
        item.dst = null;
    }
}

fn appendItem(a: std.mem.Allocator, items: []plan.Item, extra: plan.Item) ![]plan.Item {
    const out = try a.alloc(plan.Item, items.len + 1);
    @memcpy(out[0..items.len], items);
    out[items.len] = extra;
    return out;
}
fn removeItem(a: std.mem.Allocator, items: []plan.Item, idx: usize) ![]plan.Item {
    const out = try a.alloc(plan.Item, items.len - 1);
    @memcpy(out[0..idx], items[0..idx]);
    @memcpy(out[idx..], items[idx + 1 ..]);
    return out;
}

/// Apply one edit op (JSON) to `s.plan`, recomputing affected destinations.
/// Bad index → error.BadIndex; unknown/ill-formed op → error.BadOp.
pub fn applyEdit(s: *Session, op_json: []const u8) !void {
    const op = std.json.parseFromSliceLeaky(std.json.Value, s.arena, op_json, .{ .allocate = .alloc_always }) catch return error.BadOp;
    const op_name = getStr(op, "op") orelse return error.BadOp;

    if (std.mem.eql(u8, op_name, "set-role")) {
        const g = getInt(op, "group") orelse return error.BadOp;
        const i = getInt(op, "item") orelse return error.BadOp;
        if (g >= s.plan.groups.len) return error.BadIndex;
        if (i >= s.plan.groups[g].items.len) return error.BadIndex;
        const role_s = getStr(op, "role") orelse return error.BadOp;
        var item = &s.plan.groups[g].items[i];
        if (std.mem.eql(u8, role_s, "primary")) {
            item.role = .primary;
            item.op = .move;
        } else if (std.mem.eql(u8, role_s, "skip")) {
            item.role = .duplicate;
            item.op = .skip;
        } else if (std.mem.eql(u8, role_s, "trash")) {
            item.role = .junk;
            item.op = .trash;
        } else return error.BadOp;
        try recompute(s, g, i);
    } else if (std.mem.eql(u8, op_name, "retitle")) {
        const g = getInt(op, "group") orelse return error.BadOp;
        if (g >= s.plan.groups.len) return error.BadIndex;
        const title = getStr(op, "title") orelse return error.BadOp;
        s.plan.groups[g].title = title;
        const is_tv = s.plan.groups[g].kind == .tv;
        for (s.plan.groups[g].items, 0..) |*item, i| {
            if (is_tv) {
                if (item.fields) |*f| f.series = title;
            }
            try recompute(s, g, i);
        }
    } else if (std.mem.eql(u8, op_name, "move-item")) {
        const from = getInt(op, "from") orelse return error.BadOp;
        const it_i = getInt(op, "item") orelse return error.BadOp;
        const to = getInt(op, "to") orelse return error.BadOp;
        if (from >= s.plan.groups.len or to >= s.plan.groups.len) return error.BadIndex;
        if (it_i >= s.plan.groups[from].items.len) return error.BadIndex;
        var moved = s.plan.groups[from].items[it_i];
        if (s.plan.groups[to].kind == .tv) {
            if (moved.fields) |*f| f.series = s.plan.groups[to].title;
        }
        s.plan.groups[to].items = try appendItem(s.arena, s.plan.groups[to].items, moved);
        s.plan.groups[from].items = try removeItem(s.arena, s.plan.groups[from].items, it_i);
        try recompute(s, to, s.plan.groups[to].items.len - 1);
    } else if (std.mem.eql(u8, op_name, "split")) {
        const g = getInt(op, "group") orelse return error.BadOp;
        if (g >= s.plan.groups.len) return error.BadIndex;
        const title = getStr(op, "title") orelse return error.BadOp;
        const arr = objGet(op, "items") orelse return error.BadOp;
        if (arr != .array) return error.BadOp;
        // Collect selected items (validate indices), build the new group.
        var picked: std.ArrayList(plan.Item) = .empty;
        for (arr.array.items) |v| {
            const idx: usize = switch (v) {
                .integer => |x| if (x >= 0) @intCast(x) else return error.BadIndex,
                else => return error.BadOp,
            };
            if (idx >= s.plan.groups[g].items.len) return error.BadIndex;
            var it = s.plan.groups[g].items[idx];
            if (s.plan.groups[g].kind == .tv) {
                if (it.fields) |*f| f.series = title;
            }
            try picked.append(s.arena, it);
        }
        // Remove the picked indices from the source (high→low to keep indices valid).
        const order = try s.arena.dupe(std.json.Value, arr.array.items);
        std.mem.sort(std.json.Value, order, {}, cmpIntDesc);
        for (order) |v| s.plan.groups[g].items = try removeItem(s.arena, s.plan.groups[g].items, @intCast(v.integer));
        const new_group = plan.Group{ .kind = s.plan.groups[g].kind, .title = title, .items = try picked.toOwnedSlice(s.arena) };
        s.plan.groups = try appendGroup(s.arena, s.plan.groups, new_group);
        // Recompute the new group's items.
        const ng = s.plan.groups.len - 1;
        for (0..s.plan.groups[ng].items.len) |i| try recompute(s, ng, i);
    } else return error.BadOp;
}

fn cmpIntDesc(_: void, a: std.json.Value, b: std.json.Value) bool {
    return a.integer > b.integer;
}
fn appendGroup(a: std.mem.Allocator, groups: []plan.Group, extra: plan.Group) ![]plan.Group {
    const out = try a.alloc(plan.Group, groups.len + 1);
    @memcpy(out[0..groups.len], groups);
    out[groups.len] = extra;
    return out;
}

const t = std.testing;

fn mkSession(a: std.mem.Allocator) Session {
    const items = a.alloc(plan.Item, 1) catch unreachable;
    items[0] = .{ .src = "/x/a.mkv", .role = .primary, .op = .move, .dst = "/lib/old.mkv", .fields = .{ .series = "Old", .season = 1, .episode = 1, .ext = "mkv" } };
    const groups = a.alloc(plan.Group, 1) catch unreachable;
    groups[0] = .{ .kind = .tv, .title = "Old", .items = items };
    return .{ .arena = a, .cfg = .{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE }, .plan = .{ .library_root = "/lib", .source = "/x", .groups = groups } };
}

test "retitle recomputes dst" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try applyEdit(&s, "{\"op\":\"retitle\",\"group\":0,\"title\":\"New Show\"}");
    try t.expectEqualStrings("New Show", s.plan.groups[0].title);
    try t.expect(std.mem.indexOf(u8, s.plan.groups[0].items[0].dst.?, "New Show") != null);
}

test "set-role trash clears dst and sets trash op" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try applyEdit(&s, "{\"op\":\"set-role\",\"group\":0,\"item\":0,\"role\":\"trash\"}");
    try t.expectEqual(plan.Op.trash, s.plan.groups[0].items[0].op);
    try t.expect(s.plan.groups[0].items[0].dst == null);
}

test "move-item re-parents and recomputes under the new group" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = mkSession(a);
    // add a second (empty) tv group to move into
    const g2_items = try a.alloc(plan.Item, 0);
    s.plan.groups = try appendGroup(a, s.plan.groups, .{ .kind = .tv, .title = "Dest Show", .items = g2_items });
    try applyEdit(&s, "{\"op\":\"move-item\",\"from\":0,\"item\":0,\"to\":1}");
    try t.expectEqual(@as(usize, 0), s.plan.groups[0].items.len);
    try t.expectEqual(@as(usize, 1), s.plan.groups[1].items.len);
    try t.expect(std.mem.indexOf(u8, s.plan.groups[1].items[0].dst.?, "Dest Show") != null);
}

test "bad index errors" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try t.expectError(error.BadIndex, applyEdit(&s, "{\"op\":\"retitle\",\"group\":9,\"title\":\"x\"}"));
}
