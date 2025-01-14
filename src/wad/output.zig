const std = @import("std");
const toc = @import("toc.zig");
const xxhash = @import("../xxhash.zig");
const ascii = std.ascii;
const assert = std.debug.assert;

pub const max_file_size = std.math.maxInt(u32);
pub const max_archive_size = max_file_size * 2;

pub const max_entries_len = @divTrunc(max_file_size - @sizeOf(toc.LatestHeader), @sizeOf(toc.LatestEntry));

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

    pub fn setEntriesLen(self: *Header, entries: u32) void {
        assert(max_entries_len >= entries);
        self.raw_header.entries_len = entries;
    }
};

pub const Entry = extern struct {
    raw_entry: toc.LatestEntry,

    pub const Options = struct {
        path: ?[]const u8 = null,
        offset: u32 = 0,
        compressed_size: u32 = 0,
        decompressed_size: u32 = 0,
        type: toc.EntryType = .raw,
        duplicate: bool = false,
        checksum: u64 = 0,
    };

    pub fn init(options: Options) Entry {
        var res = Entry{ .raw_entry = .{
            .hash = 0,
            .offset = options.offset,
            .compressed_size = options.compressed_size,
            .decompressed_size = options.decompressed_size,
            .byte = 0,
            .duplicate = options.duplicate,
            .subchunk_index = 0,
            .checksum = options.checksum,
        } };

        if (options.path) |path| {
            res.setPath(path);
        }

        res.setType(options.type);
        return res;
    }

    pub inline fn setPath(self: *Entry, path: []const u8) void {
        if (std.debug.runtime_safety) for (path) |c| {
            assert(ascii.isASCII(c) and (!ascii.isAlphabetic(c) or ascii.isLower(c)));
        };
        self.raw_entry.hash = xxhash.XxHash64.hash(0, path);
    }

    pub inline fn setOffset(self: *Entry, offset: u32) void {
        self.raw_entry.offset = offset;
    }

    pub inline fn setCompressedSize(self: *Entry, size: u32) void {
        self.raw_entry.compressed_size = size;
    }

    pub inline fn setType(self: *Entry, entry_type: toc.EntryType) void {
        self.raw_entry.byte |= @as(u8, @intFromEnum(entry_type)) << 4;
    }

    pub inline fn setDuplicate(self: *Entry) void {
        self.raw_entry.duplicate = true;
    }
};
