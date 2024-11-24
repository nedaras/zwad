const std = @import("std");

pub const Compressor = @import("hashes/Compressor.zig");
pub const Decompressor = @import("hashes/Decompressor.zig");

pub fn decompressor(buf: []const u8) Decompressor {
    return .{
        .buf = buf,
        .hashes_len = std.mem.readInt(u32, buf[0..4], .little),
    };
}
