const std = @import("std");

const mem = std.mem;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;

const PathThree = @This();
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Node = struct {
    parent: ?*Node,
    childs: ArrayListUnmanaged(*Node),
    value: []u8,
};

allocator: Allocator,
head: Node,

pub fn init(allocator: Allocator) PathThree {
    const head: Node = .{
        .parent = null,
        .childs = ArrayListUnmanaged(*Node){},
        .value = "",
    };

    return .{ .allocator = allocator, .head = head };
}

fn getNode(node: *Node, value: []const u8) ?*Node {
    for (node.childs.items) |item| {
        if (mem.eql(u8, item.value, value)) return item;
    }

    return null;
}

fn pushNode(self: *PathThree, parent: *Node, value: []const u8) !*Node {
    var node = try self.allocator.create(Node);
    node.* = .{
        .parent = parent,
        .childs = ArrayListUnmanaged(*Node){},
        .value = try self.allocator.dupe(u8, value),
    };

    try parent.childs.append(self.allocator, node);
    return parent.childs.getLast();
}

pub fn addPath(self: *PathThree, path: []const u8, hash: u64) !void {
    var it = mem.split(u8, path, "/");
    var node = &self.head;

    while (it.next()) |dir| {
        if (getNode(node, dir)) |n| {
            print("hash: {}, allocated: false\n", .{hash});
            node = n;
            continue;
        }

        node = try pushNode(self, node, dir);

        print("hash: {}, allocated: true\n", .{hash});
    }
}

fn deinitNodes(allocator: Allocator, node: *Node) void {
    for (node.childs.items) |item| {
        deinitNodes(allocator, item);
        allocator.free(item.value);
        allocator.destroy(item);
    }

    node.childs.deinit(allocator);
}

pub fn deinit(self: *PathThree) void {
    deinitNodes(self.allocator, &self.head);
}

test "testing path three" {
    const allocator = testing.allocator;
    const paths = [_][]const u8{
        "abc/hhl/cbd/a",
        "abc/hhl/b",
        "abc/cbd/c",
        "abc/Dhd/d",
        "ddf/hhl/e",
        "ddf/hhl/f",
        "ddf/ddf/g",
        "ux/cbd/a",
        "abc/hhl/cbd/x",
    };

    var three = PathThree.init(allocator);
    defer three.deinit();

    for (0.., paths) |i, path| {
        try three.addPath(path, i);
    }

    try expect(true);
}
