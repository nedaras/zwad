const std = @import("std");
const xxhash = @import("xxhash.zig");
const windows = @import("windows.zig");
const mapping = @import("mapping.zig");
const hashes = @import("hashes.zig");
const compress = @import("compress.zig");
const wad = @import("wad.zig");
const cli = @import("cli.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;
const native_endian = @import("builtin").target.cpu.arch.endian();
const time = std.time;

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

// add a wraper that would handle HandleErrors, like if unexpected link github where they could submit those errors
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = handleArguments(allocator) catch return;
    defer args.deinit();

    if (args.options.file) |file| {
        std.debug.print("{s}\n", .{file});
    }

    if (args.options.hashes) |h| {
        std.debug.print("{s}\n", .{h});
    }

    const src = null orelse return error.ArgumentSrcFileMissing;
    const dst = null orelse return error.ArgumentDstDirMissing;

    var out_dir = try fs.cwd().makeOpenPath(dst, .{});
    defer out_dir.close();

    const hashes_file = try fs.cwd().openFile(".hashes", .{});
    defer hashes_file.close();

    const hashes_mapping = try mapping.mapFile(hashes_file, .{});
    defer hashes_mapping.unmap();

    const game_hashes = hashes.decompressor(hashes_mapping.view);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_mapping = try mapping.mapFile(file, .{});
    defer file_mapping.unmap();

    var file_stream = io.fixedBufferStream(file_mapping.view);

    var window_buf: [1 << 17]u8 = undefined;
    var iter = try wad.iterator(allocator, file_stream.reader(), file_stream.seekableStream(), &window_buf);
    defer iter.deinit();

    // add multithreading
    while (try iter.next()) |entry| {
        const path = game_hashes.get(entry.hash).?;
        const out_file = makeFile(out_dir, path) catch |err| switch (err) {
            error.BadPathName => {
                std.debug.print("_invalid: {s}\n", .{path});
                continue;
            },
            else => |e| return e,
        };
        defer out_file.close();

        const out_maping = try mapping.mapFile(out_file, .{
            .mode = .write_only,
            .size = entry.decompressed_len,
        });
        defer out_maping.unmap();

        switch (entry.decompressor) {
            .none => |stream| {
                assert(try stream.readAll(out_maping.view) == entry.decompressed_len);
            },
            .zstd => |zstd_stream| {
                var idx: usize = 0;
                while (entry.decompressed_len > idx) { // cuz if we hit zstd_multi we will have multiple blocks
                    const amt = try zstd_stream.readAll(out_maping.view[idx..]);
                    idx += amt;
                }
                assert(idx == entry.decompressed_len);
            },
        }
    }
}

const HandleError = error{
    OutOfMemory,
    EarlyReturn,
    Fatal,
    Unexpected,
};

fn handleArguments(allocator: mem.Allocator) HandleError!cli.Arguments {
    // should we add logger?
    var diagnostics = cli.Diagnostics{
        .allocator = allocator,
    };
    defer diagnostics.deinit();

    var args = cli.parseArguments(allocator, .{ .diagnostics = &diagnostics }) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("zwad: Out of memory\n", .{});
            return error.OutOfMemory;
        },
        else => unreachable,
    };
    errdefer args.deinit();

    if (diagnostics.errors.items.len > 0) {
        switch (diagnostics.errors.items[0]) {
            .unknown_option => |err| {
                if (mem.eql(u8, err.option, "help")) {
                    std.debug.print(cli.help, .{});
                    return error.EarlyReturn;
                }
                std.debug.print("zwad: unrecognized option '{s}{s}'\n", .{ if (err.option.len == 1) "-" else "--", err.option });
            },
            .unexpected_argument => |err| {
                std.debug.print("zwad: option '--{s}' doesn't allow an argument\n", .{err.option});
            },
            .empty_argument => |err| {
                std.debug.print("zwad: option '{s}{s}' requires an argument\n", .{ if (err.option.len == 1) "-" else "--", err.option });
            },
        }
        std.debug.print("Try 'zwad --help' for more information.", .{});
        return error.EarlyReturn;
    }

    return args;
}

const MakeFileError = fs.File.OpenError || fs.Dir.MakeError || fs.File.StatError;

pub fn makeFile(dir: fs.Dir, sub_path: []const u8) MakeFileError!fs.File {
    return dir.createFile(sub_path, .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound => {
            if (fs.path.dirname(sub_path)) |sub_dir| {
                @setCold(false);
                try dir.makePath(sub_dir);
                return dir.createFile(sub_path, .{ .read = true });
            }
            return error.FileNotFound;
        },
        else => |e| return e,
    };
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
