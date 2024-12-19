const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../errors.zig");
const mapping = @import("../mapping.zig");
const wad = @import("../wad.zig");
const hashes = @import("../hashes.zig");
const handled = @import("../handled.zig");
const Options = @import("../cli.zig").Options;
const logger = @import("../logger.zig");
const fs = std.fs;
const io = std.io;
const HandleError = handled.HandleError;
const Allocator = std.mem.Allocator;

pub fn extract(allocator: Allocator, options: Options) !void {
    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    //const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;

    const stdout = std.io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    var out_dir = try fs.cwd().makeOpenPath("out", .{});
    defer out_dir.close();

    var window_buf: [1 << 17]u8 = undefined;
    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            logger.println("Refusing to read archive contents from terminal (missing -f option?)", .{});
            return error.Fatal;
        }

        var br = io.bufferedReader(stdin.reader());
        var iter = try wad.streamIterator(allocator, br.reader(), .{
            .handle_duplicates = false,
            .window_buffer = &window_buf,
        });
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (entry.duplicate()) {
                continue;
            }

            writer.print("{x}.dds", .{entry.hash}) catch return;

            var buf: [256]u8 = undefined;
            const file_name = try std.fmt.bufPrint(&buf, "{x}.dds\n", .{entry.hash});
            const out_file = try out_dir.createFile(file_name, .{ .read = true });
            defer out_file.close();

            const map = try mapping.mapFile(out_file, .{ .mode = .write_only, .size = entry.decompressed_len });
            defer map.unmap();

            var amt: usize = 0;
            while (entry.decompressed_len > amt) { // fix this stuff
                const len = try entry.read(map.view[amt..]);
                amt += len;
            }
            if (entry.decompressed_len != amt) {
                std.debug.print("len: {d} ", .{amt});
                @panic("not same lens");
            }
        }

        bw.flush() catch return;

        return;
    }

    const file = try fs.cwd().openFile(options.file.?, .{ .mode = .read_only });
    defer file.close();

    var br = io.bufferedReader(file.reader());
    var iter = try wad.streamIterator(allocator, br.reader(), .{
        .handle_duplicates = false,
        .window_buffer = &window_buf,
    });
    defer iter.deinit();

    while (try iter.next()) |entry| {
        if (entry.duplicate()) {
            continue;
        }

        writer.print("{x}.dds\n", .{entry.hash}) catch return;

        var buf: [256]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&buf, "{x}.dds", .{entry.hash});
        const out_file = try out_dir.createFile(file_name, .{ .read = true });
        defer out_file.close();

        const map = try mapping.mapFile(out_file, .{ .mode = .write_only, .size = entry.decompressed_len });
        defer map.unmap();

        var amt: usize = 0;
        while (entry.decompressed_len > amt) { // fix this stuff
            const len = try entry.read(map.view[amt..]);
            amt += len;
        }
        if (entry.decompressed_len != amt) {
            std.debug.print("len: {d} ", .{amt});
            @panic("not same lens");
        }
    }

    bw.flush() catch return;

    // when reading for mmap file, we should read it from steam iter, unless if multithreading is used
    // mb would be nice to, like err if reading stdin after extraction is not empty
}
