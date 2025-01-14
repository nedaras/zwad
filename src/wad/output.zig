const std = @import("std");
const toc = @import("toc.zig");
const xxhash = @import("../xxhash.zig");
const ascii = std.ascii;

pub const Header = extern struct {
    version: toc.Version,
    raw_header: toc.LatestHeader,

    pub const Options = struct {
        entries_len: u32 = 0,
    };

    pub fn init(options: Options) Header {
        var header = std.mem.zeroes(toc.LatestHeader);
        header.entries_len = options.entries_len;

        return .{
            .version = .{ .major = 3, .minor = 4 },
            .raw_header = header,
        };
    }
};

pub const Entry = extern struct {
    raw_entry: toc.LatestEntry,

    pub fn init() Entry {}
};
