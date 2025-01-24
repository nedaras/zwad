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

    // idea is very simple we will not habdle blobs
    // linux does handle them kinda
    // if the file is a dir we will just get the whole dirs fils
    // we can do smth like tars -T option so they could stream them in

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
pub fn writeArchive(allocator: Allocator, writer: anytype, options: Options, files: []const []const u8) HandleError!void {
    assert(files.len > 0);

    if (files.len > wad.max_entries_len) {
        return logger.fatal("Argument list too long", .{});
    }

    var block = std.ArrayList(u8).init(allocator);
    defer block.deinit();

    var entries = try std.ArrayList(ouput.Entry).initCapacity(allocator, files.len);
    defer entries.deinit();

    var offsets = std.AutoHashMap(u64, *const ouput.Entry).init(allocator);
    defer offsets.deinit();

    try offsets.ensureTotalCapacity(@intCast(files.len));

    var window_buffer: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.zstd.compressor(allocator, block.writer(), .{ .window_buffer = &window_buffer });
    defer zstd_stream.deinit();

    for (files) |file_path| {
        const stdout = io.getStdOut();
        var bw = io.BufferedWriter(fs.max_path_bytes, fs.File.Writer){ .unbuffered_writer = stdout.writer() };

        addFileToArchive(file_path, &zstd_stream, .{
            .header = &entries,
            .data = &block,
            .entry_by_checksum = &offsets,
        }) catch |err| switch (err) {
            error.IsDir => {
                const dir = fs.cwd().openDir(file_path, .{ .iterate = true }) catch unreachable;

                var walker = dir.walk(allocator) catch unreachable;
                defer walker.deinit();

                while (walker.next() catch unreachable) |next| {
                    if (next.kind == .directory) continue;

                    addFileToArchive(next.path, &zstd_stream, .{
                        .dir = dir,
                        .prefix = file_path,
                        .header = &entries,
                        .data = &block,
                        .entry_by_checksum = &offsets,
                    }) catch unreachable;

                    if (options.verbose) {
                        if (file_path.len > 0) {
                            for (file_path) |c| {
                                bw.writer().writeByte(std.ascii.toLower(c)) catch return;
                            }
                            // todo: handle so it would not be like path///////////////////
                            if (file_path[file_path.len - 1] != '/') {
                                bw.writer().writeByte('/') catch return;
                            }
                        }

                        for (next.path) |c| {
                            bw.writer().writeByte(std.ascii.toLower(c)) catch return;
                        }

                        bw.writer().writeByte('\n') catch return;
                        bw.flush() catch return;
                    }
                }

                continue;
            },
            else => unreachable,
        };

        if (options.verbose) {
            for (file_path) |c| {
                bw.writer().writeByte(std.ascii.toLower(c)) catch return;
            }

            bw.writer().writeByte('\n') catch return;
            bw.flush() catch return;
        }
    }

    if (entries.items.len == 0) {
        return error.Fatal;
    }

    var checksum = xxhash.XxHash64.init(0);
    for (entries.items) |*entry| {
        // todo: check for overflow
        const shift: u32 = @intCast(@sizeOf(ouput.Header) + entries.items.len * @sizeOf(ouput.Entry));
        entry.raw_entry.offset += shift;
        checksum.update(mem.asBytes(entry));
    }

    //var fatal = false;
    //if (entries.items.len != files.len) {
    //fatal = true;

    //const offset_rollback: u32 = @intCast((files.len - entries.items.len) * @sizeOf(ouput.Entry));
    //checksum.reset(0);

    //for (entries.items) |*entry| {
    //entry.raw_entry.offset -= offset_rollback;
    //checksum.update(mem.asBytes(entry));
    //}
    //}

    // todo: check what is faster sorting paths before hand or sorting entries
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

    writer.writeAll(block.items) catch |err| return switch (err) {
        error.BrokenPipe => {},
        error.Unexpected => logger.unexpected("Unknown error has occurred while creating this archive", .{}),
        else => |e| return logger.errprint(e, "Unexpected error has occurred while creating this archive", .{}),
    };

    //if (fatal) {
    //return error.Fatal;
    //}
}

