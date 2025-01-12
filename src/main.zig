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
    //subchunks: 3, subchunk_inex: 15971 compressed: 19913
    //assets/maps/particles/tft/booms/chibi_yuumi/yuumi_base_boom_trail_01.tft_booms_yuumi_base.tex

    const file = try fs.cwd().openFile("out/data/final/global.wad.subchunktoc", .{});
    defer file.close();

    try file.reader().skipBytes(15971 * 16, .{});

    const Subchunk = extern struct {
        compressed: u32,
        decompressed: u32,
        checksum: u64,
    };

    for (0..3) |_| {
        const s = try file.reader().readStruct(Subchunk);
        std.debug.print("{}\n", .{s});
    }
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
