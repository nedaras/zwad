const std = @import("std");
const xxhash = @import("xxhash.zig");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const zstd = std.compress.zstd;
const assert = std.debug.assert;
const win = std.os.windows;
const native_endian = @import("builtin").target.cpu.arch.endian();

extern "kernel32" fn CreateFileMappingA(hFile: win.HANDLE, ?*anyopaque, flProtect: win.DWORD, dwMaximumSizeHigh: win.DWORD, dwMaximumSizeLow: win.DWORD, lpName: ?win.LPCSTR) callconv(win.WINAPI) ?win.HANDLE;

extern "kernel32" fn MapViewOfFile(hFileMappingObject: win.HANDLE, dwDesiredAccess: win.DWORD, dwFileOffsetHigh: win.DWORD, dwFileOffsetLow: win.DWORD, dwNumberOfBytesToMap: win.SIZE_T) callconv(win.WINAPI) ?[*]u8;

extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: win.LPCVOID) callconv(win.WINAPI) win.BOOL;

const c = @cImport({
    @cInclude("zstd.h");
});

const Header = extern struct {
    const Version = extern struct {
        magic: [2]u8,
        major: u8,
        minor: u8,
    };

    version: Version,
    ecdsa_signature: [256]u8,
    checksum: u64 align(1),
    entries_len: u32,
};

const EntryType = enum(u4) {
    raw = 0,
    link,
    gzip,
    zstd,
    zstd_multi,
};

const Entry = packed struct {
    hash: u64,
    offset: u32,
    compressed_len: u32,
    decompressed_len: u32,
    entry_type: EntryType,
    subchunk_len: u4,
    subchunk: u24,
    checksum: u64,
};

fn fastHexParse(comptime T: type, buf: []const u8) !u64 { // we can simd, but idk if its needed
    var result: T = 0;

    for (buf) |ch| {
        var mask: T = undefined;

        if (ch >= '0' and ch <= '9') {
            mask = ch - '0';
        } else if (ch >= 'a' and ch <= 'f') {
            mask = ch - 'a' + 10;
        } else {
            return error.InvalidCharacter;
        }

        if (result > std.math.maxInt(T) >> 4) {
            return error.Overflow;
        }

        result = (result << 4) | mask;
    }

    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();

    const uri = try std.Uri.parse("http://raw.communitydragon.org/data/hashes/lol/hashes.game.txt"); // http so there would not be any tls overhead
    var server_header_buffer: [16 * 1024]u8 = undefined;

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .keep_alive = false,
    });
    defer req.deinit();

    try req.send();

    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        //req.response.skip = true;
        //assert(try req.transferRead(&.{}) == 0);

        return error.InvalidStatusCode;
    }

    var line_buf: [4 * 1024]u8 = undefined;
    var fbs = io.fixedBufferStream(&line_buf);

    const writer = fbs.writer();

    var buf: [std.http.Client.Connection.buffer_size]u8 = undefined; // we prob can use connections buffer, like fill cmds

    var start: usize = 0;
    var end: usize = 0;

    const out_file = try fs.cwd().createFile(".hashes", .{}); // mb maping would prob be better, cuz on falure we would not have corrupted .hashes file
    defer out_file.close();

    var bw = io.bufferedWriter(out_file.writer());
    const file_writer = bw.writer();

    var file_list = std.ArrayList(u8).init(allocator);
    defer file_list.deinit();

    var map = std.AutoArrayHashMap(u64, struct { usize, usize }).init(allocator);
    defer map.deinit();

    while (true) {
        if (mem.indexOfScalar(u8, buf[start..end], '\n')) |pos| {
            try writer.writeAll(buf[start .. start + pos]);
            start += pos + 1;

            {
                const line = line_buf[0..fbs.pos];
                assert(line.len > 17);
                assert(line[16] == ' ');

                const hash = try fastHexParse(u64, line[0..16]);
                const file = line[17..];

                const i = file_list.items.len;

                // we could prob drop map and just use arr list
                try file_list.appendSlice(file); // we could use better allocation strategy, prob 2n or better n^2
                try map.put(hash, .{ i, file_list.items.len }); // we could use better allocation strategy, prob 2n or better n^2
            }
            fbs.pos = 0;

            continue;
        }
        try writer.writeAll(buf[start..end]);

        const amt = try req.read(buf[0..]);
        if (amt == 0) break; //return error.EndOfStream;

        start = 0;
        end = amt;
    }

    const Context = struct {
        keys: []u64,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.keys[a_index] < ctx.keys[b_index];
        }
    };

    map.unmanaged.sortUnstableContext(Context{ .keys = map.keys() }, map.ctx);

    const header_len: u64 = 4 + map.keys().len * (8 + 4 + 2);
    try out_file.seekTo(header_len);
    _ = file_writer;

    var it = map.iterator();
    while (it.next()) |entry| {
        const beg, end = entry.value_ptr.*;

        const k = entry.key_ptr.*;
        const v = file_list.items[beg..end];
        _ = k;

        var splits = mem.splitScalar(u8, v, '/');
        while (splits.next()) |split| {
            _ = split;
            // first walk from top and find unset fields
        }
    }

    //try file_writer.writeInt(u32, @intCast(map.keys().len), native_endian);
    //for (map.keys()) |k| {
    //const beg, end = map.get(k).?;
    //const v = file_list.items[beg..end];

    //const offset = 0;
    //const len = 0;

    //try file_writer.writeInt(u64, k, native_endian);
    //try file_writer.writeInt(u32, offset, native_endian);
    //try file_writer.writeInt(u16, v.len, native_endian);

    //header_len += 8 + 4 + 2;
    //try gzip_stream.writer().print("{x:0>16} {s}\n", .{ k, v });
    //}

    try bw.flush();
}