const AddFileOptions = struct {
    dir: fs.Dir = fs.cwd(),
    prefix: []const u8 = "",
    header: *std.ArrayList(ouput.Entry),
    data: *std.ArrayList(u8),
    entry_by_checksum: *std.AutoHashMap(u64, *const ouput.Entry),
};

fn addFileToArchive(sub_path: []const u8, stream: anytype, options: AddFileOptions) !void {
    const file_stat = try options.dir.statFile(sub_path);
    if (file_stat.kind == .directory) {
        return error.IsDir;
    }

    if (file_stat.size > wad.max_file_size) {
        return error.FileTooBig;
    }

    const file = try options.dir.openFile(sub_path, .{});
    defer file.close();

    const decompressed_size: u32 = @intCast(file_stat.size);
    stream.setFrameSize(decompressed_size);

    var buffer: [1 << 17]u8 = undefined;

    var compressed_size: u32 = 0;
    while (true) {
        const amt = try file.read(&buffer);
        if (amt == 0) break;
        compressed_size += @intCast(try stream.write(buffer[0..amt]));
    }

    const entry_checksum = xxhash.XxHash3(64).hash(options.data.items[options.data.items.len - compressed_size ..]);
    var entry = ouput.Entry.init(.{
        //.path = sub_path, // path is always converted to lowercase by Entry, we're not handling prefix
        .compressed_size = compressed_size,
        .decompressed_size = decompressed_size,
        .type = .zstd,
        .checksum = entry_checksum,
    });

    {
        var path_hash = xxhash.XxHash64.init(0);
        if (options.prefix.len > 0) {
            for (options.prefix) |c| {
                var char = [_]u8{std.ascii.toLower(c)};
                path_hash.update(&char);
            }
            if (options.prefix[options.prefix.len - 1] != '/') {
                path_hash.update("/");
            }
        }

        for (sub_path) |c| {
            var char = [_]u8{std.ascii.toLower(c)};
            path_hash.update(&char);
        }

        entry.raw_entry.hash = path_hash.final();
    }

    const dirname = path.dirname(sub_path);
    if (dirname) |dir| blk: {
        if (mem.endsWith(u8, dir, "_unk") or mem.endsWith(u8, dir, "_inv")) {
            const hash = std.fmt.parseInt(u64, path.basename(sub_path), 16) catch break :blk;
            entry.raw_entry.hash = hash;
        }
    }

    var flag = false;
    if (options.entry_by_checksum.get(entry_checksum)) |e| {
        entry.setType(e.getType());
        entry.setCompressedSize(e.raw_entry.compressed_size);
        entry.setOffset(e.raw_entry.offset);

        options.data.items.len -= compressed_size;
    } else {
        // todo: check for overflow
        flag = true;
        const offset: u32 = @intCast(options.data.items.len - compressed_size);
        entry.setOffset(offset);

        if (compressed_size >= decompressed_size) blk: {
            if (decompressed_size == 0) {
                entry.setType(.raw);
                break :blk;
            }
            file.seekTo(0) catch break :blk;

            entry.setType(.raw);
            entry.setCompressedSize(decompressed_size);

            options.data.items.len -= compressed_size;

            var unread_bytes = decompressed_size;
            while (unread_bytes != 0) {
                const slice = buffer[0..@min(buffer.len, unread_bytes)];

                try file.reader().readNoEof(slice);
                try options.data.appendSlice(slice);

                unread_bytes -= @intCast(slice.len);
            }
        }
    }

    // todo: when working with 32-bit we need to check these overflows too
    const max_block_size = wad.maxBlockSize(@intCast(options.header.items.len + 1));
    if (options.data.items.len > max_block_size) {
        return error.ArchiveTooBig;
    }

    const item_ptr = try options.header.addOne();
    item_ptr.* = entry;

    if (flag) {
        try options.entry_by_checksum.put(entry_checksum, item_ptr);
    }
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
