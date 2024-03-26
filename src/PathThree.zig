const std = @import("std");

const mem = std.mem;
const testing = std.testing;
const print = std.debug.print;

const PathThree = @This();
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const Node = struct {
    parent: ?*Node,
    childs: ArrayListUnmanaged(*Node),
    value: []u8,
};

allocator: Allocator,
head: Node,

entires: AutoHashMapUnmanaged(u64, *Node) = AutoHashMapUnmanaged(u64, *Node){},
size: usize = 0,

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
    const parent_node = if (parent == &self.head) null else parent;

    node.* = .{
        .parent = parent_node,
        .childs = ArrayListUnmanaged(*Node){},
        .value = try self.allocator.dupe(u8, value),
    };

    try parent.childs.append(self.allocator, node);
    return parent.childs.getLast();
}

pub fn addFile(self: *PathThree, path: []const u8, hash: u64) !void {
    var it = mem.split(u8, path, "/");
    var node = &self.head;

    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (getNode(node, dir)) |next| {
            node = next;
            continue;
        }

        node = try pushNode(self, node, dir);
    }

    try self.entires.put(self.allocator, hash, node);
}

pub fn getFile(self: PathThree, allocator: Allocator, hash: u64) !?[]u8 {
    var stack = ArrayListUnmanaged([]u8){};
    var stack_size: usize = 0;

    defer stack.deinit(allocator);

    var current = self.entires.get(hash);
    if (current == null) return null;

    while (current) |node| {
        try stack.append(allocator, node.value);
        stack_size += node.value.len;
        current = node.parent;
    }

    var out = try allocator.alloc(u8, stack_size + stack.items.len - 1);

    var i = stack.items.len;
    var filled_i: usize = 0;

    while (i >= 1) : (i -= 1) {
        const item = stack.items[i - 1];

        mem.copy(u8, out[filled_i..], item);
        if (i != 1) out[filled_i + item.len] = '/';

        filled_i += item.len + 1;
    }

    return out;
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
    self.entires.deinit(self.allocator);
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
        try three.addFile(path, i);
    }

    for (0..paths.len) |i| {
        if (try three.getFile(i)) |path| {
            try testing.expectEqualStrings(paths[i], path);
            defer allocator.free(path);
            continue;
        }

        try testing.expect(false);
    }
}
