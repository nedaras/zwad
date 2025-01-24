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

pub fn extract(allocator: Allocator, options: Options, files: [][]const u8) HandleError!void {
    const Error = fs.File.Reader.Error;

    if (options.file == null) {
        const stdin = io.getStdIn();
        if (std.posix.isatty(stdin.handle)) {
            return logger.fatal("Refusing to read archive contents from terminal (missing -f option?)", .{});
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

fn extractSome(allocator: Allocator, reader: anytype, options: Options, files: [][]const u8) HandleError!void {
    assert(options.directory == null);

    if (files.len == 0) {
        return;
    }

    const PathedEntry = struct { []const u8, Entry };

    // unleast we add patterns for extracting file like `assets/*` i do not see a good enough reason to buffer stdout
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();

    var entries = try std.ArrayList(PathedEntry).initCapacity(allocator, files.len);
    defer entries.deinit();

    std.sort.block([]const u8, files, {}, struct {
        fn inner(_: void, a: []const u8, b: []const u8) bool {
            return xxhash.XxHash64.hash(0, a) < xxhash.XxHash64.hash(0, b);
        }
    }.inner);

    var iter = wad.header.headerIterator(reader) catch |err| return switch (err) {
        error.UnknownVersion => return error.Outdated,
        error.InvalidFile, error.EndOfStream => logger.fatal("This does not look like a wad archive", .{}),
        error.Unexpected => logger.unexpected("Unknown error has occurred while extracting this archive", .{}),
        else => |e| logger.errprint(e, "Unexpected error has occurred while extracting this archive", .{}),
    };

    while (iter.next()) |mb| {
        const entry = mb orelse break;
        if (entries.items.len == files.len) break;

        // this should be cached outside the while loop ye??
        const path = files[entries.items.len];
        const hash = xxhash.XxHash64.hash(0, path);

        if (entry.hash == hash) {
            entries.appendAssumeCapacity(.{ path, entry });
        }
    } else |err| return switch (err) {
        error.InvalidFile => logger.fatal("This archive seems to be corrupted", .{}),
        error.EndOfStream => logger.fatal("Unexpected EOF in archive", .{}),
        error.Unexpected => logger.unexpected("Unknown error has occurred while extracting this archive", .{}),
        else => |e| logger.errprint(e, "Unexpected error has occurred while extracting this archive", .{}),
    };

    std.sort.block(PathedEntry, entries.items, {}, struct {
        fn inner(_: void, a: PathedEntry, b: PathedEntry) bool {
            return a[1].offset < b[1].offset;
        }
    }.inner);

    var window_buffer: [1 << 17]u8 = undefined;
    var write_buffer: [1 << 17]u8 = undefined;

    // make a reader that would compute subchunks at the same time or mb zstd makes them subchunks
    var zstd_stream = try compress.zstd.decompressor(allocator, reader, .{ .window_buffer = &window_buffer });
    defer zstd_stream.deinit();

    var write_files = std.ArrayList(fs.File).init(allocator);
    defer write_files.deinit();

    // todo: make this more readable
    var bytes_handled: u32 = iter.bytesRead();
    for (entries.items, 0..) |pathed_entry, i| {
        const path, const entry = pathed_entry;

        // todo: check checksums
        // checksum is just Xxhash3(64).hash(0, compressed_buf)
        if (bytes_handled > entry.offset) {
            return logger.fatal("This archive seems to be corrupted", .{});
        }

        var skip = entry.offset - bytes_handled;
        while (skip > 0) {
            const n = reader.read(write_buffer[0..@min(write_buffer.len, skip)]) catch |err| return switch (err) {
                error.Unexpected => logger.unexpected("Unknown error has occurred while extracting this archive", .{}),
                else => |e| logger.errprint(e, "Unexpected error has occurred while extracting this archive", .{}),
            };

            if (n == 0) {
                logger.println("Unexpected EOF in archive", .{});
                return error.Fatal;
            }

            skip -= @intCast(n);
        }

        for (i..entries.items.len) |j| {
            if (entry.offset != entries.items[j][1].offset) break;

            const entry_path = entries.items[j][0];
            const file = createDirAndFile(fs.cwd(), entry_path) catch |err| return logger.errprint(err, "{s}: Cannot make", .{entry_path});

            try write_files.append(file);
        }
        defer {
            for (write_files.items) |file| file.close();
            write_files.items.len = 0;
        }

        if (entry.type == .zstd or entry.type == .zstd_multi) {
            zstd_stream.available_bytes = entry.decompressed_size;
            zstd_stream.unread_bytes = entry.compressed_size;
        }

        var write_len: usize = entry.decompressed_size;
        while (write_len != 0) {
            const buf = write_buffer[0..@min(write_buffer.len, write_len)];
            _ = switch (entry.type) {
                .raw => reader.readNoEof(buf),
                .zstd, .zstd_multi => zstd_stream.reader().readNoEof(buf),
                else => @panic("not implemented"),
            } catch |err| return switch (err) {
                error.MalformedFrame, error.MalformedBlock => logger.fatal("This archive seems to be corrupted", .{}),
                error.EndOfStream => logger.fatal("Unexpected EOF in archive", .{}),
                error.Unexpected => logger.unexpected("Unknown error has occurred while extracting this archive", .{}),
                else => |e| logger.errprint(e, "Unexpected error has occurred while extracting this archive", .{}),
            };

            for (write_files.items, 0..) |file, j| {
                const entry_path = entries.items[i + j][0];
                file.writeAll(buf) catch |err| return switch (err) {
                    error.LockViolation => unreachable, // no lock
                    error.InvalidArgument => unreachable,
                    else => |e| logger.errprint(e, "{s}: Cannot write", .{entry_path}),
                };
            }

            write_len -= @intCast(buf.len);
        }

        if (options.verbose) {
            writer.writeAll(path) catch return;
            writer.writeByte('\n') catch return;
        }

        bytes_handled = entry.offset + entry.compressed_size;
    }
}

// how anytype works it just makes two huge extract all functions, i think we can reduce it to just one call
// i verified this with ida, using any reader would be nice, but it has anyerror so not that good, then using any reader our bundle goes down by 30kb
// we can use like AnyReader but with typed errors
fn extractAll(allocator: Allocator, reader: anytype, options: Options) HandleError!void {
    assert(options.directory != null);
    const dir = options.directory.?;

    const stdout = std.io.getStdOut();
    var bw = io.bufferedWriter(stdout.writer());

    const writer = bw.writer();

    var out_dir = fs.cwd().openDir(dir, .{}) catch |err| return logger.errprint(err, "{s}: Cannot open", .{dir});
    defer out_dir.close();

    const hashes_map = if (options.hashes) |h| try handled.map(fs.cwd(), h, .{}) else null;
    defer if (hashes_map) |h| h.deinit();

    const game_hashes = if (hashes_map) |h| hashes.decompressor(h.view) else null;
    const path_len = 21 + magic.maxExtentionBytes();

    var path_buf: [path_len]u8 = undefined;
    var path: []const u8 = undefined;

    var write_buffer: [1 << 17]u8 = undefined;
    var window_buf: [1 << 17]u8 = undefined;

    // todo: check checksums
    var iter = wad.streamIterator(allocator, reader, .{
        .handle_duplicates = false,
        .window_buffer = &window_buf,
    }) catch |err| return switch (err) {
        error.UnknownVersion => return error.Outdated,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFile, error.EndOfStream => logger.fatal("This does not look like a wad archive", .{}),
        error.Unexpected => logger.unexpected("Unknown error has occurred while extracting this archive", .{}),
        else => |e| logger.errprint(e, "Unexpected error has occurred while extracting this archive", .{}),
    };
    defer iter.deinit();

    // todo: handle duplicates like writing to multiple files
    while (iter.next()) |mb| {
        const entry = mb orelse break;
        if (entry.duplicate()) { // delete this tingy
            var new_path_buf: [path_len]u8 = undefined;
            var new_path: []const u8 = undefined;

            if (game_hashes) |h| {
                // todo: add lambda that would flush automaticly
                new_path = h.get(entry.hash) catch {
                    bw.flush() catch return;
                    return logger.fatal("This hashes file seems to be corrupted", .{});
                } orelse std.fmt.bufPrint(&new_path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
            } else {
                new_path = std.fmt.bufPrint(&new_path_buf, "{x:0>16}", .{entry.hash}) catch unreachable;
            }

            copyFile(out_dir, path, out_dir, new_path, .{}) catch |err| {
                bw.flush() catch return;
                return logger.errprint(err, "{s}: Cannot copy '{s}'", .{ new_path, path });
            };

            if (options.verbose) {
                writer.print("{s}\n", .{new_path}) catch return;
            }
            continue;
        }
        // todo: add magic?
        if (game_hashes) |h| {
            path = h.get(entry.hash) catch {
                bw.flush() catch return;
                return logger.fatal("This hashes file seems to be corrupted", .{});
            } orelse std.fmt.bufPrint(&path_buf, "_unk/{x:0>16}", .{entry.hash}) catch unreachable;
        } else {
            path = std.fmt.bufPrint(&path_buf, "{x:0>16}", .{entry.hash}) catch unreachable;
        }

        const write_file = createDirAndFile(out_dir, path) catch |err| blk: {
            bw.flush() catch return;
            logger.println("{s}: Cannot make: {s}", .{ path, errors.stringify(err) });
            if (err == error.BadPathName or err == error.NameTooLong or err == error.IsDir) {
                path = std.fmt.bufPrint(&path_buf, "_inv/{x:0>16}", .{entry.hash}) catch unreachable;
                break :blk createDirAndFile(out_dir, path) catch |e| return logger.errprint(e, "{s}: Cannot make", .{path});
            }
            return handled.fatal(err);
        };
        defer write_file.close();

        var write_len: u32 = entry.decompressed_size;
        while (write_len != 0) {
            const buf = write_buffer[0..@min(write_buffer.len, write_len)];
            entry.reader().readNoEof(buf) catch |err| {
                bw.flush() catch return;
                return switch (err) {
                    error.MalformedFrame, error.MalformedBlock => logger.fatal("This archive seems to be corrupted", .{}),
                    error.EndOfStream => logger.fatal("Unexpected EOF in archive", .{}),
                    error.Unexpected => logger.unexpected("Unknown error has occurred while extracting this archive", .{}),
                    else => |e| logger.errprint(e, "Unexpected error has occurred while extracting this archive", .{}),
                };
            };

            write_file.writeAll(buf) catch |err| switch (err) {
                error.LockViolation => unreachable, // no lock
                error.InvalidArgument => unreachable,
                else => |e| {
                    bw.flush() catch return;
                    return logger.errprint(e, "{s}: Cannot write", .{path});
                },
            };

            write_len -= @intCast(buf.len);
        }
        assert(write_len == 0);

        if (options.verbose) {
            writer.writeAll(path) catch return;
            writer.writeByte('\n') catch return;
        }
    } else |err| {
        bw.flush() catch return;
        return switch (err) {
            error.InvalidFile => logger.fatal("This archive seems to be corrupted", .{}),
            error.EndOfStream => logger.fatal("Unexpected EOF in archive", .{}),
            error.Unexpected => logger.unexpected("Unknown error has occurred while extracting this archive", .{}),
            else => |e| logger.errprint(e, "Unexpected error has occurred while extracting this archive", .{}),
        };
    }

    bw.flush() catch return;
}

const MakeFileError = fs.File.OpenError || fs.Dir.MakeError || fs.File.StatError;

fn createDirAndFile(dir: std.fs.Dir, file_name: []const u8) !std.fs.File {
    const fs_file = dir.createFile(file_name, .{}) catch |err| {
        if (err == error.FileNotFound) {
            if (std.fs.path.dirname(file_name)) |dir_name| {
                try dir.makePath(dir_name);
                return dir.createFile(file_name, .{});
            }
        }
        return err;
    };
    return fs_file;
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
