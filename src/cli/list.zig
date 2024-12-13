const std = @import("std");
const builtin = @import("builtin");
const errors = @import("../errors.zig");
const mapping = @import("../mapping.zig");
const wad = @import("../wad.zig");
const hashes = @import("../hashes.zig");
const handled = @import("../handled.zig");
const Options = @import("../cli.zig").Options;
const fs = std.fs;
const io = std.io;
const HandleError = handled.HandleError;
const is_windows = builtin.os.tag == .windows;

pub fn list(options: Options) HandleError!void {
    const stdout = std.io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;

    if (options.file == null) {
        if (is_windows) @panic("not implemented on windows");

        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            std.debug.print("zwad: Refusing to read archive contents from terminal (missing -f option?)\n", .{});
            return error.Fatal;
        }

        var br = io.bufferedReader(stdin.reader());
        var iter = wad.header.headerIterator(br.reader()) catch |err| return switch (err) {
            error.InvalidFile, error.EndOfStream => {
                std.debug.print("zwad: This does not look like a wad archive\n", .{});
                return error.Fatal;
            },
            error.UnknownVersion => error.Outdated,
            else => |e| {
                std.debug.print("zwad: {s}\n", .{errors.stringify(e)});
                return if (e == error.Unexpected) error.Unexpected else error.Fatal;
            },
        };

        while (iter.next() catch |err| {
            switch (err) {
                error.InvalidFile => std.debug.print("zwad: This wad archive seems to be corrupted\n", .{}),
                error.EndOfStream => std.debug.print("zwad: Unexpected EOF in archive\n", .{}),
                else => |e| {
                    std.debug.print("zwad: {s}\n", .{errors.stringify(e)});
                    return if (e == error.Unexpected) error.Unexpected else error.Fatal;
                },
            }
            return error.Fatal;
        }) |entry| {
            const path = if (game_hashes) |h| h.get(entry.hash) catch {
                std.debug.print("zwad: This hashes file seems to be corrupted\n", .{});
                return error.Fatal;
            } else null;
            if (path) |p| {
                writer.print("{s}\n", .{p}) catch return;
                continue;
            }
            writer.print("{x:0>16}\n", .{entry.hash}) catch return;
        }

        bw.flush() catch {};

        return;
    }

    const file_map = try handled.map(fs.cwd(), options.file.?, .{});
    defer file_map.deinit();

    var fbs = io.fixedBufferStream(file_map.view);
    var iter = wad.header.headerIterator(fbs.reader()) catch |err| return switch (err) {
        error.InvalidFile, error.EndOfStream => {
            std.debug.print("zwad: This does not look like a wad archive\n", .{});
            return error.Fatal;
        },
        error.UnknownVersion => error.Outdated,
    };

    while (iter.next() catch |err| {
        switch (err) {
            error.InvalidFile => std.debug.print("zwad: This wad archive seems to be corrupted\n", .{}),
            error.EndOfStream => std.debug.print("zwad: Unexpected EOF in archive\n", .{}),
        }
        return error.Fatal;
    }) |entry| {
        const path = if (game_hashes) |h| h.get(entry.hash) catch {
            std.debug.print("zwad: This hashes file seems to be corrupted\n", .{});
            return error.Fatal;
        } else null;
        if (path) |p| {
            writer.print("{s}\n", .{p}) catch return;
            continue;
        }
        writer.print("{x:0>16}\n", .{entry.hash}) catch return;
    }

    bw.flush() catch {};
}
