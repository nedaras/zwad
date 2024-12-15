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

    var window_buf: [1 << 17]u8 = undefined;
    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            logger.println("Refusing to read archive contents from terminal (missing -f option?)", .{});
            return error.Fatal;
        }

        var br = io.bufferedReader(stdin.reader());
        var iter = wad.streamIterator(allocator, br.reader(), &window_buf) catch |err| {
            logger.println("{s}", .{@errorName(err)});
            return error.Fatal;
        };
        defer iter.deinit();

        while (iter.next() catch |err| {
            logger.println("{s}", .{@errorName(err)});
            return error.Fatal;
        }) |entry| {
            switch (entry.decompressor) {
                .zstd => |zstd_stream| {
                    var amt: usize = 0;
                    while (entry.decompressed_len > amt) {
                        var buf: [4096]u8 = undefined;
                        const len = zstd_stream.readAll(&buf) catch |err| {
                            logger.println("{s}", .{@errorName(err)});
                            return error.Fatal;
                        };
                        amt += len;
                    }
                    if (entry.decompressed_len != amt) {
                        @panic("not same lens");
                    }
                },
                .none => |stream| {
                    std.debug.print("RAWWW\n", .{});
                    stream.skipBytes(entry.compressed_len, .{}) catch unreachable;
                },
            }
        }

        return;
    }
    @panic("not implemented");
}
