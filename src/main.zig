const std = @import("std");
const xxhash = @import("xxhash.zig");
const windows = @import("windows.zig");
const mapping = @import("mapping.zig");
const hashes = @import("hashes.zig");
const compress = @import("compress.zig");
const wad = @import("wad.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;
const native_endian = @import("builtin").target.cpu.arch.endian();

pub fn main_generate_hashes() !void {
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

    var game_hashes = hashes.Compressor.init(allocator);
    defer game_hashes.deinit();

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

                try game_hashes.update(hash, file);
            }
            fbs.pos = 0;

            continue;
        }
        try writer.writeAll(buf[start..end]);

        const amt = try req.read(buf[0..]);
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

    var out_dir = try fs.cwd().makeOpenPath(dst, .{});
    defer out_dir.close();

    const hashes_file = try fs.cwd().openFile(".hashes", .{});
    defer hashes_file.close();

    const hashes_mapping = try mapping.mapFile(hashes_file);
    defer hashes_mapping.unmap();

    const game_hashes = hashes.decompressor(hashes_mapping.view);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_mapping = try mapping.mapFile(file);
    defer file_mapping.unmap();

    var file_stream = io.fixedBufferStream(file_mapping.view);
    //  const reader = file_stream.reader();

    var window_buf: [1 << 17]u8 = undefined;
    var out_buf: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.zstd.Decompressor(@TypeOf(file_stream.reader())).init(allocator, undefined, .{ .window_buffer = &window_buf });
    defer zstd_stream.deinit();

    var iter = try wad.iterator(file_stream.reader(), file_stream.seekableStream());
    while (try iter.next()) |entry| {
        if (entry.entry_type != .zstd) continue;
        const compressed = file_mapping.view[entry.offset .. entry.offset + entry.compressed_len];
        var fbs = io.fixedBufferStream(compressed);

        //var zstd_stream = try compress.zstd.decompressor(allocator, fbs.reader(), .{ .window_buffer = &window_buf });
        //defer zstd_stream.deinit();
        zstd_stream.setReader(fbs.reader());

        const path = game_hashes.get(entry.hash).?;

        if (fs.path.dirname(path)) |dir| {
            try out_dir.makePath(dir);
        }

        const out_file = out_dir.createFile(path, .{}) catch |err| switch (err) {
            error.BadPathName => { // add like _invalid path
                std.debug.print("warn: invalid path:  {s}.\n", .{path});
                continue;
            },
            else => return err,
        };
        defer out_file.close();

        var len: usize = 0;
        while (true) {
            const chunk_len = try zstd_stream.read(&out_buf);
            len += chunk_len;
            if (chunk_len == 0) break;
            try out_file.writeAll(out_buf[0..chunk_len]);
        }

        if (len != entry.decompressed_len) {
            std.debug.print("invalid_len: {d}\n", .{len});
            unreachable;
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
