const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const panic = std.debug.panic;

const Config = struct {
    key_count_max: usize,
    debug: bool,
    search: enum { linear, linear_branchless, binary_branchless },
    leaf_order: enum {
        strict,
        lazy, // lazy is broken - need to sort before leaf split
    },
};

pub fn Map(
    comptime Key: type,
    comptime Value: type,
    equal: fn (Key, Key) bool,
    less_than: fn (Key, Key) bool,
    config: Config,
) type {
    comptime {
        if (config.key_count_max < 2) @compileError("config.key_count_max must be at least 2");
    }
    return struct {
        allocator: Allocator,
        root: ChildPtr,
        count: usize,
        depth: usize,

        const ChildPtr = *align(8) void;

        const Branch = extern struct {
            key_count: u8,
            keys: [config.key_count_max]Key,
            children: [config.key_count_max + 1]ChildPtr,
        };

        const Leaf = extern struct {
            key_count: u8,
            keys: [config.key_count_max]Key,
            values: [config.key_count_max]Value,
        };

        const branchSearch = switch (config.search) {
            .linear => linearSearch,
            .linear_branchless => linearSearchBranchless,
            .binary_branchless => binarySearchBranchless,
        };

        const leafSearch = switch (config.leaf_order) {
            .lazy => linearSearch,
            .strict => branchSearch,
        };

        const Self = @This();

        const max_depth = @round(@log2(@as(f64, @floatFromInt(std.math.maxInt(usize)))) / @log2(@as(f64, @floatFromInt(config.key_count_max + 1))));
        const separator_ix = @divFloor(config.key_count_max, 2);

        pub fn init(allocator: Allocator) error{OutOfMemory}!Self {
            // TODO Avoid allocating for empty maps.
            const root = try allocator.create(Leaf);
            root.key_count = 0;
            return .{
                .allocator = allocator,
                .root = @ptrCast(root),
                .count = 0,
                .depth = 0,
            };
        }

        pub fn print(self: *Self, writer: anytype) @TypeOf(writer.print("", .{})) {
            try self.printNode(writer, 0, self.root);
        }

        fn printNode(self: *Self, writer: anytype, depth: usize, child_ptr: ChildPtr) @TypeOf(writer.print("", .{})) {
            try writer.writeByteNTimes(' ', depth * 2);
            if (depth < self.depth) {
                const branch = @as(*Branch, @ptrCast(child_ptr));
                try writer.print("{any}\n", .{branch.keys[0..branch.key_count]});
                for (branch.children[0 .. branch.key_count + 1]) |child| {
                    try self.printNode(writer, depth + 1, child);
                }
            } else {
                const leaf = @as(*Leaf, @ptrCast(child_ptr));
                try writer.print("{any} = {any}\n", .{ leaf.keys[0..leaf.key_count], leaf.values[0..leaf.key_count] });
            }
        }

        pub fn validate(self: *Self) void {
            self.validateNode(0, null, null, self.root);
        }

        fn validateNode(self: *Self, depth: usize, lower_bound: ?Key, upper_bound: ?Key, child_ptr: ChildPtr) void {
            if (depth < self.depth) {
                const branch = @as(*Branch, @ptrCast(child_ptr));
                for (0..branch.key_count - 1) |ix| {
                    assert(less_than(branch.keys[ix], branch.keys[ix + 1]));
                }
                for (branch.keys[0..branch.key_count]) |key| {
                    if (lower_bound != null) assert(less_than(lower_bound.?, key));
                    if (upper_bound != null) assert(!less_than(upper_bound.?, key));
                }
                for (0..branch.key_count + 1) |ix| {
                    const lower_bound_child = if (ix == 0) lower_bound else branch.keys[ix - 1];
                    const upper_bound_child = if (ix == branch.key_count) upper_bound else branch.keys[ix];
                    self.validateNode(depth + 1, lower_bound_child, upper_bound_child, branch.children[ix]);
                }
            } else {
                const leaf = @as(*Leaf, @ptrCast(child_ptr));
                if (self.depth > 0) assert(leaf.key_count >= separator_ix);
                if (leaf.key_count == 0) return;
                if (config.leaf_order == .strict) {
                    for (0..leaf.key_count - 1) |ix| {
                        assert(less_than(leaf.keys[ix], leaf.keys[ix + 1]));
                    }
                }
                for (leaf.keys[0..leaf.key_count]) |key| {
                    if (lower_bound != null) assert(less_than(lower_bound.?, key));
                    if (upper_bound != null) assert(!less_than(upper_bound.?, key));
                }
            }
        }

        pub fn put(self: *Self, key: Key, value: Value) error{OutOfMemory}!enum { inserted, replaced } {
            var parents: [max_depth]*Branch = undefined;
            var parent_ixes: [max_depth]usize = undefined;
            var child_ptr = self.root;
            var depth: usize = 0;
            down: while (true) {
                if (depth < self.depth) {
                    // We are at a branch.
                    const branch = @as(*Branch, @ptrCast(child_ptr));
                    const search_ix = branchSearch(branch.keys[0..branch.key_count], key);
                    parents[depth] = branch;
                    parent_ixes[depth] = search_ix;
                    child_ptr = branch.children[search_ix];
                    depth += 1;
                    continue :down;
                } else {
                    // We are at a leaf.
                    const leaf = @as(*Leaf, @ptrCast(child_ptr));
                    const search_ix = leafSearch(leaf.keys[0..leaf.key_count], key);
                    if (search_ix < leaf.key_count and equal(key, leaf.keys[search_ix])) {
                        leaf.values[search_ix] = value;
                        return .replaced;
                    } else {
                        if (leaf.key_count < config.key_count_max) {
                            if (config.debug) std.debug.print("Insert into leaf\n", .{});
                            switch (config.leaf_order) {
                                .strict => {
                                    insertAt(Key, leaf.keys[0 .. leaf.key_count + 1], key, search_ix);
                                    insertAt(Value, leaf.values[0 .. leaf.key_count + 1], value, search_ix);
                                },
                                .lazy => {
                                    leaf.keys[leaf.key_count] = key;
                                    leaf.values[leaf.key_count] = value;
                                },
                            }
                            leaf.key_count += 1;
                        } else {
                            var separator_key = leaf.keys[separator_ix - 1];
                            const leaf_new = try self.allocator.create(Leaf);
                            if (search_ix < separator_ix) {
                                if (config.debug) std.debug.print("Split leaf left\n", .{});
                                std.mem.copyForwards(Key, leaf_new.keys[0..], leaf.keys[separator_ix..]);
                                std.mem.copyForwards(Value, leaf_new.values[0..], leaf.values[separator_ix..]);
                                insertAt(Key, leaf.keys[0 .. separator_ix + 1], key, search_ix);
                                insertAt(Value, leaf.values[0 .. separator_ix + 1], value, search_ix);
                                leaf.key_count = separator_ix + 1;
                                leaf_new.key_count = config.key_count_max - separator_ix;
                            } else {
                                if (config.debug) std.debug.print("Split leaf right\n", .{});
                                const search_ix_new = search_ix - separator_ix;
                                copyAndInsertAt(Key, leaf_new.keys[0..], leaf.keys[separator_ix..], key, search_ix_new);
                                copyAndInsertAt(Value, leaf_new.values[0..], leaf.values[separator_ix..], value, search_ix_new);
                                leaf.key_count = separator_ix;
                                leaf_new.key_count = config.key_count_max - separator_ix + 1;
                            }
                            // Insert leaf_new into parent.
                            var child = @as(ChildPtr, @ptrCast(leaf));
                            var child_new = @as(ChildPtr, @ptrCast(leaf_new));
                            up: while (true) {
                                if (depth == 0) {
                                    if (config.debug) std.debug.print("Replace root\n", .{});
                                    const root_new = try self.allocator.create(Branch);
                                    root_new.key_count = 1;
                                    root_new.keys[0] = separator_key;
                                    root_new.children[0] = child;
                                    root_new.children[1] = child_new;
                                    self.root = @ptrCast(root_new);
                                    self.depth += 1;
                                    break :up;
                                } else {
                                    depth -= 1;
                                    const parent = parents[depth];
                                    const parent_ix = parent_ixes[depth];
                                    if (parent.key_count < config.key_count_max) {
                                        if (config.debug) std.debug.print("Insert into branch\n", .{});
                                        insertAt(Key, parent.keys[0 .. parent.key_count + 1], separator_key, parent_ix);
                                        insertAt(ChildPtr, parent.children[0 .. parent.key_count + 2], child_new, parent_ix + 1);
                                        parent.key_count += 1;
                                        break :up;
                                    } else {
                                        const separator_key_new = parent.keys[separator_ix];
                                        const parent_new = try self.allocator.create(Branch);
                                        if (parent_ix <= separator_ix) {
                                            if (config.debug) std.debug.print("Split branch left\n", .{});
                                            std.mem.copyForwards(Key, parent_new.keys[0..], parent.keys[separator_ix + 1 ..]);
                                            std.mem.copyForwards(ChildPtr, parent_new.children[0..], parent.children[separator_ix + 1 ..]);
                                            insertAt(Key, parent.keys[0 .. separator_ix + 1], separator_key, parent_ix);
                                            insertAt(ChildPtr, parent.children[0 .. separator_ix + 2], child_new, parent_ix + 1);
                                            parent.key_count = separator_ix + 1;
                                            parent_new.key_count = config.key_count_max - separator_ix - 1;
                                        } else {
                                            if (config.debug) std.debug.print("Split branch right\n", .{});
                                            const parent_ix_new = parent_ix - separator_ix - 1;
                                            copyAndInsertAt(Key, parent_new.keys[0..], parent.keys[separator_ix + 1 ..], separator_key, parent_ix_new);
                                            copyAndInsertAt(ChildPtr, parent_new.children[0..], parent.children[separator_ix + 1 ..], child_new, parent_ix_new + 1);
                                            parent.key_count = separator_ix;
                                            parent_new.key_count = config.key_count_max - separator_ix;
                                        }
                                        separator_key = separator_key_new;
                                        child = @ptrCast(parent);
                                        child_new = @ptrCast(parent_new);
                                        continue :up;
                                    }
                                }
                            }
                        }
                        self.count += 1;
                        return .inserted;
                    }
                }
            }
        }

        pub fn get(self: *Self, key: Key) ?Value {
            var child_ptr = self.root;
            var depth: usize = 0;
            down: while (true) {
                if (depth < self.depth) {
                    // We are at a branch.
                    const branch = @as(*Branch, @ptrCast(child_ptr));
                    const search_ix = branchSearch(branch.keys[0..branch.key_count], key);
                    child_ptr = branch.children[search_ix];
                    depth += 1;
                    continue :down;
                } else {
                    // We are at a leaf.
                    const leaf = @as(*Leaf, @ptrCast(child_ptr));
                    const search_ix = leafSearch(leaf.keys[0..leaf.key_count], key);
                    if (search_ix < leaf.key_count and equal(key, leaf.keys[search_ix])) {
                        return leaf.values[search_ix];
                    } else {
                        return null;
                    }
                }
            }
        }

        fn linearSearch(keys: []Key, search_key: Key) usize {
            for (keys, 0..) |key, ix| {
                if (!less_than(search_key, key)) {
                    return ix;
                }
            } else {
                return keys.len;
            }
        }

        fn linearSearchBranchless(keys: []Key, search_key: Key) usize {
            var result = keys.len;
            var ix = keys.len;
            while (ix > 0) {
                ix -= 1;
                const key = key: {
                    @setRuntimeSafety(false);
                    break :key keys[ix];
                };
                const next_result = [_]usize{ ix, result };
                result = next_result[@intFromBool(less_than(key, search_key))];
            }
            return result;
        }

        fn binarySearchBranchless(keys: []Key, search_key: Key) usize {
            if (keys.len == 0) return 0;
            var offset: usize = 0;
            var length: usize = keys.len;
            while (length > 1) {
                const half = length / 2;
                const mid = offset + half;
                const next_offsets = [_]usize{ offset, mid };
                offset = next_offsets[@intFromBool(less_than(keys[mid], search_key))];
                length -= half;
            }
            offset += @intFromBool(less_than(keys[offset], search_key));
            return offset;
        }

        fn insertAt(comptime Elem: type, elems: []Elem, elem: Elem, ix: usize) void {
            std.mem.copyBackwards(Elem, elems[ix + 1 ..], elems[ix .. elems.len - 1]);
            elems[ix] = elem;
        }

        fn copyAndInsertAt(comptime Elem: type, elems: []Elem, source: []Elem, elem: Elem, ix: usize) void {
            std.mem.copyForwards(Elem, elems, source[0..ix]);
            elems[ix] = elem;
            std.mem.copyForwards(Elem, elems[ix + 1 ..], source[ix..]);
        }
    };
}
