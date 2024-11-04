const std = @import("std");
const xxhash = @import("xxhash.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;
const win = std.os.windows;

extern "kernel32" fn CreateFileMappingA(hFile: win.HANDLE, ?*anyopaque, flProtect: win.DWORD, dwMaximumSizeHigh: win.DWORD, dwMaximumSizeLow: win.DWORD, lpName: ?win.LPCSTR) callconv(.C) ?win.HANDLE;

extern "kernel32" fn MapViewOfFile(hFileMappingObject: win.HANDLE, dwDesiredAccess: win.DWORD, dwFileOffsetHigh: win.DWORD, dwFileOffsetLow: win.DWORD, dwNumberOfBytesToMap: win.SIZE_T) callconv(.C) ?[*]u8;

const c = @cImport({
    @cInclude("zstd.h");
});

const Header = extern struct {
    const Version = extern struct {
        major: u8,
        minor: u8,
    };

    magic: [2]u8,
    version: Version,
    signature: u128 align(1), // its just all entries checksums hashed
    unknown: [240]u8, // idk what should this be
    checksum: u64 align(1),
    entries_len: u32,
};

const EntryType = enum(u4) {
    raw = 0,
    link,
    gzip,
    zstd,
    zstd_multi,
};

const Entry = packed struct {
    hash: u64,
    offset: u32,
    compressed_len: u32,
    decompressed_len: u32,
    entry_type: EntryType,
    subchunk_len: u4,
    duplicate: u8,
    subchunk: u16,
    checksum: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing; // now try to extract only a file
    const dst = args.next() orelse return error.ArgumentDstDirMissing;

    comptime assert(@sizeOf(Header) == 272);
    comptime assert(@sizeOf(Entry) == 32);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    if (CreateFileMappingA(file.handle, null, win.PAGE_READONLY, 0, 0, null)) |map| {
        defer win.CloseHandle(map);
        const ptr = MapViewOfFile(map, 0x4, 0, 0, 0);
        if (ptr == null) {
            return error.No;
        }
        std.debug.print("magic: {s}\n", .{ptr.?[0..2]});
        return error.Yes;
    }

    var out_dir = try fs.cwd().openDir(dst, .{});
    defer out_dir.close();

    var fbr = io.bufferedReader(file.reader());
    const reader = fbr.reader();

    const header = try reader.readStruct(Header); // idk if league uses a specific endian, my guess is that they do not

    assert(mem.eql(u8, &header.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 3);

    var out_list = std.ArrayList(u8).init(allocator); // todo: dont use arraylist as a reusible buffer
    defer out_list.deinit();

    var in_list = std.ArrayList(u8).init(allocator);
    defer in_list.deinit();

    var scrape_buf: [256]u8 = undefined;
    for (header.entries_len) |_| { // prob its better to mmap file then streaming and seeking it
        const entry = try reader.readStruct(Entry);
        switch (entry.entry_type) {
            .zstd => {
                const pos = try file.getPos();
                try file.seekTo(entry.offset);

                try out_list.ensureTotalCapacity(entry.decompressed_len);
                try in_list.ensureTotalCapacity(entry.compressed_len);
                assert(out_list.capacity >= entry.decompressed_len);
                assert(in_list.capacity >= entry.compressed_len);

                const out = out_list.items.ptr[0..entry.decompressed_len];
                const in = in_list.items.ptr[0..entry.compressed_len];

                assert(try file.reader().readAll(in) == in.len);

                const zstd_len = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len); // can we stream it, check how does ZSTD_decompressStream work and make zig like api.
                if (c.ZSTD_isError(zstd_len) == 1) {
                    std.debug.print("err: {s}\n", .{c.ZSTD_getErrorName(zstd_len)});
                }

                try file.seekTo(pos);

                const name = try std.fmt.bufPrint(&scrape_buf, "{x}.dds", .{entry.hash});
                const out_file = try out_dir.createFile(name, .{});
                defer out_file.close();

                try out_file.writeAll(out);
            },
            .raw, .gzip, .link, .zstd_multi => |t| {
                std.debug.print("warn: idk how to handle, {s}.\n", .{@tagName(t)});
            },
        }
    }
}
