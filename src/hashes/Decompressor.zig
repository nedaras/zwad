const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const math = std.math;

const Self = @This(); // add like SteamType

buf: []const u8,
hashes_len: u32,

pub const Error = error{
    EndOfStream,
};

pub fn get(self: Self, hash: u64) Error!?[]const u8 {
    var beg: u32 = 0;
    var end = self.hashes_len;

    while (beg != end) {
        const midpoint = (beg + end) / 2;
        const pos = 4 + midpoint * (8 + 4);

        if (pos + 8 > self.buf.len) return error.EndOfStream;

        const curr_hash = mem.readInt(u64, self.buf[pos..][0..8], .little);

        if (curr_hash == hash) {
            const offset = mem.readInt(u32, self.buf[pos + 8 ..][0..4], .little);
            if (offset > self.buf.len) return error.EndOfStream;

            const path_bytes: u8 = switch (self.buf[offset]) {
                0 => 3,
                else => 1,
            };

            if (offset + path_bytes > self.buf.len) return error.EndOfStream;

            const path_len = switch (path_bytes) {
                3 => mem.readInt(u16, self.buf[offset + 1 ..][0..2], .little),
                1 => self.buf[offset],
                else => unreachable,
            };

            if (offset + path_bytes + path_len > self.buf.len) return error.EndOfStream;

            const path = self.buf[offset + path_bytes .. offset + path_bytes + path_len];
            return path;
        }

        if (hash > curr_hash) {
            beg = midpoint + 1;
        }

        if (hash < curr_hash) {
            end = midpoint;
        }
    }

    return null;
}
