const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const panic = std.debug.panic;

pub fn Map(
    comptime Key: type,
    comptime Value: type,
    key_count_max: usize,
    order: fn (Key, Key) std.math.Order,
    debug: bool,
) type {
    comptime {
        if (key_count_max < 2) @compileError("key_count_max must be at least 2");
    }
    return struct {
        allocator: Allocator,
        root: ChildPtr,
        count: usize,
        depth: usize,

        const ChildPtr = *align(8) void;

        const Branch = extern struct {
            key_count: u8,
            keys: [key_count_max]Key,
            children: [key_count_max + 1]ChildPtr,
            values: [key_count_max]Value,
        };

        const Leaf = extern struct {
            key_count: u8,
            keys: [key_count_max]Key,
            values: [key_count_max]Value,
        };

        const Self = @This();

        const max_depth = @round(@log2(@as(f64, @floatFromInt(std.math.maxInt(usize)))) / @log2(@as(f64, @floatFromInt(key_count_max + 1))));
        const separator_ix = @divFloor(key_count_max, 2);

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
                try writer.print("{any} = {any}\n", .{ branch.keys[0..branch.key_count], branch.values[0..branch.key_count] });
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
                    assert(order(branch.keys[ix], branch.keys[ix + 1]) == .lt);
                }
                for (branch.keys[0..branch.key_count]) |key| {
                    if (lower_bound != null) assert(order(lower_bound.?, key) == .lt);
                    if (upper_bound != null) assert(order(key, upper_bound.?) == .lt);
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
                for (0..leaf.key_count - 1) |ix| {
                    assert(order(leaf.keys[ix], leaf.keys[ix + 1]) == .lt);
                }
                for (leaf.keys[0..leaf.key_count]) |key| {
                    if (lower_bound != null) assert(order(lower_bound.?, key) == .lt);
                    if (upper_bound != null) assert(order(key, upper_bound.?) == .lt);
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
                    const search = linearSearch(branch.keys[0..branch.key_count], key);
                    switch (search.order) {
                        .eq => {
                            branch.values[search.ix] = value;
                            return .replaced;
                        },
                        .lt => {
                            parents[depth] = branch;
                            parent_ixes[depth] = search.ix;
                            child_ptr = branch.children[search.ix];
                            depth += 1;
                            continue :down;
                        },
                    }
                } else {
                    // We are at a leaf.
                    const leaf = @as(*Leaf, @ptrCast(child_ptr));
                    const search = linearSearch(leaf.keys[0..leaf.key_count], key);
                    switch (search.order) {
                        .eq => {
                            leaf.values[search.ix] = value;
                            return .replaced;
                        },
                        .lt => {
                            if (leaf.key_count < key_count_max) {
                                if (debug) std.debug.print("Insert into leaf\n", .{});
                                insertAt(Key, leaf.keys[0 .. leaf.key_count + 1], key, search.ix);
                                insertAt(Value, leaf.values[0 .. leaf.key_count + 1], value, search.ix);
                                leaf.key_count += 1;
                            } else {
                                var separator_key = leaf.keys[separator_ix];
                                var separator_value = leaf.values[separator_ix];
                                const leaf_new = try self.allocator.create(Leaf);
                                if (search.ix <= separator_ix) {
                                    if (debug) std.debug.print("Split leaf left\n", .{});
                                    std.mem.copyForwards(Key, leaf_new.keys[0..], leaf.keys[separator_ix + 1 ..]);
                                    std.mem.copyForwards(Value, leaf_new.values[0..], leaf.values[separator_ix + 1 ..]);
                                    insertAt(Key, leaf.keys[0 .. separator_ix + 1], key, search.ix);
                                    insertAt(Value, leaf.values[0 .. separator_ix + 1], value, search.ix);
                                    leaf.key_count = separator_ix + 1;
                                    leaf_new.key_count = key_count_max - separator_ix - 1;
                                } else {
                                    if (debug) std.debug.print("Split leaf right\n", .{});
                                    const search_ix_new = search.ix - separator_ix;
                                    copyAndInsertAt(Key, leaf_new.keys[0..], leaf.keys[separator_ix..], key, search_ix_new);
                                    copyAndInsertAt(Value, leaf_new.values[0..], leaf.values[separator_ix..], value, search_ix_new);
                                    leaf.key_count = separator_ix;
                                    leaf_new.key_count = key_count_max - separator_ix + 1;
                                }
                                // Insert leaf_new into parent.
                                var child = @as(ChildPtr, @ptrCast(leaf));
                                var child_new = @as(ChildPtr, @ptrCast(leaf_new));
                                up: while (true) {
                                    if (depth == 0) {
                                        if (debug) std.debug.print("Replace root\n", .{});
                                        const root_new = try self.allocator.create(Branch);
                                        root_new.key_count = 1;
                                        root_new.keys[0] = separator_key;
                                        root_new.values[0] = separator_value;
                                        root_new.children[0] = child;
                                        root_new.children[1] = child_new;
                                        self.root = @ptrCast(root_new);
                                        self.depth += 1;
                                        break :up;
                                    } else {
                                        depth -= 1;
                                        const parent = parents[depth];
                                        const parent_ix = parent_ixes[depth];
                                        if (parent.key_count < key_count_max) {
                                            if (debug) std.debug.print("Insert into branch\n", .{});
                                            insertAt(Key, parent.keys[0 .. parent.key_count + 1], separator_key, parent_ix);
                                            insertAt(Key, parent.values[0 .. parent.key_count + 1], separator_value, parent_ix);
                                            insertAt(ChildPtr, parent.children[0 .. parent.key_count + 2], child_new, parent_ix + 1);
                                            parent.key_count += 1;
                                            break :up;
                                        } else {
                                            const separator_key_new = parent.keys[separator_ix];
                                            const separator_value_new = parent.values[separator_ix];
                                            const parent_new = try self.allocator.create(Branch);
                                            if (parent_ix <= separator_ix) {
                                                if (debug) std.debug.print("Split branch left\n", .{});
                                                std.mem.copyForwards(Key, parent_new.keys[0..], parent.keys[separator_ix + 1 ..]);
                                                std.mem.copyForwards(Value, parent_new.values[0..], parent.values[separator_ix + 1 ..]);
                                                std.mem.copyForwards(ChildPtr, parent_new.children[0..], parent.children[separator_ix + 1 ..]);
                                                insertAt(Key, parent.keys[0 .. separator_ix + 1], separator_key, parent_ix);
                                                insertAt(Value, parent.values[0 .. separator_ix + 1], separator_value, parent_ix);
                                                insertAt(ChildPtr, parent.children[0 .. separator_ix + 2], child_new, parent_ix + 1);
                                                parent.key_count = separator_ix + 1;
                                                parent_new.key_count = key_count_max - separator_ix - 1;
                                            } else {
                                                if (debug) std.debug.print("Split branch right\n", .{});
                                                const parent_ix_new = parent_ix - separator_ix - 1;
                                                copyAndInsertAt(Key, parent_new.keys[0..], parent.keys[separator_ix + 1 ..], separator_key, parent_ix_new);
                                                copyAndInsertAt(Value, parent_new.values[0..], parent.values[separator_ix + 1 ..], separator_value, parent_ix_new);
                                                copyAndInsertAt(ChildPtr, parent_new.children[0..], parent.children[separator_ix + 1 ..], child_new, parent_ix_new + 1);
                                                parent.key_count = separator_ix;
                                                parent_new.key_count = key_count_max - separator_ix;
                                            }
                                            separator_key = separator_key_new;
                                            separator_value = separator_value_new;
                                            child = @ptrCast(parent);
                                            child_new = @ptrCast(parent_new);
                                            continue :up;
                                        }
                                    }
                                }
                            }
                            self.count += 1;
                            return .inserted;
                        },
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
                    const search = linearSearch(branch.keys[0..branch.key_count], key);
                    switch (search.order) {
                        .eq => return branch.values[search.ix],
                        .lt => {
                            child_ptr = branch.children[search.ix];
                            depth += 1;
                            continue :down;
                        },
                    }
                } else {
                    // We are at a leaf.
                    const leaf = @as(*Leaf, @ptrCast(child_ptr));
                    const search = linearSearch(leaf.keys[0..leaf.key_count], key);
                    switch (search.order) {
                        .eq => return leaf.values[search.ix],
                        .lt => return null,
                    }
                }
            }
        }

        const SearchResult = struct {
            ix: usize,
            order: enum { lt, eq },
        };

        fn linearSearch(keys: []Key, search_key: Key) SearchResult {
            var ix: usize = 0;
            for (keys) |key| {
                switch (order(search_key, key)) {
                    .lt => return .{ .ix = ix, .order = .lt },
                    .eq => return .{ .ix = ix, .order = .eq },
                    .gt => ix += 1,
                }
            } else {
                return .{ .ix = ix, .order = .lt };
            }
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
