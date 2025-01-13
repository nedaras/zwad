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

    const final = try game_hashes.final();

    std.debug.print("writting to file: {d}\n", .{final.len});
    try out_file.writeAll(final);
}

pub fn _main() !void {
    //checksums: 3, subchunk_inex: 15971 compressed: 19913
    //assets/maps/particles/tft/booms/chibi_yuumi/yuumi_base_boom_trail_01.tft_booms_yuumi_base.tex

    // 6525dbd92e8d3c77

    // we need to find a way to make these checksums seemless
    // these checksums do only accure on .tex file but it does not matter
    // we need to make a way that if we decompress all file and change some checksumed files
    // at the end it still should have checksums we need a way to see if file should be made using subchunks
    // i think smth like one checksum for every 3 bitmaps

    // until 7 bitmaps no checksums
    // and after just add and add checksums

    // there is no direct way to identify checksum file

    const file = try fs.cwd().openFile("Global.wad.client", .{});
    defer file.close();

    var hash = @import("xxhash.zig").XxHash64.init(0);
    var before_checksum: [@sizeOf(toc.Version) + 256]u8 = undefined;

    try file.reader().readNoEof(&before_checksum);

    hash.update(&before_checksum);

    //for (0..header.entries_len) |_| {
    //const entry = try file.reader().readStruct(toc.Entry.v3_4);
    //const a: [8]u8 = @bitCast(entry.checksum);
    //hash.update(&a);
    //}

    try file.reader().skipBytes(8, .{});

    while (true) {
        var buf: [1024 * 4]u8 = undefined;
        const amt = try file.read(&buf);
        if (amt == 0) break;

        hash.update(buf[0..amt]);
    }

    std.debug.print("mysum: {x}\n", .{hash.final()});
}

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
    // should we add logger?
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

const toc = @import("wad/toc.zig");

// commentded out are those who failed
test "finding checksum from block xxhash64" {
    var xxhash64 = @import("xxhash.zig").XxHash64.init(0);
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashBlock("Global.wad.client", &xxhash64));
}

test "finding checksum from block xxhash3" {
    var xxhash3 = @import("xxhash.zig").XxHash3(64).init();
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashBlock("Global.wad.client", &xxhash3));
}

test "finding checksum from entries xxhash64" {
    var xxhash64 = @import("xxhash.zig").XxHash64.init(0);
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashEntries("Global.wad.client", &xxhash64));
}

test "finding checksum from entries xxhash3" {
    var xxhash3 = @import("xxhash.zig").XxHash3(64).init();
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashEntries("Global.wad.client", &xxhash3));
}

test "finding checksum from decompressed xxhash64" {
    var xxhash64 = @import("xxhash.zig").XxHash64.init(0);
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashDecompressed("Global.wad.client", &xxhash64));
}

test "finding checksum from decompressed xxhash3" {
    var xxhash3 = @import("xxhash.zig").XxHash3(64).init();
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashDecompressed("Global.wad.client", &xxhash3));
}

test "finding checksum from entry checksum xxhash64" {
    var xxhash64 = @import("xxhash.zig").XxHash64.init(0);
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashEntryChecksums("Global.wad.client", &xxhash64));
}

test "finding checksum from entry checksums xxhash3" {
    var xxhash3 = @import("xxhash.zig").XxHash3(64).init();
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashEntryChecksums("Global.wad.client", &xxhash3));
}

test "finding checksum from whole except ver and checksum xxhash64" {
    var xxhash64 = @import("xxhash.zig").XxHash64.init(0);
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashWholeExceptVersioAndSubchunk("Global.wad.client", &xxhash64));
}

test "finding checksum from whole except ver and checksum xxhash3" {
    var xxhash3 = @import("xxhash.zig").XxHash3(64).init();
    try std.testing.expectEqual(0x6525dbd92e8d3c77, try hashWholeExceptVersioAndSubchunk("Global.wad.client", &xxhash3));
}

