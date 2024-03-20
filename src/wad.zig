const std = @import("std");

const fs = std.fs;
const io = std.io;
const mem = std.mem;
const print = std.debug.print;
const Allocator = mem.Allocator;

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

const File = fs.File;
const Reader = io.BufferedReader(4096, File.Reader); // comptime the size mb

pub const WADFile = struct {
    file: File,
    allocator: Allocator,
    buffer_reader: *Reader,
    entries_count: u32,

    entry_index: u32 = 0,
    hash_maps: std.AutoHashMapUnmanaged(u8, []u8) = .{},

    pub const OpenError = error{
        InvalidVersion,
    };

    pub fn next(self: *WADFile) !?EntryV3 {
        if (self.entry_index >= self.entries_count) return null;

        self.entry_index += 1;

        // is reader like a ptr or struct?
        // it is soo i guess it better to have reader class
        const reader = self.buffer_reader.reader();
        return try reader.readStruct(EntryV3);
    }

    pub fn getBuffer(self: *WADFile, entry: EntryV3) ![]u8 {
        var buffer = try self.allocator.alloc(u8, entry.size_compressed);

        const pos = try self.file.getPos();
        try self.file.seekTo(entry.offset);

        // wait some reason the file reader works and not buffered_reader
        const read = try self.file.reader().read(buffer);
        print("read: {}\n", .{read});
        try self.file.seekTo(pos);

        return buffer;
    }

    pub fn close(self: WADFile) void {
        self.allocator.destroy(self.buffer_reader);
        self.file.close();
    }
};

pub fn openFile(path: []const u8, allocator: Allocator) !WADFile {
    const file = try fs.cwd().openFile(path, .{ .mode = .read_write });
    errdefer file.close();

    var buffer_reader = try allocator.create(Reader);
    errdefer allocator.destroy(buffer_reader);

    buffer_reader.* = io.bufferedReader(file.reader());

    const reader = buffer_reader.reader();

    const version = try reader.readStruct(Version);

    if (!std.meta.eql(version, Version.latest())) return WADFile.OpenError.InvalidVersion;

    const header = try reader.readStruct(HeaderV3);

    return .{
        .file = file,
        .allocator = allocator,
        .buffer_reader = buffer_reader,
        .entries_count = header.entries_count,
    };
}
