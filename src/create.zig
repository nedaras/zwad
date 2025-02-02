const std = @import("std");
const wad = @import("wad.zig");
const compress = @import("compress.zig");
const xxhash = @import("xxhash.zig");
const logger = @import("logger.zig");
const handled = @import("handled.zig");
const errors = @import("errors.zig");
const io = std.io;
const fs = std.fs;
const path = fs.path;
const math = std.math;
const mem = std.mem;
const ouput = wad.output;
const Allocator = mem.Allocator;
const Options = @import("cli.zig").Options;
const HandleError = handled.HandleError;
const assert = std.debug.assert;

pub fn create(allocator: Allocator, options: Options, files: []const []const u8) HandleError!void {
    if (files.len == 0) {
        return logger.fatal("Cowardly refusing to create an empty archive", .{});
    }

    if (options.file == null) {
        const stdout = io.getStdOut();
        if (std.posix.isatty(stdout.handle)) {
            return logger.fatal("Refusing to write archive contents from terminal (missing -f option?)", .{});
        }

        return writeArchive(allocator, stdout.writer(), options, files);
    }

    const file = fs.cwd().createFile(options.file.?, .{}) catch |err| return logger.errprint(err, "{s}: Cannot create", .{options.file.?});
    defer file.close();

    return writeArchive(allocator, file.writer(), options, files);
}

