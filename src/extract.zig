const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const mapping = @import("mapping.zig");
const wad = @import("wad.zig");
const hashes = @import("hashes.zig");
const handled = @import("handled.zig");
const Options = @import("cli.zig").Options;
const logger = @import("logger.zig");
const magic = @import("/magic.zig");
const castedReader = @import("casted_reader.zig").castedReader;
const fs = std.fs;
const io = std.io;
const HandleError = handled.HandleError;
const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

pub fn extract(allocator: Allocator, options: Options, files: []const []const u8) HandleError!void {
    const Error = fs.File.Reader.Error || error{EndOfStream};

    if (options.directory == null) {
        for (files) |file| {
            std.debug.print("file: {s}\n", .{file});
        }
        // idea is simple
        // hash these file names and sort them
        // loop trough entries, when then sort our needed data offset
        // read till we hit it and then just save it
        @panic("not implemented");
    }

    var out_dir = fs.cwd().openDir(options.directory.?, .{}) catch |err| {
        logger.println("{s}: Cannot open: {s}", .{ options.directory.?, errors.stringify(err) });
        return handled.fatal(err);
    };
    defer out_dir.close();

    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            logger.println("Refusing to read archive contents from terminal (missing -f option?)", .{});
            return error.Fatal;
        }

        // buffered reader would be nice for header, but for body, not rly
        // window_buffer is like buffered reader
        try extractAll(allocator, castedReader(Error, stdin), options);
        return;
    }

    const file_map = try handled.map(fs.cwd(), options.file.?, .{});
    defer file_map.deinit();

    var fbs = io.fixedBufferStream(file_map.view);
    try extractAll(allocator, castedReader(Error, &fbs), options);
}