fn hashBlock(sub_path: []const u8, hasher: anytype) !u64 {
    const file = try fs.cwd().openFile(sub_path, .{});
    defer file.close();

    try file.seekBy(@sizeOf(toc.Version));
    const header = try file.reader().readStruct(toc.LatestHeader);

    try file.seekBy(header.entries_len * @sizeOf(toc.LatestEntry));

    while (true) {
        var buf: [1 << 17]u8 = undefined;
        const amt = try file.read(&buf);
        if (amt == 0) break;

        hasher.update(buf[0..amt]);
    }

    return hasher.final();
}

fn hashEntries(sub_path: []const u8, hasher: anytype) !u64 {
    const file = try fs.cwd().openFile(sub_path, .{});
    defer file.close();

    try file.seekBy(@sizeOf(toc.Version));
    const header = try file.reader().readStruct(toc.LatestHeader);

    var read_len: u64 = header.entries_len * @sizeOf(toc.LatestEntry);
    while (true) {
        var buf: [1 << 17]u8 = undefined;
        const amt = try file.read(buf[0..@min(buf.len, read_len)]);
        if (amt == 0) break;
        read_len -= amt;

        hasher.update(buf[0..amt]);
    }

    return hasher.final();
}

fn hashDecompressed(sub_path: []const u8, hasher: anytype) !u64 {
    const file = try fs.cwd().openFile(sub_path, .{});
    defer file.close();

    try file.seekBy(@sizeOf(toc.Version));
    const header = try file.reader().readStruct(toc.LatestHeader);

    var window_buf: [1 << 17]u8 = undefined;
    var buf: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.zstd.decompressor(std.testing.allocator, file.reader(), .{ .window_buffer = &window_buf });
    defer zstd_stream.deinit();

    for (0..header.entries_len) |_| {
        const entry = try file.reader().readStruct(toc.LatestEntry);
        const pos = try file.getPos();

        try file.seekTo(entry.offset);

        zstd_stream.unread_bytes = entry.compressed_len;
        zstd_stream.available_bytes = entry.decompressed_len;

        switch (entry.entry_type) {
            .raw => {
                var read_len = entry.decompressed_len;
                while (read_len != 0) {
                    const amt = try file.read(buf[0..@min(buf.len, read_len)]);
                    if (amt == 0) break;
                    read_len -= @intCast(amt);
                    hasher.update(buf[0..amt]);
                }
            },
            .zstd, .zstd_multi => {
                while (true) {
                    const amt = try zstd_stream.read(&buf);
                    if (amt == 0) break;
                    hasher.update(buf[0..amt]);
                }
            },
            else => @panic("no"),
        }
        try file.seekTo(pos);
    }

    return hasher.final();
}

fn hashEntryChecksums(sub_path: []const u8, hasher: anytype) !u64 {
    const file = try fs.cwd().openFile(sub_path, .{});
    defer file.close();

    try file.seekBy(@sizeOf(toc.Version));
    const header = try file.reader().readStruct(toc.LatestHeader);

    for (0..header.entries_len) |_| {
        const entry = try file.reader().readStruct(toc.LatestEntry);
        const bytes: [8]u8 = @bitCast(entry.checksum);

        hasher.update(&bytes);
    }

    return hasher.final();
}

fn hashWholeExceptVersioAndSubchunk(sub_path: []const u8, hasher: anytype) !u64 {
    const file = try fs.cwd().openFile(sub_path, .{});
    defer file.close();

    try file.seekBy(@sizeOf(toc.Version));
    var signature: [256]u8 = undefined;
    var entries_len: [4]u8 = undefined;

    try file.reader().readNoEof(&signature);
    try file.reader().skipBytes(8, .{});
    try file.reader().readNoEof(&entries_len);

    hasher.update(&signature);
    hasher.update(&entries_len);

    while (true) {
        var buf: [1 << 17]u8 = undefined;
        const amt = try file.read(&buf);
        if (amt == 0) break;

        hasher.update(buf[0..amt]);
    }

    return hasher.final();
}