pub fn main_validate() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing; // now try to extract only a file

    comptime assert(@sizeOf(Header) == 272);
    comptime assert(@sizeOf(Entry) == 32);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_len = try file.getEndPos();
    const maping = CreateFileMappingA(file.handle, null, win.PAGE_READONLY, 0, 0, null).?;
    defer win.CloseHandle(maping);

    const file_buf = MapViewOfFile(maping, 0x4, 0, 0, 0).?;
    defer _ = UnmapViewOfFile(file_buf);

    var file_stream = io.fixedBufferStream(file_buf[0..file_len]);
    const reader = file_stream.reader();

    const header = try reader.readStruct(Header); // idk if league uses a specific endian, my guess is that they do not

    assert(mem.eql(u8, &header.version.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 4);

    var out_list = std.ArrayList(u8).init(allocator);
    defer out_list.deinit();

    var prev_hash: u64 = 0;
    std.debug.print("checksum: {x}\n", .{header.checksum});
    for (header.entries_len) |_| {
        const entry = try reader.readStruct(Entry);
        const gb = 1024 * 1024 * 1024;

        assert(entry.hash >= prev_hash);
        prev_hash = entry.hash;

        assert(4 * gb > entry.compressed_len);
        assert(4 * gb > entry.decompressed_len);
        assert(4 * gb > entry.offset);

        switch (entry.entry_type) {
            .raw => {
                const pos = try file_stream.getPos();
                try file_stream.seekTo(entry.offset);

                assert(entry.compressed_len == entry.decompressed_len);
                assert(file_stream.buffer[file_stream.pos..].len >= entry.compressed_len);

                const in = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.compressed_len];

                const checksum = xxhash.XxHash3(64).hash(in);
                assert(checksum == entry.checksum);

                try file_stream.seekTo(pos);
            },
            .zstd, .gzip, .zstd_multi => {
                const pos = try file_stream.getPos();
                try file_stream.seekTo(entry.offset);

                assert(file_stream.buffer[file_stream.pos..].len >= entry.compressed_len);

                const in = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.compressed_len];

                const magic = [_]u8{ 0x28, 0xB5, 0x2f, 0xfd };
                assert(mem.eql(u8, in[0..4], &magic));

                const checksum = xxhash.XxHash3(64).hash(in);
                assert(checksum == entry.checksum);

                try file_stream.seekTo(pos);
            },
            .link => |t| { // hiping that gzip in zig is now slow.
                std.debug.print("warn: idk how to handle, {s}.\n", .{@tagName(t)});
            },
        }
    }
}

pub fn parsing_main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator(); // todo: use  c_allocator on unsafe release modes

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next().?;

    const src = args.next() orelse return error.ArgumentSrcFileMissing; // now try to extract only a file
    const dst = args.next() orelse return error.ArgumentDstDirMissing;

    comptime assert(@sizeOf(Header) == 272);
    comptime assert(@sizeOf(Entry) == 32);

    const file = try fs.cwd().openFile(src, .{});
    defer file.close();

    const file_len = try file.getEndPos();
    const maping = CreateFileMappingA(file.handle, null, win.PAGE_READONLY, 0, 0, null).?;
    defer win.CloseHandle(maping);

    const file_buf = MapViewOfFile(maping, 0x4, 0, 0, 0).?;
    defer _ = UnmapViewOfFile(file_buf);

    var file_stream = io.fixedBufferStream(file_buf[0..file_len]);
    const reader = file_stream.reader();

    var out_dir = try fs.cwd().openDir(dst, .{});
    defer out_dir.close();

    const header = try reader.readStruct(Header); // idk if league uses a specific endian, my guess is that they do not

    assert(mem.eql(u8, &header.magic, "RW"));
    assert(header.version.major == 3);
    assert(header.version.minor == 3);

    var out_list = std.ArrayList(u8).init(allocator);
    defer out_list.deinit();

    var scrape_buf: [256]u8 = undefined;
    for (header.entries_len) |_| {
        const entry = try reader.readStruct(Entry);
        switch (entry.entry_type) {
            .zstd => { // performance not bad, but we probably could multithread (it would be pain to implement)
                const pos = try file_stream.getPos();
                try file_stream.seekTo(entry.offset);

                try out_list.ensureTotalCapacity(entry.decompressed_len);

                assert(out_list.capacity >= entry.decompressed_len);
                assert(file_len - file_stream.pos >= entry.compressed_len);

                const in = file_stream.buffer[file_stream.pos .. file_stream.pos + entry.compressed_len];
                const out = out_list.allocatedSlice()[0..entry.decompressed_len];

                const zstd_len = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len); // we could have stack buf and just fill it and write to file, and thus we would not need to alloc mem.
                if (c.ZSTD_isError(zstd_len) == 1) {
                    std.debug.print("err: {s}\n", .{c.ZSTD_getErrorName(zstd_len)});
                }

                try file_stream.seekTo(pos);

                const name = try std.fmt.bufPrint(&scrape_buf, "{x}.dds", .{entry.hash});
                const out_file = try out_dir.createFile(name, .{});
                defer out_file.close();

                try out_file.writeAll(out);
            },
            .raw, .gzip, .link, .zstd_multi => |t| { // hiping that gzip in zig is now slow.
                std.debug.print("warn: idk how to handle, {s}.\n", .{@tagName(t)});
            },
        }
    }
}

