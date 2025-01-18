const std = @import("std");
const wad = @import("wad.zig");
const compress = @import("compress.zig");
const xxhash = @import("xxhash.zig");
const logger = @import("logger.zig");
const handled = @import("handled.zig");
const errors = @import("errors.zig");
const io = std.io;
const fs = std.fs;
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

    // todo: we need to make blobs from files

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

    var offsets = std.AutoHashMap(u64, u32).init(allocator);
    defer offsets.deinit();

    try offsets.ensureTotalCapacity(@intCast(files.len));

    const header_len = @sizeOf(ouput.Header) + @sizeOf(ouput.Entry) * files.len;

    var read_buffer: [1 << 17]u8 = undefined;
    var window_buffer: [1 << 17]u8 = undefined;

    var zstd_stream = try compress.zstd.compressor(allocator, block.writer(), .{ .window_buffer = &window_buffer });
    defer zstd_stream.deinit();

    var checksum = xxhash.XxHash64.init(0);
    for (files) |file_path| {
        const stat = fs.cwd().statFile(file_path) catch |err| {
            logger.println("{s}: Cannot stat: {s}", .{ file_path, errors.stringify(err) });
            continue;
        };

        // todo: make that given files could never be a directory
        if (stat.kind == .directory) {
            logger.println("{s}: Cannot open: {s}", .{ file_path, errors.stringify(error.IsDir) });
            continue;
        }

        if (stat.size > wad.max_file_size) {
            return logger.errprint(error.FileTooBig, "{s}: Cannot open", .{file_path});
        }

        // todo: Check if maping is faster
        const file = fs.cwd().openFile(file_path, .{}) catch |err| {
            logger.println("{s}: Cannot open: {s}", .{ file_path, errors.stringify(err) });
            continue;
        };
        defer file.close();

        const decompressed_size: u32 = @intCast(stat.size);
        zstd_stream.setFrameSize(decompressed_size);

        var compressed_size: u32 = 0;
        while (true) {
            const amt = file.read(&read_buffer) catch |err| return logger.errprint(err, "{s}: Cannot read", .{file_path});
            if (amt == 0) break;
            compressed_size += @intCast(zstd_stream.write(read_buffer[0..amt]) catch |err| return switch (err) {
                error.Unexpected => logger.unexpected("Unknown error has occurred while creating this archive", .{}),
                error.OutOfMemory => |e| e,
            });
        }

        // bench what is faster this, or wraped checksum writer
        const entry_checksum = xxhash.XxHash3(64).hash(block.items[block.items.len - compressed_size ..]);
        var entry = ouput.Entry.init(.{
            .path = file_path, // path is always converted to lowercase by Entry
            .compressed_size = compressed_size,
            .decompressed_size = decompressed_size,
            .type = .zstd,
            .checksum = entry_checksum,
        });

        if (offsets.get(entry_checksum)) |offset| {
            entry.setOffset(offset);
            block.items.len -= compressed_size;
        } else {
            const offset: u32 = @intCast(header_len + block.items.len - compressed_size);

            offsets.putAssumeCapacity(entry_checksum, offset);
            entry.setOffset(offset);

            if (compressed_size >= decompressed_size) blk: {
                if (decompressed_size == 0) {
                    entry.setType(.raw);
                    break :blk;
                }
                file.seekTo(0) catch break :blk;

                entry.setType(.raw);
                entry.setCompressedSize(decompressed_size);

                block.items.len -= compressed_size;

                var unread_bytes = decompressed_size;
                while (unread_bytes != 0) {
                    const len = @min(read_buffer.len, unread_bytes);
                    file.reader().readNoEof(read_buffer[0..len]) catch |err| return switch (err) {
                        error.EndOfStream => logger.fatal("{s}: Cannot read: EOF", .{file_path}),
                        else => |e| logger.errprint(e, "{s}: Cannot read", .{file_path}),
                    };

                    try block.appendSlice(read_buffer[0..len]);
                    unread_bytes -= @intCast(len);
                }
            }
        }

        // todo: when working with 32-bit we need to check these overflows too
        const max_block_size = wad.maxBlockSize(@intCast(entries.items.len + 1));
        if (block.items.len > max_block_size) {
            return logger.fatal("File size exceeded archive format limit", .{});
        }

        checksum.update(mem.asBytes(&entry));
        entries.appendAssumeCapacity(entry);

        if (options.verbose) {
            const stdout = io.getStdOut();
            var bw = io.BufferedWriter(fs.max_path_bytes, fs.File.Writer){ .unbuffered_writer = stdout.writer() };

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

    var fatal = false;
    if (entries.items.len != files.len) {
        fatal = true;

        const offset_rollback: u32 = @intCast((files.len - entries.items.len) * @sizeOf(ouput.Entry));
        checksum.reset(0);

        for (entries.items) |*entry| {
            entry.raw_entry.offset -= offset_rollback;
            checksum.update(mem.asBytes(entry));
        }
    }

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

    if (fatal) {
        return error.Fatal;
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
