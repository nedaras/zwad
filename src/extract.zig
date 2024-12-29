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
const xxhash = @import("xxhash.zig");
const compress = @import("compress.zig");
const castedReader = @import("casted_reader.zig").castedReader;
const fs = std.fs;
const io = std.io;
const HandleError = handled.HandleError;
const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;
const Entry = wad.header.Entry;
const assert = std.debug.assert;

pub fn extract(allocator: Allocator, options: Options, files: []const []const u8) !void {
    const Error = fs.File.Reader.Error || error{EndOfStream};

    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            logger.println("Refusing to read archive contents from terminal (missing -f option?)", .{});
            return error.Fatal;
        }

        // buffered reader would be nice for header, but for body, not rly
        // window_buffer is like buffered reader
        if (options.directory == null) {
            return extractSome(allocator, castedReader(Error, stdin), options, files);
        }
        try extractAll(allocator, castedReader(Error, stdin), options);
        return;
    }

    const file_map = try handled.map(fs.cwd(), options.file.?, .{});
    defer file_map.deinit();

    var fbs = io.fixedBufferStream(file_map.view);
    if (options.directory == null) {
        return extractSome(allocator, castedReader(Error, &fbs), options, files);
    }
    try extractAll(allocator, castedReader(Error, &fbs), options);
}

fn extractSome(allocator: Allocator, reader: anytype, options: Options, files: []const []const u8) !void {
    assert(options.directory == null);
    if (files.len == 0) return;

    const stdout = std.io.getStdOut();
    var bw = io.BufferedWriter(1024, fs.File.Writer){ .unbuffered_writer = stdout.writer() };

    var file_hashes = std.ArrayList(u64).init(allocator);
    defer file_hashes.deinit();

    var paths = std.AutoArrayHashMap(u64, []const u8).init(allocator); // this is dumb
    defer paths.deinit();

    var entries = std.ArrayList(Entry).init(allocator);
    defer entries.deinit();

    blk: for (files) |file| {
        const hash = xxhash.XxHash64.hash(0, file);
        for (file_hashes.items) |h| {
            if (hash == h) continue :blk;
        }
        try file_hashes.append(hash);
        try paths.put(hash, file);
    }
    std.sort.block(u64, file_hashes.items, {}, std.sort.asc(u64));

    var iter = try wad.header.headerIterator(reader);
    while (try iter.next()) |entry| {
        if (entries.items.len == file_hashes.items.len) break;

        if (entry.hash == file_hashes.items[entries.items.len]) {
            try entries.append(entry);
        }
    }

    const Context = struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.offset < b.offset;
        }
    };
    std.sort.block(Entry, entries.items, {}, Context.lessThan);

    var window_buffer: [1 << 17]u8 = undefined;
    var zstd_stream = try compress.btrstd.decompressor(allocator, reader, .{
        .window_buffer = &window_buffer,
        .decompressed_size = undefined,
        .compressed_size = undefined,
    });
    defer zstd_stream.deinit();

    var read: u32 = iter.bytesRead();
    for (entries.items) |entry| { // there can be duplicates
        if (entry.type != .zstd and entry.type != .zstd_multi) {
            @panic("not implemented");
        }

        const skip = entry.offset - read;
        _ = try reader.skipBytes(skip, .{ .buf_size = 4096 });

        zstd_stream.available_bytes = entry.decompressed_len;
        zstd_stream.unread_bytes = entry.compressed_len;
        // todo: for handling duplicates we can just use one buffer to write out lots of files
        if (writeFile(paths.get(entry.hash).?, zstd_stream.reader(), .{ .size = entry.decompressed_len })) |_| {
            return error.WriteFile;
        }

        read += skip + entry.compressed_len;
    }

    bw.flush() catch return;
}

// how anytype works it just makes two huge extract all functions, i think we can reduce it to just one call
// i verified this with ida, using any reader would be nice, but it has anyerror so not that good, then using any reader our bundle goes down by 30kb
// we can use like AnyReader but with typed errors
fn extractAll(allocator: Allocator, reader: anytype, options: Options) HandleError!void {
    assert(options.directory != null);

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
        std.debug.print("dec_len: {d}, comp_len: {d}\n", .{ entry.decompressed_len, entry.compressed_len });
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
    const file = makeFile(options.dir orelse fs.cwd(), sub_path) catch |err| return .{ .make = err };
    defer file.close();

    // writting in chunks seems to be faster after all
    // and with big buffers like these it most of the times is only one sys call
    var amt: u32 = 0;
    var buf: [1 << 17]u8 = undefined;
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
