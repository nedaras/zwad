const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const math = std.math;

const Self = @This();
const Hashes = std.AutoArrayHashMapUnmanaged(u64, u32);
const Data = std.ArrayListUnmanaged(u8);

allocator: Allocator,
hashes: Hashes = Hashes{},
data: Data = Data{},
finalized: bool = false,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.hashes.deinit(self.allocator);
    self.data.deinit(self.allocator);
}

const UpdateError = error{
    NameTooLong,
    AlreadyExists,
} || Allocator.Error;

pub fn update(self: *Self, hash: u64, path: []const u8) UpdateError!void {
    assert(!self.finalized);
    assert(path.len > 0);

    if (path.len > math.maxInt(u64)) return error.NameTooLong;
    assert(math.maxInt(u32) >= self.data.items.len + 2 + path.len); // 2 bytes for byte_len
    if (self.hashes.get(hash) != null) return error.AlreadyExists;

    const path_len: u16 = @intCast(path.len);
    const pos: u32 = @intCast(self.data.items.len);

    try self.hashes.put(self.allocator, hash, pos);

    const writer = self.data.writer(self.allocator);
    try writer.writeInt(u16, path_len, .little); // use that one byte thingy
    try writer.writeAll(path);
}

pub fn final(self: *Self) Allocator.Error![]const u8 {
    assert(!self.finalized);
    assert(math.maxInt(u32) >= 4 + self.hashes.keys().len * (8 + 4));
    assert(math.maxInt(u32) >= self.data.items.len);

    const header_len: u32 = @intCast(4 + self.hashes.keys().len * (8 + 4));
    const content_len: u32 = @intCast(self.data.items.len);

    try self.data.ensureUnusedCapacity(self.allocator, header_len);
    defer self.finalized = true;

    self.data.items.len += header_len;
    const out = self.data.items;

    mem.copyBackwards(u8, out[header_len..], out[0..content_len]);

    const Context = struct {
        keys: []u64,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.keys[a_index] < ctx.keys[b_index];
        }
    };

    self.hashes.sortUnstable(Context{ .keys = self.hashes.keys() });
    mem.writeInt(u32, out[0..4], @intCast(self.hashes.keys().len), .little);

    var buf_start: u32 = 4;
    for (self.hashes.keys()) |hash| {
        const pos = self.hashes.get(hash).?;
        mem.writeInt(u64, out[buf_start..][0..8], hash, .little);
        mem.writeInt(u32, out[buf_start + 8 ..][0..4], pos + header_len, .little);
        buf_start += 8 + 4;
    }

    return out;
}
