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

pub fn extract(allocator: Allocator, options: Options) HandleError!void {
    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    //const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;

    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            logger.println("Refusing to read archive contents from terminal (missing -f option?)", .{});
            return error.Fatal;
        }

        var br = io.bufferedReader(stdin.reader());
        var iter = wad.iterator(allocator, br.reader()) catch |err| {
            logger.println("{s}", .{@errorName(err)});
            return error.Fatal;
        };
        defer iter.deinit();

        while (iter.next() catch |err| {
            logger.println("{s}", .{@errorName(err)});
            return error.Fatal;
        }) |offset| {
            _ = offset;
            //logger.println("{d}", .{offset});
        }

        return;
    }
    @panic("not implemented");
}
