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

pub fn extract(allocator: Allocator, options: Options, files: []const []const u8) HandleError!void {
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

fn extractSome(allocator: Allocator, reader: anytype, options: Options, files: []const []const u8) HandleError!void {
    assert(options.directory == null);
    if (files.len == 0) return;

    const PathedEntry = struct { []const u8, Entry };
    const PathedHash = struct { []const u8, u64 };

    const stdout = std.io.getStdOut();
    var bw = io.BufferedWriter(1024, fs.File.Writer){ .unbuffered_writer = stdout.writer() };

    const writer = bw.writer();

    // mb move all this to a function idk
    var file_hashes = std.ArrayList(PathedHash).init(allocator);
    defer file_hashes.deinit();

    var entries = std.ArrayList(PathedEntry).init(allocator);
    defer entries.deinit();

    blk: for (files) |file| {
        const hash = xxhash.XxHash64.hash(0, file);
        for (file_hashes.items) |h| {
            if (hash == h[1]) continue :blk;
        }
        try file_hashes.append(.{ file, hash });
    }

    {
        const Context = struct {
            fn lessThan(_: void, a: PathedHash, b: PathedHash) bool {
                return a[1] < b[1];
            }
        };
        std.sort.block(PathedHash, file_hashes.items, {}, Context.lessThan);
    }

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

    while (iter.next()) |mb| {
        const entry = mb orelse break;
        if (entries.items.len == file_hashes.items.len) break;

        const path, const hash = file_hashes.items[entries.items.len];
        if (entry.hash == hash) {
            try entries.append(.{ path, entry });
        }
    } else |err| {
        switch (err) {
            error.InvalidFile => logger.println("This archive seems to be corrupted", .{}),
            error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
            else => |e| logger.println("Unexpected read error: {s}", .{errors.stringify(e)}),
        }
        return handled.fatal(err);
    }

    const Context = struct {
        fn lessThan(_: void, a: PathedEntry, b: PathedEntry) bool {
            return a[1].offset < b[1].offset;
        }
    };
    std.sort.block(PathedEntry, entries.items, {}, Context.lessThan);

    var window_buffer: [1 << 17]u8 = undefined;
    var write_buffer: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.btrstd.decompressor(allocator, reader, .{ .window_buffer = &window_buffer });
    defer zstd_stream.deinit();

    var write_files = std.ArrayList(fs.File).init(allocator);
    defer write_files.deinit();

    var bytes_handled: u32 = iter.bytesRead();
    for (entries.items, 0..) |pathed_entry, i| {
        const path, const entry = pathed_entry;

        const skip = entry.offset - bytes_handled;
        reader.skipBytes(skip, .{ .buf_size = 4096 }) catch |err| {
            bw.flush() catch return;
            switch (err) {
                error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
                else => |e| logger.println("Unexpected read error: {s}", .{errors.stringify(e)}),
            }
            return handled.fatal(err);
        };

        for (i..entries.items.len) |j| {
            if (entry.offset != entries.items[j][1].offset) break;
            const entry_path = entries.items[j][0];
            const file = makeFile(fs.cwd(), entry_path) catch |err| {
                bw.flush() catch return;
                logger.println("{s}: Cannot make: {s}", .{ entry_path, errors.stringify(err) });
                return handled.fatal(err);
            };
            try write_files.append(file);
        }
        defer {
            for (write_files.items) |file| file.close();
            write_files.items.len = 0;
        }

        if (entry.type == .zstd or entry.type == .zstd_multi) {
            zstd_stream.available_bytes = entry.decompressed_len;
            zstd_stream.unread_bytes = entry.compressed_len;
        }

        var amt: usize = 0;
        while (true) {
            const dest = write_buffer[0..@min(write_buffer.len, entry.decompressed_len - amt)];
            const n = switch (entry.type) {
                .raw => reader.read(dest),
                .zstd, .zstd_multi => zstd_stream.read(dest),
                else => @panic("not implemented"),
            } catch |err| {
                bw.flush() catch return;
                switch (err) {
                    error.EndOfStream => logger.println("Unexpected EOF in archive", .{}),
                    error.MalformedFrame, error.MalformedBlock => logger.println("This archive seems to be corrupted", .{}),
                    else => |e| logger.println("Unexpected read error: {s}", .{errors.stringify(e)}),
                }
                return handled.fatal(err);
            };

            if (n == 0) break;

            for (write_files.items, 0..) |file, j| {
                file.writeAll(write_buffer[0..n]) catch |err| {
                    const entry_path = entries.items[i + j][0];
                    switch (err) {
                        error.LockViolation => unreachable, // no lock
                        error.InvalidArgument => unreachable,
                        else => |e| logger.println("{s}: Cannot write: {s}", .{ entry_path, errors.stringify(e) }),
                    }
                    return handled.fatal(err);
                };
            }

            amt += n;
        }

        assert(amt == entry.decompressed_len);

        if (options.verbose) {
            writer.writeAll(path) catch return;
            writer.writeByte('\n') catch return;
        }

        bytes_handled += skip + entry.compressed_len;
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

fn DiagnosticsError(comptime ReaderType: type) type { // This thing is just goofy
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
            FileDescriptorNotASocket,
            MessageTooBig,
            NetworkUnreachable,
            NetworkSubsystemFailed,
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
                        else => |x| x,
                    };
                }
                return error.FileNotFound;
            },
            error.OutOfMemory => return error.SystemResources,
            error.PermissionDenied => return error.AccessDenied,
            error.InvalidArgument, error.FileLocksNotSupported => unreachable, // i think zig should handle this before hand
            error.LockViolation => unreachable, // idk why zig left this error
            else => |e| return e,
        }
    };
}
