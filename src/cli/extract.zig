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

            // mmapping on linux seems to be rly fucking slow
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

    while (try iter.next()) |entry| {
        if (entry.duplicate()) {
            continue;
        }

        var buf: [256]u8 = undefined;
        var path = if (game_hashes) |h| try h.get(entry.hash) else null;
        if (path == null) {
            path = try std.fmt.bufPrint(&buf, "{x:0>16}.dds", .{entry.hash});
        }

        if (options.verbose) {
            writer.print("{s}\n", .{path.?}) catch return;
        }

        // todo: handle write File errors here
        writeFile(out_dir, path.?, entry.reader(), entry.decompressed_len) catch |err| switch (err) {
            error.Fatal => {},
            else => |e| return e,
        };
    }

    bw.flush() catch return;
}

fn writeFile(dir: fs.Dir, sub_path: []const u8, reader: anytype, max_size: u32) HandleError!void {
    if (is_windows) {
        return writeFileW(dir, sub_path, reader, max_size);
    }
    @compileError("not implemented for linux");
}

fn writeFileW(dir: fs.Dir, sub_path: []const u8, reader: anytype, size: u32) HandleError!void {
    // on windows mapping files is much faster then buffered writting

    const file = makeFile(dir, sub_path) catch |err| switch (err) {
        error.DiskQuota, error.LinkQuotaExceeded, error.ReadOnlyFileSystem => @panic("unwraping"),
        else => |e| {
            logger.println("{s}: Cannot create: {s}", .{ sub_path, errors.stringify(e) });
            return if (e == error.Unexpected) error.Unexpected else error.Fatal;
        },
    };
    defer file.close();

    if (size == 0) {
        @setCold(true);
        return;
    }

    const map = mapping.mapFileW(file, .{ .mode = .write_only, .size = size }) catch |err| switch (err) {
        error.LockedMemoryLimitExceeded => unreachable, // no lock requested
        error.InvalidSize => unreachable, // size will not be zero
        else => |e| {
            logger.println("{s}: Cannot map: {s}", .{ sub_path, errors.stringify(e) });
            return if (e == error.Unexpected) error.Unexpected else error.Fatal;
        },
    };
    defer map.unmap();

    reader.readNoEof(map.view) catch |err| switch (err) {
        error.EndOfStream => unreachable,
        error.Unexpected => {
            logger.println("Unexpected error has occured while extracting this archive", .{});
            return error.Fatal;
        },
        error.MalformedFrame, error.MalformedBlock => {
            logger.println("This archive seems to be corrupted", .{});
            return error.Fatal;
        },
    };
}

const MakeFileError = fs.File.OpenError || fs.Dir.MakeError || fs.File.StatError;

pub fn makeFile(dir: fs.Dir, sub_path: []const u8) MakeFileError!fs.File {
    return dir.createFile(sub_path, .{ .read = true }) catch |err| switch (err) {
        error.FileNotFound => {
            if (fs.path.dirname(sub_path)) |sub_dir| {
                @setCold(false);
                try dir.makePath(sub_dir);
                return dir.createFile(sub_path, .{ .read = true });
            }
            return error.FileNotFound;
        },
        else => |e| return e,
    };
}
