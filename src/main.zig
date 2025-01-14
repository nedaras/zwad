const std = @import("std");
const mapping = @import("mapping.zig");
const hashes = @import("hashes.zig");
const compress = @import("compress.zig");
const wad = @import("wad.zig");
const cli = @import("cli.zig");
const logger = @import("logger.zig");
const handle = @import("handled.zig").handle;
const HandleError = @import("handled.zig").HandleError;
const list = @import("list.zig").list;
const extract = @import("extract.zig").extract;
const create = @import("create.zig").create;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;

pub fn ___main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const uri = try std.Uri.parse("https://raw.communitydragon.org/data/hashes/lol/hashes.game.txt"); // http so there would not be any tls overhead
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

    const final = try game_hashes.final();

    std.debug.print("writting to file: {d}\n", .{final.len});
    try out_file.writeAll(final);
}

fn loadTOC(allocator: std.mem.Allocator, file: fs.File) !?struct { []const u8, []const u8 } {
    const header: wad.output.Header = try file.reader().readStruct(wad.output.Header);

    for (0..header.raw_header.entries_len) |_| {
        const entry: wad.output.Entry = try file.reader().readStruct(wad.output.Entry);
        if (entry.raw_entry.hash != @import("xxhash.zig").XxHash64.hash(0, "data/final/global.wad.subchunktoc")) continue;

        try file.seekTo(entry.raw_entry.offset);

        const in = try allocator.alloc(u8, entry.raw_entry.compressed_size);
        errdefer allocator.free(in);

        try file.reader().readNoEof(in);

        const out = try allocator.alloc(u8, entry.raw_entry.decompressed_size);
        errdefer allocator.free(out);

        try @import("compress/zstandart/zstandart.zig").decompress(in, out);

        try file.seekTo(0);
        return .{ out, in };
    }
    try file.seekTo(0);
    return null;
}

pub fn __main() !void {
    //const file = try fs.cwd().openFile("CommonLEVELS.wad.client", .{}); // why does this work?
    const file = try fs.cwd().openFile("TFTChampion.wad.client", .{});
    defer file.close();

    //const toc, const toc_comp = (try loadTOC(std.heap.page_allocator, file)).?;
    //defer std.heap.page_allocator.free(toc);

    //var toc_stream = io.fixedBufferStream(toc);

    var checksum = @import("xxhash.zig").XxHash64.init(0);
    const header: wad.output.Header = try file.reader().readStruct(wad.output.Header);

    std.debug.print("checksum: {x}\n", .{header.raw_header.checksum});

    // not working with subchunks mb we can just set subchunks to zero
    for (0..header.raw_header.entries_len) |_| {
        const entry: wad.output.Entry = try file.reader().readStruct(wad.output.Entry);
        //const raw_entry: [32]u8 = @bitCast(entry);
        const subchunk_len = entry.raw_entry.byte >> 4;

        const perfect_entry = @import("wad/toc.zig").LatestEntry{
            .hash = entry.raw_entry.hash,
            .offset = entry.raw_entry.offset,
            .decompressed_size = entry.raw_entry.decompressed_size,
            .compressed_size = entry.raw_entry.compressed_size,
            .byte = entry.raw_entry.byte,
            .duplicate = false,
            .subchunk_index = 0,
            .checksum = entry.raw_entry.checksum,
        };
        const raw_entry: [32]u8 = @bitCast(perfect_entry);

        if (entry.raw_entry.duplicate) {
            unreachable;
        }

        //if (entry.raw_entry.hash == @import("xxhash.zig").XxHash64.hash(0, "data/final/global.wad.subchunktoc")) {
        //continue;
        //}
        checksum.update(&raw_entry);

        if (subchunk_len > 0) {
            unreachable;
        }

        //checksum.update(&raw_entry);
        //const subchunk_len = entry.raw_entry.byte >> 4;
        //if (subchunk_len > 0) {
        //try toc_stream.seekTo(@as(u64, entry.raw_entry.subchunk_index) * 16);
        //for (0..subchunk_len) |_| {
        //var raw_subchunk: [16]u8 = undefined;
        //try toc_stream.reader().readNoEof(&raw_subchunk);
        //checksum.update(&raw_subchunk);
        //}
        //}
        //checksum.update(&raw_entry);
    }

    //_ = toc_comp;
    //checksum.update(toc);

    //_ = toc_comp[0];
    std.debug.print("mysum:    {x}\n", .{checksum.final()});
}

// todo: findout how does league of legends create them header checksums
//   * find a file that has no duplicates and no subchunks and try to guess
//   * or mb we need to reverse it inside league of legends itself, there prob is some verify function

// add a wraper that would handle HandleErrors, like if unexpected link github where they could submit those errors
// todo: we need a way to test our application fuzzing would be the best way
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = false }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = handle(handleArguments(allocator));
    defer args.deinit();

    return switch (args.operation) {
        .list => handle(list(args.options)),
        .extract => handle(extract(allocator, args.options, args.files)),
        .create => try create(allocator, args.options, args.files),
    };
}

fn handleArguments(allocator: mem.Allocator) HandleError!cli.Arguments {
    var diagnostics = cli.Diagnostics{
        .allocator = allocator,
    };
    defer diagnostics.deinit();

    var args = cli.parseArguments(allocator, .{ .diagnostics = &diagnostics }) catch |err| return switch (err) {
        error.OutOfMemory => |e| e,
        else => unreachable,
    };
    errdefer args.deinit();

    if (diagnostics.errors.items.len > 0) {
        switch (diagnostics.errors.items[0]) {
            .unknown_option => |err| {
                if (mem.eql(u8, err.option, "help")) {
                    std.debug.print(cli.help, .{});
                    return error.Exit;
                }
                logger.println("unrecognized option '{s}{s}'", .{ if (err.option.len == 1) "-" else "--", err.option });
            },
            .unexpected_argument => |err| {
                logger.println("zwad: option '--{s}' doesn't allow an argument", .{err.option});
            },
            .empty_argument => |err| {
                logger.println("zwad: option '{s}{s}' requires an argument", .{ if (err.option.len == 1) "-" else "--", err.option });
            },
            .missing_operation => {
                logger.println("zwad: You must specify one of the '-ctx' options", .{});
            },
            .multiple_operations => {
                logger.println("zwad: You may not specify more than one '-ctx' option", .{});
            },
        }
        return error.Usage;
    }

    return args;
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
