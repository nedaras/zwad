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

            // mmapping on linux seems to be rly fucking slow
            std.debug.print("{x}.txt\n", .{entry.hash});

            var buf: [256]u8 = undefined;
            const file_name = try std.fmt.bufPrint(&buf, "{x}.txt", .{entry.hash});

            const out_file = try out_dir.createFile(file_name, .{ .read = true });
            defer out_file.close();

            var amt: usize = 0;
            var write_buf: [16 * 1024]u8 = undefined;
            while (true) {
                amt += try entry.read(&write_buf);
                if (amt == 0) break;
                try out_file.writeAll(write_buf[0..amt]);
            }

            std.debug.assert(amt == entry.decompressed_len);

            //try out_file.setEndPos(file_name.len + 1);

            //const map = try mapping.mapFile(out_file, .{ .mode = .read_write, .size = file_name.len });
            //defer map.unmap();
            //const map = try std.posix.mmap(null, file_name.len + 1, std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, out_file.handle, 0);
            //defer std.posix.munmap(map);

            //@memcpy(map[0 .. map.len - 1], file_name);
            //map[file_name.len] = '\n';

            //try std.posix.msync(map, std.posix.MSF.SYNC);
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

    var prev_path_buf: [256]u8 = undefined;
    var prev_path: []u8 = &prev_path_buf;

    while (try iter.next()) |entry| {
        var buf: [256]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&buf, "{x}.dds", .{entry.hash});

        writer.print("{x}.dds\n", .{entry.hash}) catch return;

        if (entry.duplicate()) {
            try out_dir.copyFile(prev_path, out_dir, file_name, .{});
            continue;
        }

        prev_path.len = file_name.len;
        @memcpy(prev_path, file_name);

        const out_file = try out_dir.createFile(file_name, .{ .read = true });
        defer out_file.close();

        const mmap = try mapping.mapFileW(out_file, .{ .mode = .write_only, .size = entry.decompressed_len });
        defer mmap.unmap();

        try entry.reader().readNoEof(mmap.view);
    }

    bw.flush() catch return;

    // when reading for mmap file, we should read it from steam iter, unless if multithreading is used
    // mb would be nice to, like err if reading stdin after extraction is not empty
}
