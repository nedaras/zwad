const std = @import("std");
const errors = @import("../errors.zig");
const mapping = @import("../mapping.zig");
const wad = @import("../wad.zig");
const hashes = @import("../hashes.zig");
const Options = @import("../cli.zig").Options;
const HandleError = errors.HandleError;
const fs = std.fs;
const io = std.io;
const Allocator = std.mem.Allocator;

// todo: add like some handled util functions
pub fn list(allocator: Allocator, options: Options) HandleError!void {
    const src = options.file orelse @panic("not implemented"); // we rly should start working on linux

    const file = fs.cwd().openFile(src, .{}) catch |err| return switch (err) {
        error.FileBusy => unreachable, // read-only
        error.NoSpaceLeft => unreachable, // read-only
        error.PathAlreadyExists => unreachable, // read-only
        error.WouldBlock => unreachable, // not using O_NONBLOCK
        error.FileLocksNotSupported => unreachable, // no lock requested
        error.NotDir => unreachable, // should not err
        else => |e| {
            std.debug.print("zwad: {s}: Cannot open: {s}\n", .{ src, errors.stringify(e) });
            return if (e == error.Unexpected) error.Unexpected else error.Fatal;
        },
    };
    defer file.close();

    const file_map = mapping.mapFile(file, .{}) catch |err| return switch (err) {
        error.NoSpaceLeft => unreachable, // not using size
        else => |e| {
            std.debug.print("zwad: {s}: Cannot map: {s}\n", .{ src, errors.stringify(e) });
            return if (e == error.Unexpected) error.Unexpected else error.Fatal;
        },
    };
    defer file_map.unmap();

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
        const hashes_file = fs.cwd().openFile(h, .{}) catch |err| return switch (err) {
            error.FileBusy => unreachable, // read-only
            error.NoSpaceLeft => unreachable, // read-only
            error.PathAlreadyExists => unreachable, // read-only
            error.WouldBlock => unreachable, // not using O_NONBLOCK
            error.FileLocksNotSupported => unreachable, // no lock requested
            error.NotDir => unreachable, // prob will not err
            else => |e| {
                std.debug.print("zwad: {s}: Cannot open: {s}\n", .{ src, errors.stringify(e) });
                return if (e == error.Unexpected) error.Unexpected else error.Fatal;
            },
        };
        defer hashes_file.close();

        const hashes_map = mapping.mapFile(hashes_file, .{}) catch |err| return switch (err) {
            error.NoSpaceLeft => unreachable, // not using size
            else => |e| {
                std.debug.print("zwad: {s}: Cannot map: {s}\n", .{ src, errors.stringify(e) });
                return if (e == error.Unexpected) error.Unexpected else error.Fatal;
            },
        };
        defer hashes_map.unmap();

        // add magic to hashes file
        const game_hashes = hashes.decompressor(hashes_map.view);

        while (iter.next() catch {
            std.debug.print("zwad: This wad archive seems to be corrupted\n", .{});
            return error.Fatal;
        }) |entry| {
            if (game_hashes.get(entry.hash)) |path| {
                writer.print("{s}\n", .{path}) catch return;
                continue;
            }
            writer.print("{d:0>16}\n", .{entry.hash}) catch return;
        }
    }

    while (iter.next() catch {
        std.debug.print("zwad: This wad archive seems to be corrupted\n", .{});
        return error.Fatal;
    }) |entry| {
        writer.print("{d:0>16}\n", .{entry.hash}) catch return;
    }

    bw.flush() catch return;
}
