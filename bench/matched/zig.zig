const std = @import("std");
const p = @import("paxos");
const cfg = @import("config");
const N = cfg.members;
const V = [cfg.words]u64;
const W = 4096;
const P = p.Protocol(V, .{ .max_members = N, .window_slots = W, .recovery_chunk_slots = 256 });
const Cluster = struct {
    membership: P.Membership,
    nodes: [N]P.Node,
    effects: P.Effects,
    queue: [8192]P.Envelope,
    count: usize,
    messages: u64,
};
var c: Cluster = undefined;
fn value(seq: u64) V { var v = std.mem.zeroes(V); v[0] = seq; return v; }
fn flush() !void {
    c.effects.confirmWritesDurable();
    for (c.effects.messagesSlice()) |env| {
        if (c.count == c.queue.len) return error.QueueFull;
        c.queue[c.count] = env;
        c.count += 1;
        c.messages += 1;
    }
}
fn drain() !void {
    var head: usize = 0;
    while (head < c.count) : (head += 1) {
        const env = c.queue[head];
        try c.nodes[env.to - 1].step(env, &c.effects);
        try flush();
    }
    c.count = 0;
}
fn drive_epoch(depth: usize) !void {
    var first: usize = 1;
    while (first <= W) : (first += depth) {
        for (first..@min(first + depth, W + 1)) |seq| {
            _ = try c.nodes[0].propose(value(seq), &c.effects);
            try flush();
        }
        try drain();
    }
}
noinline fn measured_epoch(depth: usize) !void { try drive_epoch(depth); }
fn epoch(io: std.Io, depth: usize, warmup: bool) !u64 {
    var ids: [N]p.NodeId = undefined;
    for (&ids, 1..) |*id, index| id.* = @intCast(index);
    try c.membership.init(&ids);
    for (&c.nodes, 1..) |*node, id| try node.init(@intCast(id), &c.membership);
    c.effects.init(); c.count = 0; c.messages = 0;
    try c.nodes[0].campaign(value(0), &c.effects);
    try flush(); try drain(); c.messages = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    if (warmup) { try drive_epoch(depth); } else { try measured_epoch(depth); }
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    for (&c.nodes) |*node| {
        if (node.decidedThrough() != W) return error.Incomplete;
        for (1..W + 1) |slot| {
            const v = node.committedAt(slot) orelse return error.Missing;
            if (!std.meta.eql(v, value(slot))) return error.WrongValue;
        }
    }
    return @intCast(start.durationTo(end).raw.nanoseconds);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedDepthAndEpochs;
    const depth = try std.fmt.parseInt(usize, args[1], 10);
    const epochs = try std.fmt.parseInt(usize, args[2], 10);
    if ((depth != 1 and depth != 8 and depth != 64) or epochs == 0) return error.InvalidArgument;
    _ = try epoch(init.io, depth, true);
    var ns: u64 = 0; var messages: u64 = 0;
    for (0..epochs) |_| { ns += try epoch(init.io, depth, false); messages += c.messages; }
    std.debug.print("{{\"ns_total\":{d},\"messages\":{d},\"values\":{d},\"node_inline_bytes\":{d},\"effects_inline_bytes\":{d},\"driver_capacity_bytes\":{d},\"validated\":true}}\n",
        .{ns, messages, W * epochs, @sizeOf(P.Node), @sizeOf(P.Effects), @sizeOf(Cluster)});
}