// object_begin
// object_end

fn count(input: []const u8) u32 {
    assert(input.len > 0);

    // obj_len + str_len + _str + str_len + obj_beg + obj_end
    const static_len = 4 + 1 + 1 + 1 + 1;
    if (mem.indexOfScalar(u8, input, '/')) |pos| {
        return static_len + @as(u32, @intCast(input[0..pos].len)) + count(input[pos + 1 ..]);
    }

    return static_len + @as(u32, @intCast(input.len));
}

fn write(buf: []u8, input: []const u8) usize {
    assert(input.len > 0);

    const split = input[0..(mem.indexOfScalar(u8, input, '/') orelse input.len)];
    const obj_len = count(input); // just testing, we could just write len direct before ret
    mem.writeInt(u32, buf[0..4], obj_len, native_endian);
    buf[4] = @intCast(split.len);
    @memcpy(buf[5 .. 5 + split.len], split);
    buf[5 + split.len] = @intCast(split.len);
    buf[6 + split.len] = 1;

    var len = split.len + 7;
    if (mem.indexOfScalar(u8, input, '/')) |pos| {
        len += write(buf[len..], input[pos + 1 ..]);
    }

    assert(obj_len == len + 1);

    buf[len] = 0;
    return len + 1;
}

test "hashes algorithm" {
    const files = [_]struct { u64, []const u8 }{
        .{ 0, "some/testing/data/file/a" },
        .{ 0, "some/testing/data/file/b" },
        .{ 0, "some/testing/data/extra/empty" },
        .{ 0, "some/testing/data/file/c" },
    };

    var buf: [16 * 1024]u8 = undefined;
    var buf_end: usize = 0;

    for (files) |v| {
        const hash, const file = v;

        var buf_start: usize = 0;
        var file_start: usize = 0;
        var stack = std.ArrayList(usize).init(std.testing.allocator);
        defer stack.deinit();
        outer: while (file_start != file.len) {
            const split_start = file_start;
            const split_end: usize = if (mem.indexOfScalar(u8, file[file_start..], '/')) |pos| split_start + pos else file.len;
            const split = file[split_start..split_end];

            assert(split.len > 0);

            while (buf_end > buf_start and buf[buf_start] != 0) {
                const obj_len = mem.readInt(u32, buf[buf_start..][0..4], native_endian);
                const str_len = buf[buf_start + 4];
                const str = buf[buf_start + 4 + 1 .. buf_start + 4 + 1 + str_len];

                if (mem.eql(u8, str, split)) {
                    try stack.append(buf_start);
                    buf_start += 4 + 1 + str_len + 1 + 1;
                    file_start += split.len + 1;
                    continue :outer;
                }

                buf_start += @intCast(obj_len);
            }

            std.debug.print("writting: {s}\n", .{file[split_start..]});

            const write_index = buf_start;
            const write_len = count(file[split_start..]);

            assert(buf_end >= write_index);
            if (buf_end > write_index) {
                const src = buf[write_index..buf_end];
                const dst = buf[write_index + write_len .. buf_end + write_len];
                mem.copyBackwards(u8, dst, src);
            }

            const len = write(buf[write_index..], file[split_start..]);

            assert(write_len == len);

            for (stack.items) |frame_start| {
                const frame_len = mem.readInt(u32, buf[frame_start..][0..4], native_endian);
                mem.writeInt(u32, buf[frame_start..][0..4], frame_len + @as(u32, @intCast(len)), native_endian);
            }

            file_start = file.len;
            buf_end += @intCast(len);
        }
        _ = hash;
    }

    std.debug.print("\n", .{});
    std.debug.print("{s}\n", .{buf[0..buf_end]});
    std.debug.print("{d}\n", .{buf[0..buf_end]});
}