// todo: think if we should try to only writeout all the content if there was no errors
// todo: add an option fot writing out hashes or writing them inside the archive at like 0x000...
pub fn writeArchive(allocator: Allocator, writer: anytype, options: Options, files: []const []const u8) HandleError!void {
    assert(files.len > 0);

    if (files.len > wad.max_entries_len) {
        return logger.fatal("Argument list too long", .{});
    }

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    var entries = try std.ArrayList(ouput.Entry).initCapacity(allocator, files.len);
    defer entries.deinit();

    var entry_by_zstd_checksum = std.AutoHashMap(u64, *const ouput.Entry).init(allocator);
    defer entry_by_zstd_checksum.deinit();

    var window_buffer: [1 << 17]u8 = undefined;
    var read_buffer: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.zstd.compressor(allocator, data.writer(), .{ .window_buffer = &window_buffer });
    defer zstd_stream.deinit();

    var walker = walkFiles(allocator, files);
    defer walker.deinit();

    // todo: get failure flag
    // have no idea if we're doing stuff correcly, we're not handling like symlinks and other stuff
    // for getting the failure flag we could just throw handled errors inside walker
    outer: while (try walker.next()) |file_path| {
        var hash = xxhash.XxHash64.init(0);
        hash.update(file_path.first);
        hash.update(file_path.seperator());
        hash.update(file_path.second);

        const path_hash = hash.final();
        for (entries.items) |entry| {
            // means this file is already added
            if (entry.raw_entry.hash == path_hash) {
                continue :outer;
            }
        }

        const errprint = struct {
            fn inner(wp: Walker.Path, comptime description: []const u8, err: errors.Error) void {
                logger.println("{s}{s}{s}: " ++ description ++ ": {s}", .{ wp.first, wp.seperator(), wp.second, errors.stringify(err) });
            }
        }.inner;

        const file_stat = file_path.stat() catch |err| {
            errprint(file_path, "Cannot stat", err);
            continue;
        };

        if (file_stat.size > wad.max_file_size) {
            errprint(file_path, "Cannot open", error.FileTooBig);
            continue;
        }

        const file = file_path.open(.{}) catch |err| {
            errprint(file_path, "Cannot open", err);
            continue;
        };
        defer file.close();

        const decompressed_size: u32 = @intCast(file_stat.size);
        zstd_stream.setFrameSize(decompressed_size);

        var compressed_size: u32 = 0;
        const entry_offset: u32 = @intCast(data.items.len);
        while (true) {
            const amt = file.read(&read_buffer) catch |err| {
                errprint(file_path, "Cannot read", err);
                continue :outer;
            };
            if (amt == 0) break;
            compressed_size += @intCast(try zstd_stream.write(read_buffer[0..amt]));
        }

        // we're checking for duplicates using zstd_checksums, cuz first thing we will try todo is zstd_compress it
        // todo: add into checksum writer it has to be faster
        const entry_zstd_checksum = xxhash.XxHash3(64).hash(data.items[data.items.len - compressed_size ..]);
        var entry = ouput.Entry.init(.{
            .compressed_size = compressed_size,
            .decompressed_size = decompressed_size,
            .type = .zstd,
            .offset = entry_offset,
            .checksum = entry_zstd_checksum,
        });

        entry.raw_entry.hash = path_hash;
        const dir_name = path.dirname(file_path.second) orelse path.dirname(file_path.first) orelse file_path.first;
        if (std.mem.endsWith(u8, dir_name, "_unk") or std.mem.endsWith(u8, dir_name, "_inv")) blk: {
            const basename = path.basename(file_path.base_path);
            entry.raw_entry.hash = std.fmt.parseInt(u64, basename, 16) catch break :blk;
        }

        var save_checksum = true;
        if (entry_by_zstd_checksum.get(entry_zstd_checksum)) |e| {
            entry.setType(e.getType());
            entry.setOffset(e.getOffset());
            entry.setChecksum(e.getChecksum());
            entry.setCompressedSize(e.getCompressedSize());
            entry.setDecompressedSize(e.getDecompressedSize());
            save_checksum = false;
            data.items.len -= compressed_size;
        } else if (compressed_size >= decompressed_size) blk: {
            file.seekTo(0) catch break :blk;
            data.items.len -= compressed_size;

            var unread_bytes = decompressed_size;
            while (unread_bytes != 0) {
                const slice = read_buffer[0..@min(read_buffer.len, unread_bytes)];

                file.reader().readNoEof(slice) catch |err| {
                    switch (err) {
                        error.EndOfStream => {},
                        else => |e| errprint(file_path, "Cannot read", e),
                    }
                    continue :outer;
                };
                try data.appendSlice(slice);

                unread_bytes -= @intCast(slice.len);
            }

            entry.setCompressedSize(decompressed_size);
            entry.setType(.raw);

            const entry_raw_checksum = xxhash.XxHash3(64).hash(data.items[data.items.len - decompressed_size ..]);
            entry.setChecksum(entry_raw_checksum);
        }

        // todo: when working with 32-bit we need to check these overflows too
        const max_block_size = wad.maxBlockSize(@intCast(entries.items.len + 1));
        if (data.items.len > max_block_size) {
            return logger.fatal("Archive has reached its size limit", .{});
        }

        const item_ptr = try entries.addOne();
        item_ptr.* = entry;

        if (save_checksum) {
            try entry_by_zstd_checksum.put(entry_zstd_checksum, item_ptr);
        }

        if (options.verbose) {
            const stdout = io.getStdOut();
            var bw = io.BufferedWriter(fs.max_path_bytes, fs.File.Writer){
                .unbuffered_writer = stdout.writer(),
            };

            bw.writer().writeAll(file_path.first) catch {};
            bw.writer().writeAll(file_path.seperator()) catch {};
            bw.writer().writeAll(file_path.second) catch {};
            bw.writer().writeByte('\n') catch {};

            bw.flush() catch {};
        }
    }

    var checksum = xxhash.XxHash64.init(0);
    for (entries.items) |*entry| {
        // todo: check for overflow
        const shift: u32 = @intCast(@sizeOf(ouput.Header) + entries.items.len * @sizeOf(ouput.Entry));
        entry.raw_entry.offset += shift;
        checksum.update(mem.asBytes(entry));
    }

    std.sort.block(ouput.Entry, entries.items, {}, struct {
        fn inner(_: void, a: ouput.Entry, b: ouput.Entry) bool {
            return a.raw_entry.hash < b.raw_entry.hash;
        }
    }.inner);

    writer.writeStruct(ouput.Header.init(.{
        .checksum = checksum.final(),
        .entries_len = @intCast(entries.items.len),
    })) catch |err| return switch (err) {
        error.BrokenPipe => {},
        error.Unexpected => logger.unexpected("Unknown error has occurred while creating this archive", .{}),
        else => |e| return logger.errprint(e, "Unexpected error has occurred while creating this archive", .{}),
    };

    writer.writeAll(mem.sliceAsBytes(entries.items)) catch |err| return switch (err) {
        error.BrokenPipe => {},
        error.Unexpected => logger.unexpected("Unknown error has occurred while creating this archive", .{}),
        else => |e| return logger.errprint(e, "Unexpected error has occurred while creating this archive", .{}),
    };

    writer.writeAll(data.items) catch |err| return switch (err) {
        error.BrokenPipe => {},
        error.Unexpected => logger.unexpected("Unknown error has occurred while creating this archive", .{}),
        else => |e| return logger.errprint(e, "Unexpected error has occurred while creating this archive", .{}),
    };
}

