const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const math = std.math;
const native_endian = @import("builtin").target.cpu.arch.endian();

const Self = @This();
const Data = std.ArrayListUnmanaged(u8);

allocator: Allocator,
data: Data,

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .data = Data{},
    };
}

pub fn deinit(self: *Self) void {
    self.data.deinit(self.allocator);
}

// todo: add lots of asserts and remove recursion

pub fn update(self: *Self, hash: u64, path: []const u8) Allocator.Error!void {
    if (mem.startsWith(u8, path, "assets/sounds/wwise//")) return;

    var buf: [4 * 1024]u8 = undefined;
    var stack_allocator = std.heap.FixedBufferAllocator.init(&buf);

    var frames = std.ArrayList(usize).init(stack_allocator.allocator());
    defer frames.deinit();

    var buf_start: usize = 0;
    var path_start: usize = 0;

    var block_end = self.data.items.len;
    outer: while (path_start != path.len) {
        const split_start = path_start;
        const split_end: usize = if (mem.indexOfScalar(u8, path[path_start..], '/')) |pos| split_start + pos else path.len;
        const split = path[split_start..split_end];

        if (split.len <= 0) {
            std.debug.print("{s}\n", .{path});
            std.debug.print("data_len: {d}\n", .{self.data.items.len});
        }

        assert(split.len > 0);
        assert(split.len <= math.maxInt(u16));

        while (block_end > buf_start) { //  bench
            const obj_len = mem.readInt(u32, self.data.items[buf_start..][0..4], native_endian);
            const str_len = mem.readInt(u16, self.data.items[buf_start + 4 ..][0..2], native_endian);
            const str = self.data.items[buf_start + 4 + 2 .. buf_start + 4 + 2 + str_len];

            if (mem.eql(u8, str, split)) {
                try frames.append(buf_start);
                block_end = buf_start + obj_len;
                buf_start += 4 + 2 + str_len;
                path_start += split.len + 1;
                continue :outer;
            }

            buf_start += @intCast(obj_len);
        }

        const write_index = buf_start;
        const write_len = count(path[split_start..]);

        const buf_end = self.data.items.len;
        assert(buf_end >= write_index);

        try self.data.ensureUnusedCapacity(self.allocator, write_len);
        self.data.items.len += write_len;

        if (buf_end > write_index) {
            const dst = self.data.items[write_index + write_len .. buf_end + write_len];
            const src = self.data.items[write_index..buf_end];
            mem.copyBackwards(u8, dst, src); // bench
        }

        const len = write(self.data.items[write_index..], path[split_start..]); // bench

        assert(write_len == len);

        for (frames.items) |frame_start| {
            const frame_len = mem.readInt(u32, self.data.items[frame_start..][0..4], native_endian);
            mem.writeInt(u32, self.data.items[frame_start..][0..4], frame_len + @as(u32, @intCast(len)), native_endian);
        }

        path_start = path.len;
        frames.clearRetainingCapacity();
    }
    _ = hash;
}

pub fn final(self: Self) []u8 {
    setOffsets(self.data.items, 0);
    return self.data.items;
}

fn count(input: []const u8) u32 {
    assert(input.len > 0);

    var len: u32 = 0;
    var it = mem.splitScalar(u8, input, '/');
    while (it.next()) |v| {
        assert(v.len > 0);
        assert(v.len <= math.maxInt(u16));

        len += 4 + 2 + @as(u32, @intCast(v.len));
    }
    return len;
}

fn write(buf: []u8, input: []const u8) u32 {
    assert(input.len > 0);

    const split = input[0..(mem.indexOfScalar(u8, input, '/') orelse input.len)];
    assert(split.len > 0);
    assert(split.len <= math.maxInt(u16));

    //buf[4] = @intCast(split.len);
    mem.writeInt(u16, buf[4..6], @intCast(split.len), native_endian);
    @memcpy(buf[6 .. 6 + split.len], split);

    var len = 4 + 2 + @as(u32, @intCast(split.len));
    if (mem.indexOfScalar(u8, input, '/')) |pos| {
        len += write(buf[len..], input[pos + 1 ..]);
    }

    mem.writeInt(u32, buf[0..4], @intCast(len), native_endian);
    return len;
}

fn setOffsets(buf: []u8, obj_beg: u32) void {
    _ = buf;
    _ = obj_beg;
}
