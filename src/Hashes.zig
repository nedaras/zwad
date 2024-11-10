const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
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
    var buf: [4 * 1024]u8 = undefined;
    var stack_allocator = std.heap.FixedBufferAllocator.init(&buf);

    var frames = std.ArrayList(usize).init(stack_allocator.allocator());
    defer frames.deinit();

    var buf_start: usize = 0;
    var path_start: usize = 0;
    outer: while (path_start != path.len) {
        const split_start = path_start;
        const split_end: usize = if (mem.indexOfScalar(u8, path[path_start..], '/')) |pos| split_start + pos else path.len;
        const split = path[split_start..split_end];

        assert(split.len > 0);
        assert(split.len <= 255);

        // found problem - when size becomes smth, like [0x00, 0x10, 0x00, 0x00], we think its enf of object
        while (self.data.items.len > buf_start and self.data.items[buf_start] != 0) {
            const obj_len = mem.readInt(u32, self.data.items[buf_start..][0..4], native_endian);
            const str_len = self.data.items[buf_start + 4];
            const str = self.data.items[buf_start + 4 + 1 .. buf_start + 4 + 1 + str_len];

            if (mem.eql(u8, str, split)) {
                try frames.append(buf_start);
                buf_start += 4 + 1 + str_len + 1 + 1;
                path_start += split.len + 1;
                continue :outer;
            }

            buf_start += @intCast(obj_len);
        }

        std.debug.print("full: {s}, writting: {s}\n", .{ path[0..split_start], path[split_start..] });

        const write_index = buf_start;
        const write_len = count(path[split_start..]); // can be expensi, prob can optimize

        const buf_end = self.data.items.len;
        assert(buf_end >= write_index);

        try self.data.ensureUnusedCapacity(self.allocator, write_len);
        self.data.items.len += write_len;

        if (buf_end > write_index) {
            const dst = self.data.items[write_index + write_len .. buf_end + write_len];
            const src = self.data.items[write_index..buf_end];
            mem.copyBackwards(u8, dst, src); // prob is very expensive, prob need to add like rope algo
        }

        const len = write(self.data.items[write_index..], path[split_start..]); // prob expensive

        assert(write_len == len);

        for (frames.items) |frame_start| {
            const frame_len = mem.readInt(u32, self.data.items[frame_start..][0..4], native_endian);
            mem.writeInt(u32, self.data.items[frame_start..][0..4], frame_len + @as(u32, @intCast(len)), native_endian);
        }

        path_start = path.len;
        //buf_end += @intCast(len);

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

    // obj_len + str_len + _str + str_len + obj_beg +  obj_end
    // add like an offset to upper frame
    const static_len = 4 + 1 + 1 + 1 + 1;
    if (mem.indexOfScalar(u8, input, '/')) |pos| {
        return static_len + @as(u32, @intCast(input[0..pos].len)) + count(input[pos + 1 ..]);
    }

    return static_len + @as(u32, @intCast(input.len));
}

fn write(buf: []u8, input: []const u8) usize {
    assert(input.len > 0);

    const split = input[0..(mem.indexOfScalar(u8, input, '/') orelse input.len)];
    buf[4] = @intCast(split.len);
    @memcpy(buf[5 .. 5 + split.len], split);
    buf[5 + split.len] = @intCast(split.len);
    buf[6 + split.len] = 1;

    var len = split.len + 7;
    if (mem.indexOfScalar(u8, input, '/')) |pos| {
        len += write(buf[len..], input[pos + 1 ..]);
    }

    mem.writeInt(u32, buf[0..4], @intCast(len + 1), native_endian);
    buf[len] = 0;
    return len + 1;
}

fn setOffsets(buf: []u8, obj_beg: u32) void {
    if (buf[0] == 0) return;
    const obj_len = mem.readInt(u32, buf[0..4], native_endian);
    assert(buf.len == obj_len);

    const str_len = buf[4];
    mem.writeInt(u32, buf[0..4], obj_beg, native_endian);

    var buf_start: usize = 4 + 1 + str_len + 1 + 1;
    while (buf[buf_start] != 0) {
        const child_obj_len = mem.readInt(u32, buf[buf_start..][0..4], native_endian);
        setOffsets(buf[buf_start .. buf_start + child_obj_len], @intCast(buf_start));
        buf_start += child_obj_len;
    }
}