const Walker = struct {
    const Path = struct {
        dir: Dir,
        st: ?File.Stat = null,

        // add like dir inside and
        // len for psudo dir
        first: []const u8,
        second: []const u8,

        base_path: []const u8,

        const File = fs.File;
        const Dir = fs.Dir;

        fn stat(self: Path) Dir.StatFileError!File.Stat {
            if (self.st) |st| {
                return st;
            }

            return self.dir.statFile(self.base_path);
        }

        fn open(self: Path, flags: File.OpenFlags) File.OpenError!File {
            return self.dir.openFile(self.base_path, flags);
        }

        fn seperator(self: Path) []const u8 {
            if (self.second.len == 0) {
                return "";
            }

            if (self.first.len > 0) {
                const last_c = self.first[self.first.len - 1];
                if (last_c == path.sep_posix or last_c == path.sep_posix) {
                    return "";
                }
            }
            return path.sep_str;
        }
    };

    inner: ?fs.Dir.Walker = null,

    files: []const []const u8,
    idx: usize = 0,

    allocator: Allocator,

    fn deinit(self: *Walker) void {
        if (self.inner) |*walker| {
            walker.stack.items[0].iter.dir.close();
            walker.deinit();
        }

        self.* = undefined;
    }

    fn next(self: *Walker) Allocator.Error!?Path {
        if (self.inner != null) {
            if (try innerNext(self)) |n| {
                return n;
            }
        }

        while (self.idx != self.files.len) {
            const file_path = self.files[self.idx];
            {
                defer self.idx += 1;
                const file_stat = handled.statFile(file_path, .{}) catch continue;

                if (file_stat.kind != .directory) return .{
                    .dir = fs.cwd(),
                    .st = file_stat,
                    .first = file_path,
                    .second = "",
                    .base_path = file_path,
                };
            }

            const walk_dir = fs.cwd().openDir(file_path, .{ .iterate = true }) catch |err| {
                logger.println("{s}: Cannot open: {s}", .{ file_path, errors.stringify(err) });
                continue;
            };

            self.inner = try walk_dir.walk(self.allocator);
            if (try innerNext(self)) |n| {
                return n;
            }
        }

        return null;
    }

    fn innerNext(self: *Walker) Allocator.Error!?Path {
        while (true) {
            const mb = self.inner.?.next() catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => |e| {
                    var seperator: []const u8 = path.sep_str;
                    const file_path = self.files[self.idx - 1];

                    if (file_path.len > 0) {
                        const last_c = file_path[file_path.len - 1];
                        if (last_c == path.sep_posix or last_c == path.sep_posix) {
                            seperator = "";
                        }
                    }

                    logger.println("{s}{s}{s}: Cannot open: {s}", .{ file_path, seperator, self.inner.?.name_buffer.items, errors.stringify(e) });
                    continue;
                },
            };
            const entry = mb orelse {
                assert(self.inner.?.stack.items.len == 0);
                self.inner.?.deinit();
                self.inner = null;

                return null;
            };
            if (entry.kind == .directory) continue;

            return .{
                .dir = entry.dir,
                .first = self.files[self.idx - 1],
                .second = entry.path,
                .base_path = entry.basename,
            };
        }
    }
};

fn walkFiles(allocator: Allocator, files: []const []const u8) Walker {
    return .{
        .allocator = allocator,
        .files = files,
    };
}

fn ChecksumWriter(comptime WriterType: type) type {
    return struct {
        source: WriterType,
        hash: xxhash.XxHash3(64),

        const Self = @This();

        fn init(wt: WriterType) Self {
            return .{
                .source = wt,
                .hash = xxhash.XxHash3(64).init(),
            };
        }

        const Writer = io.Writer(*Self, WriterType.Error, write);

        fn write(self: *Self, input: []const u8) WriterType.Error!usize {
            self.source.write(input);
            self.hash.update(input);
        }

        fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        inline fn final(self: Self) u64 {
            return self.final();
        }
    };
}

fn checksumWriter(writer: anytype) ChecksumWriter(@TypeOf(writer)) {
    return ChecksumWriter(@TypeOf(writer)).init(writer);
}
