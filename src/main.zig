const std = @import("std");
const xxhash = @import("xxhash.zig");
const windows = @import("windows.zig");
const mapping = @import("mapping.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;
const native_endian = @import("builtin").target.cpu.arch.endian();
const Hashes = @import("Hashes.zig");

const c = @cImport({
    @cInclude("zstd.h");
});

const Header = extern struct {
    const Version = extern struct {
        magic: [2]u8,
        major: u8,
        minor: u8,
    };

    version: Version,
    ecdsa_signature: [256]u8,
    checksum: u64 align(1),
    entries_len: u32,
};

const EntryType = enum(u4) {
    raw,
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
    subchunk: u24,
    checksum: u64,
};

fn getPath(buf: []const u8, hash: u64) ?[]const u8 {
    const hashes_len = mem.readInt(u32, buf[0..4], .little);
    var beg: u32 = 0;
    var end = hashes_len;

    while (beg != end) {
        const midpoint = (beg + end) / 2;
        const pos = 4 + midpoint * (8 + 4);
        const curr_hash = mem.readInt(u64, buf[pos..][0..8], .little);

        if (curr_hash == hash) {
            const offset = mem.readInt(u32, buf[pos + 8 ..][0..4], .little);

            const path_len = mem.readInt(u16, buf[offset..][0..2], .little);
            const path = buf[offset + 2 .. offset + 2 + path_len];

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

pub fn main_buildhashes() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const uri = try std.Uri.parse("http://raw.communitydragon.org/data/hashes/lol/hashes.game.txt"); // http so there would not be any tls overhead
    var server_header_buffer: [16 * 1024]u8 = undefined;

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .keep_alive = false,
    });
    defer req.deinit();

    try req.send();

    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        //req.response.skip = true;
        //assert(try req.transferRead(&.{}) == 0);

        return error.InvalidStatusCode;
    }

    var line_buf: [4 * 1024]u8 = undefined;
    var fbs = io.fixedBufferStream(&line_buf);

    const writer = fbs.writer();

    var buf: [std.http.Client.Connection.buffer_size]u8 = undefined; // we prob can use connections buffer, like fill cmds

    var start: usize = 0;
    var end: usize = 0;

    const out_file = try fs.cwd().createFile(".hashes", .{}); // mb maping would prob be better, cuz on falure we would not have corrupted .hashes file
    defer out_file.close();

    var hashes = Hashes.init(allocator);
    defer hashes.deinit();

    while (true) { // zig implemintation is rly rly slow
        if (mem.indexOfScalar(u8, buf[start..end], '\n')) |pos| {
            try writer.writeAll(buf[start .. start + pos]);
            start += pos + 1;

            {
                const line = line_buf[0..fbs.pos];
                assert(line.len > 17);
                assert(line[16] == ' ');

                const hash = try fastHexParse(u64, line[0..16]);
                const file = line[17..];

                try hashes.update(hash, file);
            }
            fbs.pos = 0;

            continue;
        }
        try writer.writeAll(buf[start..end]);

        const amt = req.read(buf[0..]) catch |err| {
            try out_file.writeAll(hashes.data.items);
            return err;
        };
        if (amt == 0) break; //return error.EndOfStream;

        start = 0;
        end = amt;
    }

    std.debug.print("finalizing\n", .{});

    const final = try hashes.final();

    std.debug.print("writting to file: {d}\n", .{final.len});
    try out_file.writeAll(final);
}

pub fn main() !void { // not as fast as i wanted it to be, could async io make sence here?
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing;
    const dst = args.next() orelse return error.ArgumentDstDirMissing;

    var out_dir = try fs.cwd().openDir(dst, .{});
    defer out_dir.close();

    const hashes_file = try fs.cwd().openFile(".hashes", .{});
    defer hashes_file.close();

    const hashes_mapping = try mapping.mapFile(hashes_file);
    defer hashes_mapping.unmap();

    const hashes = hashes_mapping.view;

    comptime assert(@sizeOf(Header) == 272);
    comptime assert(@sizeOf(Entry) == 32);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_mapping = try mapping.mapFile(file);
    defer file_mapping.unmap();

    var file_stream = io.fixedBufferStream(file_mapping.view);
    const reader = file_stream.reader();

    const header = try reader.readStruct(Header); // todo: test if endian does matter, it should

    assert(mem.eql(u8, &header.version.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 4);

    var out_list = std.ArrayList(u8).init(allocator);
    defer out_list.deinit();

    var prev_hash: u64 = 0;
    for (header.entries_len) |_| {
        const entry = try reader.readStruct(Entry);
        const gb = 1024 * 1024 * 1024;

        assert(entry.hash >= prev_hash);
        prev_hash = entry.hash;

        assert(4 * gb > entry.compressed_len);
        assert(4 * gb > entry.decompressed_len);
        assert(4 * gb > entry.offset);

        if (getPath(hashes, entry.hash)) |path| switch (entry.entry_type) {
            .raw => {
                const pos = file_stream.pos;

                file_stream.pos = @intCast(entry.offset);
                defer file_stream.pos = pos;

                assert(file_mapping.view.len - file_stream.pos >= entry.compressed_len); // add these of checks to hashes file

                const out = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.decompressed_len];

                if (fs.path.dirname(path)) |dir| {
                    try out_dir.makePath(dir);
                }

                const out_file = out_dir.createFile(path, .{}) catch |err| switch (err) {
                    error.BadPathName => {
                        std.debug.print("warn: invalid path:  {s}.\n", .{path});
                        continue;
                    },
                    else => return err,
                };
                defer out_file.close();

                try out_file.writeAll(out);
            },
            .zstd, .zstd_multi => {
                const pos = file_stream.pos;

                file_stream.pos = @intCast(entry.offset);
                defer file_stream.pos = pos;

                try out_list.ensureTotalCapacity(entry.decompressed_len);
                out_list.items.len = entry.decompressed_len;

                assert(file_mapping.view.len - file_stream.pos >= entry.compressed_len); // add these of checks to hashes file

                const in = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.compressed_len];
                const out = out_list.items;

                const zstd_len = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len); // we could have stack buf and just fill it and write to file, and thus we would not need to alloc mem.
                if (c.ZSTD_isError(zstd_len) == windows.TRUE) {
                    std.debug.print("err: {s}\n", .{c.ZSTD_getErrorName(zstd_len)});
                }

                if (fs.path.dirname(path)) |dir| {
                    try out_dir.makePath(dir);
                }

                const out_file = out_dir.createFile(path, .{}) catch |err| switch (err) {
                    error.BadPathName => {
                        std.debug.print("warn: invalid path:  {s}.\n", .{path});
                        continue;
                    },
                    else => return err,
                };
                defer out_file.close();

                try out_file.writeAll(out);
            },
            .link, .gzip => |t| { // hiping that gzip in zig is now slow.
                std.debug.print("warn: idk how to handle {s}, path: {s}.\n", .{ @tagName(t), path });
            },
        } else {
            std.debug.print("unknown file: 0x{X}\n", .{entry.hash});
        }
    }
}

fn fastHexParse(comptime T: type, buf: []const u8) !u64 { // we can simd, but idk if its needed
    var result: T = 0;

    for (buf) |ch| {
        var mask: T = undefined;

        if (ch >= '0' and ch <= '9') {
            mask = ch - '0';
        } else if (ch >= 'a' and ch <= 'f') {
            mask = ch - 'a' + 10;
        } else {
            return error.InvalidCharacter;
        }

        if (result > std.math.maxInt(T) >> 4) {
            return error.Overflow;
        }

        result = (result << 4) | mask;
    }

    return result;
}
