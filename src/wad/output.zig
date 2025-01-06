const std = @import("std");

pub const Header = extern struct {
    magic: [2]u8,
    version: [2]u8,
    ecdsa_signature: [256]u8,
    checksum: [8]u8,
    entries_len: u32,

    pub fn init() Header {
        var ret = std.mem.zeroes(Header);
        ret.magic = [_]u8{ 'R', 'W' };
        ret.version = [_]u8{ 3, 4 };
        return ret;
    }

    pub inline fn setSize(self: *Header, size: u32) void {
        self.entries_len = size;
    }

    pub fn updateChecksum(self: *Header) void {
        const offset = @sizeOf(Header);
        _ = offset;
        _ = self;
        @panic("idk how");
    }
};
