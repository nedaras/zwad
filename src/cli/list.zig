const std = @import("std");
const errors = @import("../errors.zig");
const mapping = @import("../mapping.zig");
const wad = @import("../wad.zig");
const hashes = @import("../hashes.zig");
const handled = @import("../handled.zig");
const Options = @import("../cli.zig").Options;
const fs = std.fs;
const io = std.io;
const Allocator = std.mem.Allocator;
const HandleError = handled.HandleError;

pub fn list(allocator: Allocator, options: Options) HandleError!void {
    const src = options.file orelse @panic("not implemented"); // we rly should start working on linux

    const file_map = try handled.map(fs.cwd(), src, .{});
    defer file_map.deinit();

    var fbs = io.fixedBufferStream(file_map.view);

    var iter = wad.iterator(allocator, fbs.reader(), fbs.seekableStream(), undefined) catch |err| return switch (err) {
        error.Corrupted => {
            std.debug.print("zwad: This does not look like a wad archive\n", .{});
            return error.Fatal;
        },
        error.InvalidVersion => error.Outdated,
        else => |e| e,
    };
    defer iter.deinit();

    const stdout = std.io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    // todo: add verbose option
    if (options.hashes) |h| {
        const hashes_map = try handled.map(fs.cwd(), h, .{});
        defer hashes_map.deinit();

        // add magic to hashes file
        const game_hashes = hashes.decompressor(hashes_map.view);

        while (iter.next() catch {
            std.debug.print("zwad: This wad archive seems to be corrupted\n", .{});
            return error.Fatal;
        }) |entry| {
            if (game_hashes.get(entry.hash) catch {
                std.debug.print("zwad: This hashes file seems to be corrupted\n", .{});
                return error.Fatal;
            }) |path| {
                writer.print("{s}\n", .{path}) catch return;
                continue;
            }
            writer.print("{x:0>16}\n", .{entry.hash}) catch return;
        }
        bw.flush() catch return;
        return;
    }

    while (iter.next() catch {
        std.debug.print("zwad: This wad archive seems to be corrupted\n", .{});
        return error.Fatal;
    }) |entry| {
        writer.print("{x:0>16}\n", .{entry.hash}) catch return;
    }

    bw.flush() catch return;
}
