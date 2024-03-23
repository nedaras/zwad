const std = @import("std");
const wad = @import("wad.zig");
const PathThree = @import("PathThree.zig");

const fs = std.fs;
const fmt = std.fmt;
const print = std.debug.print;

pub fn createDirs(path: []const u8) !void {
    var i: usize = path.len - 1;
    var dir = path;

    while (i >= 1) : (i -= 1) {
        if (path[i] == '/') {
            dir = path[0 .. i + 1];
            break;
        }
    }

    i = 0;
    while (i < dir.len) : (i += 1) {
        if (path[i] == '/') {
            fs.cwd().makeDir(path[0..i]) catch |e| {
                if (e == error.PathAlreadyExists) {
                    //print("{}\n", .{e});
                } else {
                    return e;
                }
            };
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    fs.cwd().makeDir("out") catch |e| {
        if (e == error.PathAlreadyExists) {
            print("{}\n", .{e});
        } else {
            return e;
        }
    };

    // c_allocatpr cuz were like allocating bilion things in there
    var hashes = try wad.importHashes(std.heap.c_allocator, "hashes.txt");
    defer hashes.deinit();

    // it would be nice to know should o have like init deinit functions, like idk todo zig way
    var wad_file = try wad.openFile("Aatrox.wad.client");
    defer wad_file.close();

    while (try wad_file.next()) |entry| {
        const data = try wad_file.decompressEntry(allocator, entry);
        defer allocator.free(data);

        if (try hashes.getPath(entry.hash)) |path| {
            const file_name = try fmt.allocPrint(allocator, "out/{s}", .{path});
            defer allocator.free(file_name);

            print("name: {s}\n", .{file_name});

            try createDirs(file_name);
            fs.cwd().writeFile(file_name, data) catch |e| {
                if (e == error.NameTooLong) {

                    // put that hash inside the dir not in out
                    const file_name_2 = try fmt.allocPrint(allocator, "out/{d}", .{entry.hash});
                    defer allocator.free(file_name_2);

                    _ = try fs.cwd().writeFile(file_name_2, data);
                    print("name: {s}\n", .{file_name_2});
                } else {
                    return e;
                }
            };

            continue;
        }

        const file_name = try fmt.allocPrint(allocator, "out/{d}", .{entry.hash});
        defer allocator.free(file_name);

        _ = try fs.cwd().writeFile(file_name, data);

        print("name: {s}\n", .{file_name});
    }

    print("sizeof PathThree: {}\n", .{@sizeOf(@TypeOf(hashes))});
}
