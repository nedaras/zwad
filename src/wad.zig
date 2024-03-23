const std = @import("std");
const PathThree = @import("PathThree.zig");

extern fn ZSTD_decompress(dst: *anyopaque, dst_len: usize, src: *const anyopaque, src_len: usize) usize;
extern fn ZSTD_getErrorName(code: usize) [*c]const u8;
extern fn ZSTD_isError(code: usize) bool;

const fs = std.fs;
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const Allocator = mem.Allocator;
const File = fs.File;

const Version = extern struct {
    magic: [2]u8,
    major: u8,
    minor: u8,

    fn latest() Version {
        return .{ .magic = [_]u8{ 'R', 'W' }, .major = 3, .minor = 3 };
    }
};

const HeaderV3 = extern struct {
    signature: [16]u8,
    signature_unused: [240]u8,
    checksum: [8]u8,
    entries_count: u32,
};

const EntryV3 = packed struct {
    hash: u64,
    offset: u32,
    size_compressed: u32,
    size_decompressed: u32,
    type: u4,
    subchunk_count: u4,
    is_duplicate: u8,
    subchunk_index: u16,
    checksum_old: u64,
};

pub const WADFile = struct {
    file: File,
    entries_count: u32,

    entry_index: u32 = 0,

    pub const OpenError = error{
        InvalidVersion,
    } || File.OpenError;

    pub const DecompressError = error{
        InvalidEntry,
        InvalidEntryType,
        InvalidEntrySize,
    } || Allocator.Error || File.ReadError || File.SeekError || File.GetSeekPosError;

    pub fn next(self: *WADFile) !?EntryV3 {
        if (self.entry_index >= self.entries_count) return null;

        self.entry_index += 1;

        const reader = self.file.reader();
        return try reader.readStruct(EntryV3);
    }

    fn fillBuffer(self: WADFile, buffer: []u8, offset: u32) !void {
        const pos = try self.file.getPos();
        try self.file.seekTo(offset);

        _ = try self.file.read(buffer);

        try self.file.seekTo(pos);
    }

    // well multithreading would be cool
    pub fn decompressEntry(self: WADFile, allocator: Allocator, entry: EntryV3) DecompressError![]u8 {
        var out = try allocator.alloc(u8, entry.size_decompressed);
        errdefer allocator.free(out);

        switch (entry.type) {
            0 => {
                if (entry.size_compressed != entry.size_decompressed) return WADFile.DecompressError.InvalidEntrySize;

                try self.fillBuffer(out, entry.offset);
                return out;
            },
            3 => {
                var src = try allocator.alloc(u8, entry.size_compressed);
                defer allocator.free(src);

                try self.fillBuffer(src, entry.offset);

                const bytes = ZSTD_decompress(out.ptr, entry.size_decompressed, src.ptr, entry.size_compressed);
                if (ZSTD_isError(bytes)) return WADFile.DecompressError.InvalidEntry;
            },
            else => return WADFile.DecompressError.InvalidEntryType,
        }

        return out;
    }

    pub fn close(self: WADFile) void {
        self.file.close();
    }
};

pub fn openFile(path: []const u8) !WADFile {
    const file = try fs.cwd().openFile(path, .{ .mode = .read_write });
    errdefer file.close();

    const reader = file.reader(); // we can read ver and head with one sys call

    const version = try reader.readStruct(Version);

    if (!std.meta.eql(version, Version.latest())) return WADFile.OpenError.InvalidVersion;

    const header = try reader.readStruct(HeaderV3);

    return .{
        .file = file,
        .entries_count = header.entries_count,
    };
}

// we still need to reduce allocations
// btw three.deinit takes fucking time too, we prob would want arena allocator for that

// c_allocator ~ 30s (deinit was instant btw),
// gpa ~ 120s,
// page_allocator ~ 130s
// arena (page_allocator) ~ 130s (deinit was rly fast)
// arena (c_allocator) ~ 130s (deinit was slower then just c_alocator)
//
// so its best to use c_allocator or arena if we like care for safety but we want to be fast with our deinits
pub fn importHashes(allocator: Allocator, path: []const u8) !PathThree {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    var buffered_reader = io.bufferedReaderSize(0x10000, file.reader());
    const reader = buffered_reader.reader();

    var three = PathThree.init(allocator);
    errdefer three.deinit();

    var buffer: [1028 * 8]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |data| {
        const file_path = data[16 + 1 ..];

        try three.addPath(file_path, 69);
        print("{s}\n", .{file_path});
    }
}
