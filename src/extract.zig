const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const mapping = @import("mapping.zig");
const wad = @import("wad.zig");
const hashes = @import("hashes.zig");
const handled = @import("handled.zig");
const Options = @import("cli.zig").Options;
const logger = @import("logger.zig");
const magic = @import("magic.zig");
const fs = std.fs;
const io = std.io;
const HandleError = handled.HandleError;
const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

pub fn extract(allocator: Allocator, options: Options) !void {
    const stdout = std.io.getStdOut();
    var bw = io.BufferedWriter(1024, fs.File.Writer){
        .unbuffered_writer = stdout.writer(),
    };

    const writer = bw.writer();

    var out_dir = try fs.cwd().makeOpenPath("out", .{});
    defer out_dir.close();

    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;

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

            // mmapping on linux seems to be rly fucking sloe
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

    // add a check for of empty dir

    const file_map = try handled.map(out_dir, options.file.?, .{});
    defer file_map.deinit();

    var fbs = io.fixedBufferStream(file_map.view);
    var iter = try wad.streamIterator(allocator, fbs.reader(), .{
        .handle_duplicates = false,
        .window_buffer = &window_buf,
    });
    defer iter.deinit();

    var path_buf: [21]u8 = undefined;
    var path: []const u8 = undefined;

    while (try iter.next()) |entry| {
        if (entry.duplicate()) {
            var new_path_buf: [21]u8 = undefined;
            var new_path: []const u8 = undefined;

            if (game_hashes) |h| {
                new_path = try h.get(entry.hash) orelse std.fmt.bufPrint(&new_path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
            } else {
                new_path = std.fmt.bufPrint(&new_path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
            }

            // move to handled
            out_dir.copyFile(path, out_dir, new_path, .{}) catch |err| blk: {
                bw.flush() catch return;
                switch (err) {
                    error.FileNotFound => {
                        if (fs.path.dirname(new_path)) |sub_dir| {
                            if (out_dir.makePath(sub_dir)) {
                                break :blk;
                            } else |e| {
                                logger.println("{s}: Cannot copy '{s}': {s}", .{ new_path, path, errors.stringify(e) });
                            }
                        }
                        logger.println("{s}: Cannot copy '{s}': {s}", .{ new_path, path, errors.stringify(error.FileNotFound) });
                    },
                    else => unreachable, //logger.println("{s}: cannot copy '{s}': {s}", .{ new_path, path, errors.stringify(e) }),
                }
                continue;
            };

            if (options.verbose) {
                writer.print("{s}\n", .{new_path}) catch return;
            }
            continue;
        }

        if (game_hashes) |h| {
            path = try h.get(entry.hash) orelse std.fmt.bufPrint(&path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
        } else {
            path = std.fmt.bufPrint(&path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
        }

        // move to a function or smth f this
        if (writeFile(path, entry.reader(), .{ .dir = out_dir, .size = entry.decompressed_len })) |diagnostics| blk: {
            bw.flush() catch return;
            switch (diagnostics) {
                .make => |err| switch (err) {
                    error.NameTooLong, error.BadPathName => {
                        logger.println("{s}: Cannot make: {s}", .{ path, errors.stringify(err) });
                        path = std.fmt.bufPrint(&path_buf, "_inv/{x:0>16}", .{entry.hash}) catch unreachable;

                        if (writeFile(path, entry.reader(), .{ .dir = out_dir, .size = entry.decompressed_len })) |diag| {
                            switch (diag) {
                                .make => |e| logger.println("{s}: Cannot make: {s}", .{ path, errors.stringify(e) }),
                                .map => |e| logger.println("{s}: Cannot map: {s}", .{ path, errors.stringify(e) }),
                                .read => |e| {
                                    switch (e) {
                                        error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
                                        error.MalformedFrame, error.MalformedBlock => logger.println("This archive seems to be corrupted", .{}),
                                        error.Unexpected => logger.println("Unknown error has occurred while extracting this archive", .{}),
                                    }
                                    return handled.fatal(e);
                                },
                            }
                        } else break :blk;
                    },
                    else => logger.println("{s}: Cannot make: {s}", .{ path, errors.stringify(err) }),
                },
                .map => |err| logger.println("{s}: Cannot map: {s}", .{ path, errors.stringify(err) }),
                .read => |err| {
                    switch (err) {
                        error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
                        error.MalformedFrame, error.MalformedBlock => logger.println("This archive seems to be corrupted", .{}),
                        error.Unexpected => logger.println("Unknown error has occurred while extracting this archive", .{}),
                    }
                    return handled.fatal(err);
                },
            }
            continue;
        }

        // If we're means that current `path` was written
        if (options.verbose) {
            writer.print("{s}\n", .{path}) catch return;
        }
    }

    bw.flush() catch return;
}

const WriteOptions = struct {
    dir: ?fs.Dir = null,
    size: u32,
};

fn DiagnosticsError(comptime ReaderType: type) type {
    return union(enum) {
        make: MakeFileError,
        map: error{
            AccessDenied,
            IsDir,
            SystemResources,
            SharingViolation,
            ProcessFdQuotaExceeded,
            SystemFdQuotaExceeded,
            NoSpaceLeft,
            Unexpected,
        },
        read: (error{EndOfStream} || ReaderType.Error),
    };
}

fn writeFile(sub_path: []const u8, reader: anytype, options: WriteOptions) ?DiagnosticsError(@TypeOf(reader)) {
    if (is_windows) {
        return writeFileW(sub_path, reader, options);
    }
    @compileError("not implemented for linux");
}

fn writeFileW(sub_path: []const u8, reader: anytype, options: WriteOptions) ?DiagnosticsError(@TypeOf(reader)) {
    // on windows mapping files is much faster then buffered writting
    const file = makeFile(options.dir orelse fs.cwd(), sub_path) catch |err| return .{ .make = err };
    defer file.close();

    if (options.size == 0) {
        @setCold(true);
        return null;
    }

    const map = mapping.mapFileW(file, .{ .mode = .write_only, .size = options.size }) catch |err| return switch (err) {
        error.LockedMemoryLimitExceeded => unreachable, // no lock requested
        error.InvalidSize => unreachable, // size will not be zero
        else => |e| .{ .map = e },
    };
    defer map.unmap();

    reader.readNoEof(map.view) catch |err| return .{ .read = err };

    return null;
}

const MakeFileError = fs.File.OpenError || fs.Dir.MakeError || fs.File.StatError;

pub fn makeFile(dir: fs.Dir, sub_path: []const u8) MakeFileError!fs.File {
    return dir.createFile(sub_path, .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound => {
            if (fs.path.dirname(sub_path)) |sub_dir| {
                try dir.makePath(sub_dir);
                return dir.createFile(sub_path, .{ .read = true });
            }
            return error.FileNotFound;
        },
        else => |e| return e,
    };
}