// how anytype works it just makes two huge extract all functions, i think we can reduce it to just one call
// i verified this with ida, using any reader would be nice, but it has anyerror so not that good, then using any reader our bundle goes down by 30kb
fn extractAll(allocator: Allocator, reader: anytype, options: Options) HandleError!void {
    const stdout = std.io.getStdOut();
    var bw = io.BufferedWriter(1024, fs.File.Writer){ .unbuffered_writer = stdout.writer() };

    const writer = bw.writer();

    var out_dir = fs.cwd().openDir(options.directory.?, .{}) catch |err| {
        logger.println("{s}: Cannot open: {s}", .{ options.directory.?, errors.stringify(err) });
        return handled.fatal(err);
    };
    defer out_dir.close();

    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;

    var path_buf: [21]u8 = undefined;
    var path: []const u8 = undefined;

    var window_buf: [1 << 17]u8 = undefined;
    var iter = wad.streamIterator(allocator, reader, .{
        .handle_duplicates = false,
        .window_buffer = &window_buf,
    }) catch |err| {
        switch (err) {
            error.InvalidFile, error.EndOfStream => logger.println("This does not look like a wad archive", .{}),
            error.Unexpected => logger.println("Unknown error has occurred while extracting this archive", .{}),
            error.UnknownVersion => return error.Outdated,
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| logger.println("{s}", .{errors.stringify(e)}),
        }
        return handled.fatal(err);
    };
    defer iter.deinit();

    while (iter.next()) |mb| {
        const entry = mb orelse break;
        if (entry.duplicate()) {
            var new_path_buf: [21]u8 = undefined;
            var new_path: []const u8 = undefined;

            if (game_hashes) |h| {
                new_path = h.get(entry.hash) catch {
                    logger.println("This hashes file seems to be corrupted", .{});
                    return error.Fatal;
                } orelse std.fmt.bufPrint(&new_path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
            } else {
                new_path = std.fmt.bufPrint(&new_path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
            }

            copyFile(out_dir, path, out_dir, new_path, .{}) catch |err| {
                bw.flush() catch return;
                logger.println("{s}: Cannot copy '{s}': {s}", .{ new_path, path, errors.stringify(err) });
                return handled.fatal(err);
            };

            if (options.verbose) {
                writer.print("{s}\n", .{new_path}) catch return;
            }
            continue;
        }

        if (game_hashes) |h| {
            path = h.get(entry.hash) catch {
                logger.println("This hashes file seems to be corrupted", .{});
                return error.Fatal;
            } orelse std.fmt.bufPrint(&path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
        } else {
            path = std.fmt.bufPrint(&path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
        }

        if (writeFile(path, entry.reader(), .{ .dir = out_dir, .size = entry.decompressed_len })) |diagnostics| blk: {
            bw.flush() catch return;
            if (diagnostics == .make) switch (diagnostics.make) {
                error.NameTooLong, error.BadPathName => {
                    logger.println("{s}: Cannot make: {s}", .{ path, errors.stringify(diagnostics.make) });
                    path = std.fmt.bufPrint(&path_buf, "_inv/{x:0>16}", .{entry.hash}) catch unreachable;

                    if (writeFile(path, entry.reader(), .{ .dir = out_dir, .size = entry.decompressed_len })) |diag| {
                        return diag.handle(path);
                    } else {
                        break :blk;
                    }
                },
                else => {},
            };
            return diagnostics.handle(path);
        }

        if (options.verbose) {
            writer.print("{s}\n", .{path}) catch return;
        }
    } else |err| {
        bw.flush() catch return;
        switch (err) {
            error.InvalidFile => logger.println("This archive seems to be corrupted", .{}),
            error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
            else => |e| logger.println("{s}", .{errors.stringify(e)}),
        }
        return handled.fatal(err);
    }

    bw.flush() catch return;
}

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
            Unseekable,
            Unexpected,
        },
        read: (error{EndOfStream} || ReaderType.Error),
        write: error{
            Unexpected,
            AccessDenied,
            InputOutput,
            SystemResources,
            OperationAborted,
            BrokenPipe,
            ConnectionResetByPeer,
            WouldBlock,
            DeviceBusy,
            FileTooBig,
            NoSpaceLeft,
            DiskQuota,
            NotOpenForWriting,
        },

        fn handle(self: @This(), path: []const u8) HandleError {
            switch (self) {
                .make => |err| {
                    logger.println("{s}: Cannot make: {s}", .{ path, errors.stringify(err) });
                    return handled.fatal(err);
                },
                .map => |err| {
                    logger.println("{s}: Cannot map: {s}", .{ path, errors.stringify(err) });
                    return handled.fatal(err);
                },
                .read => |err| {
                    switch (err) {
                        error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
                        error.MalformedFrame, error.MalformedBlock => logger.println("This archive seems to be corrupted", .{}),
                        error.Unexpected => logger.println("Unknown error has occurred while extracting this archive", .{}),
                        else => |e| logger.println("{s}", .{errors.stringify(e)}),
                    }
                    return handled.fatal(err);
                },
                .write => |err| {
                    logger.println("{s}: Cannot write: {s}", .{ path, errors.stringify(err) });
                    return handled.fatal(err);
                },
            }
        }
    };
}

const WriteOptions = struct {
    dir: ?fs.Dir = null,
    size: u32,
};

fn writeFile(sub_path: []const u8, reader: anytype, options: WriteOptions) ?DiagnosticsError(@TypeOf(reader)) {
    if (is_windows) {
        return writeFileW(sub_path, reader, options);
    }

    const file = makeFile(options.dir orelse fs.cwd(), sub_path) catch |err| return .{ .make = err };
    defer file.close();

    // on linux this is just faster
    var amt: u32 = 0;
    var buf: [16 * 1024]u8 = undefined;
    while (options.size > amt) {
        const slice = buf[0..@min(buf.len, options.size - amt)];
        reader.readNoEof(slice) catch |err| return .{ .read = err };
        amt += @intCast(slice.len);

        file.writeAll(slice) catch |err| return switch (err) {
            error.LockViolation => unreachable, //  no lock
            error.InvalidArgument => unreachable,
            else => |e| .{ .write = e },
        };
    }

    return null;
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

pub fn copyFile(source_dir: fs.Dir, source_path: []const u8, dest_dir: fs.Dir, dest_path: []const u8, options: fs.Dir.CopyFileOptions) !void {
    source_dir.copyFile(source_path, dest_dir, dest_path, options) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (fs.path.dirname(dest_path)) |sub_dir| {
                    try dest_dir.makePath(sub_dir);
                    return source_dir.copyFile(source_path, dest_dir, dest_path, options) catch |e| switch (e) {
                        error.OutOfMemory => error.SystemResources,
                        error.PermissionDenied => return error.AccessDenied,
                        error.InvalidArgument => unreachable,
                        error.LockViolation, error.FileLocksNotSupported => unreachable,
                        error.FileDescriptorNotASocket, error.MessageTooBig, error.NetworkUnreachable, error.NetworkSubsystemFailed => unreachable,
                        else => |x| x,
                    };
                }
                return error.FileNotFound;
            },
            error.OutOfMemory => return error.SystemResources,
            error.PermissionDenied => return error.AccessDenied,
            error.InvalidArgument, error.FileLocksNotSupported => unreachable, // i think zig should handle this before hand
            error.LockViolation => unreachable, // idk why zig left this error
            error.FileDescriptorNotASocket, error.MessageTooBig, error.NetworkUnreachable, error.NetworkSubsystemFailed => unreachable, // Not doing any networking
            else => |e| return e,
        }
    };
}
