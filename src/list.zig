const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const mapping = @import("mapping.zig");
const wad = @import("wad.zig");
const hashes = @import("hashes.zig");
const handled = @import("handled.zig");
const Options = @import("cli.zig").Options;
const logger = @import("logger.zig");
const castedReader = @import("casted_reader.zig").castedReader;
const fs = std.fs;
const io = std.io;
const HandleError = handled.HandleError;

pub fn list(options: Options) HandleError!void {
    const Error = fs.File.Reader.Error || error{EndOfStream};

    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            logger.println("Refusing to read archive contents from terminal (missing -f option?)", .{});
            return error.Fatal;
        }

        // todo: when zig fixed its unreachable prongs we should be able to not do this weird stuff
        var br = io.bufferedReader(castedReader(Error, stdin));
        //var br = io.bufferedReader(stdin.reader());
        try _list(br.reader(), options);
        return;
    }

    const file_map = try handled.map(fs.cwd(), options.file.?, .{});
    defer file_map.deinit();

    var fbs = io.fixedBufferStream(file_map.view);
    try _list(castedReader(Error, &fbs), options);
    //try _list(fbs.reader(), options);
}

fn _list(reader: anytype, options: Options) HandleError!void {
    const stdout = std.io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;

    var iter = wad.header.headerIterator(reader) catch |err| return switch (err) {
        error.InvalidFile, error.EndOfStream => {
            logger.println("This does not look like a wad archive", .{});
            return error.Fatal;
        },
        error.UnknownVersion => error.Outdated,
        else => |e| {
            logger.println("Unexpected read error: {s}", .{errors.stringify(e)});
            return handled.fatal(e);
        },
    };

    while (iter.next()) |me| {
        const entry = me orelse break;
        const path = if (game_hashes) |h| h.get(entry.hash) catch {
            logger.println("This hashes file seems to be corrupted", .{});
            return error.Fatal;
        } else null;

        if (path) |p| {
            writer.print("{s}\n", .{p}) catch return;
            continue;
        }

        writer.print("{x:0>16}\n", .{entry.hash}) catch return;
    } else |err| {
        bw.flush() catch return;
        switch (err) {
            error.InvalidFile => logger.println("This archive seems to be corrupted", .{}),
            error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
            else => |e| logger.println("Unexpected read error: {s}", .{errors.stringify(e)}),
        }
        return handled.fatal(err);
    }

    bw.flush() catch return;
}
