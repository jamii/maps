const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const panic = std.debug.panic;

const btree = @import("btree.zig");
const bptree = @import("bptree.zig");

const debug = false;

inline fn rdtscp() u64 {
    var hi: u64 = undefined;
    var low: u64 = undefined;
    asm volatile ("rdtscp"
        : [low] "={eax}" (low),
          [hi] "={edx}" (hi),
        :
        : "ecx"
    );
    return (@as(u64, hi) << 32) | @as(u64, low);
}

const Bin = struct {
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    sum: u64 = 0,
    count: u64 = 0,

    fn add(self: *Bin, measurement: u64) void {
        self.min = @min(self.min, measurement);
        self.max = @max(self.max, measurement);
        self.sum += measurement;
        self.count += 1;
    }

    fn mean(self: Bin) u64 {
        return std.math.divCeil(u64, self.sum, self.count) catch unreachable;
    }
};

const Bins = struct {
    bins: []Bin,

    fn init(allocator: Allocator, log_count: usize) !Bins {
        const bins = try allocator.alloc(Bin, log_count);
        for (bins) |*bin| bin.* = Bin{};
        return .{ .bins = bins };
    }

    fn get(self: Bins, map_count: usize) *Bin {
        return &self.bins[std.math.log2_int_ceil(usize, map_count)];
    }
};

const Metrics = struct {
    insert_miss: Bins,
    insert_hit: Bins,
    lookup_all: Bins,
    lookup_miss: Bins,
    lookup_miss_batch: Bins,
    lookup_hit: Bins,
    lookup_hit_batch: Bins,
    lookup_hit_chain: Bins,
    free: Bins,

    fn init(allocator: Allocator, log_count: usize) !Metrics {
        return .{
            .insert_miss = try Bins.init(allocator, log_count),
            .insert_hit = try Bins.init(allocator, log_count),
            .lookup_all = try Bins.init(allocator, log_count),
            .lookup_miss = try Bins.init(allocator, log_count),
            .lookup_miss_batch = try Bins.init(allocator, log_count),
            .lookup_hit = try Bins.init(allocator, log_count),
            .lookup_hit_batch = try Bins.init(allocator, log_count),
            .lookup_hit_chain = try Bins.init(allocator, log_count),
            .free = try Bins.init(allocator, log_count),
        };
    }
};

const batch_size = 256;

pub const XorShift64 = struct {
    a: u64 = 123456789,

    pub fn next(self: *XorShift64) u64 {
        var b = self.a;
        b ^= b << 13;
        b ^= b >> 7;
        b ^= b << 17;
        self.a = b;
        return b;
    }
};

pub const Ascending = struct {
    a: u64 = 0,

    pub fn next(self: *Ascending) u64 {
        const b = self.a;
        self.a += 1;
        return b;
    }
};

pub const Descending = struct {
    a: u64 = std.math.maxInt(u64),

    pub fn next(self: *Descending) u64 {
        const b = self.a;
        self.a -= 1;
        return b;
    }
};

fn equal(a: u64, b: u64) bool {
    return a == b;
}

fn less_than(a: u64, b: u64) bool {
    return a < b;
}

fn order(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

const SipHashContext = struct {
    pub fn hash(ctx: SipHashContext, key: u64) u64 {
        _ = ctx;
        var hasher = std.crypto.auth.siphash.SipHash64(2, 4).init("0x128dad08f12307");
        hasher.update(std.mem.asBytes(&key));
        return hasher.finalInt();
    }

    pub fn eql(ctx: SipHashContext, a: u64, b: u64) bool {
        _ = ctx;
        return a == b;
    }
};

fn bench_one(map: anytype, rng: anytype, log_count: usize, metrics: Metrics) !void {
    if (map.count() != 0) panic("Non-empty map", .{});

    const count = @as(usize, 1) << @intCast(log_count);

    const keys = try map.allocator.alloc(u64, count);
    defer map.allocator.free(keys);
    for (keys) |*key| key.* = rng.next();

    const values = try map.allocator.alloc(u64, count);
    defer map.allocator.free(values);
    for (values) |*value| value.* = rng.next();

    const keys_missing = try map.allocator.alloc(u64, @max(batch_size, count));
    defer map.allocator.free(keys_missing);
    for (keys_missing) |*key| key.* = rng.next();

    const keys_hitting = try map.allocator.alloc(u64, @max(batch_size, count));
    defer map.allocator.free(keys_hitting);
    const values_hitting = try map.allocator.alloc(u64, @max(batch_size, count));
    defer map.allocator.free(values_hitting);
    for (keys_hitting, values_hitting) |*key, *value| {
        const i = rng.next() % count;
        key.* = keys[i];
        value.* = values[i];
    }

    for (keys, values) |key, value| {
        if (debug) {
            std.debug.print("writing {}, count = {}, depth = {}\n", .{ key, map.count, map.depth });
        }

        const before = rdtscp();
        _ = try map.put(key, value);
        const after = rdtscp();
        metrics.insert_miss.get(map.count()).add(after - before);

        if (debug) {
            try map.print(std.io.getStdErr().writer());
            map.validate();
        }
    }

    if (@hasDecl(@TypeOf(map.*), "validate")) map.validate();

    const count_before = map.count();
    for (keys, values) |key, value| {
        if (debug) {
            std.debug.print("writing {}, count = {}, depth = {}\n", .{ key, map.count, map.depth });
        }

        const before = rdtscp();
        _ = try map.put(key, value);
        const after = rdtscp();
        metrics.insert_hit.get(map.count()).add(after - before);

        if (debug) {
            try map.print(std.io.getStdErr().writer());
            map.validate();
        }
    }
    const count_after = map.count();
    if (count_before != count_after) {
        panic("Reinserted {} keys", .{count_after - count_before});
    }

    {
        const before = rdtscp();
        for (keys) |key| {
            const value_found = map.get(key);
            if (value_found == null) {
                panic("Value not found", .{});
            }
        }
        const after = rdtscp();
        metrics.lookup_all.get(map.count()).add(@divTrunc(after - before, count));
    }

    for (keys_hitting) |key| {
        const before = rdtscp();
        const value_found = map.get(key);
        const after = rdtscp();
        metrics.lookup_hit.get(map.count()).add(after - before);

        if (value_found == null) {
            panic("Value not found", .{});
        }
    }

    for (0..@divTrunc(keys_hitting.len, batch_size)) |batch| {
        const keys_batch = keys_hitting[batch * batch_size ..][0..batch_size];
        var values_found: [batch_size]?u64 = undefined;

        const before = rdtscp();
        var key: u64 = keys_batch[0];
        for (&values_found, 0..) |*value, i| {
            value.* = map.get(key);
            key = keys_batch[(i + 1) % keys_batch.len];
        }
        const after = rdtscp();
        metrics.lookup_hit_batch.get(map.count()).add(@divTrunc(after - before, batch_size));

        for (values_found) |value_found| {
            if (value_found == null) {
                panic("Value not found", .{});
            }
        }
    }

    for (0..@divTrunc(keys_hitting.len, batch_size)) |batch| {
        const keys_batch = keys_hitting[batch * batch_size ..][0..batch_size];
        var values_found: [batch_size]?u64 = undefined;

        const before = rdtscp();
        var key: u64 = keys_batch[0];
        for (&values_found, 0..) |*value, i| {
            value.* = map.get(key);
            key = keys_batch[(i + value.*.?) % keys_batch.len];
        }
        const after = rdtscp();
        metrics.lookup_hit_chain.get(map.count()).add(@divTrunc(after - before, batch_size));

        for (values_found) |value_found| {
            if (value_found == null) {
                panic("Value not found", .{});
            }
        }
    }

    for (keys_missing) |key| {
        const before = rdtscp();
        const value_found = map.get(key);
        const after = rdtscp();
        metrics.lookup_miss.get(map.count()).add(after - before);

        if (value_found != null) {
            panic("Value found", .{});
        }
    }

    for (0..@max(1, @divTrunc(keys_missing.len, batch_size))) |batch| {
        const keys_batch = keys_missing[batch * batch_size ..][0..batch_size];
        var values_found: [batch_size]?u64 = undefined;

        const before = rdtscp();
        var i: usize = 0;
        for (&values_found) |*value| {
            value.* = map.get(keys_batch[i]);
            i += 1;
        }
        const after = rdtscp();
        metrics.lookup_miss_batch.get(map.count()).add(@divTrunc(after - before, batch_size));

        for (values_found) |value_found| {
            if (value_found != null) {
                panic("Value found", .{});
            }
        }
    }
}

fn bench(allocator: Allocator, comptime Map: type, rng_init: anytype, log_count_max: usize) !void {
    std.debug.print("{s} {s}\n", .{ @typeName(Map), @typeName(@TypeOf(rng_init)) });
    const metrics = try Metrics.init(allocator, log_count_max);
    var rng = rng_init;
    for (0..log_count_max) |log_count| {
        // Try to get roughly `1 << log_count` samples per bin.
        for (0..@as(usize, 1) << @intCast(log_count_max - log_count)) |_| {
            const map_or_err = Map.init(allocator);
            var map = if (@typeInfo(@TypeOf(map_or_err)) == .ErrorUnion) try map_or_err else map_or_err;
            try bench_one(&map, &rng, log_count, metrics);

            const before = rdtscp();
            map.deinit();
            const after = rdtscp();
            metrics.free.get(map.count()).add(after - before);
        }
    }

    std.debug.print("len =", .{});
    for (0..log_count_max) |log_count| {
        std.debug.print(" {: >8}", .{log_count});
    }
    std.debug.print("\n", .{});
    inline for (@typeInfo(Metrics).Struct.fields) |field| {
        const bins = @field(metrics, field.name);
        std.debug.print("{s}:\n", .{field.name});
        std.debug.print("min =", .{});
        for (bins.bins) |bin| {
            if (bin.count == 0) {
                std.debug.print(" {s: >8}", .{"-"});
            } else {
                std.debug.print(" {: >8}", .{bin.min});
            }
        }
        std.debug.print("\n", .{});
        std.debug.print("avg =", .{});
        for (bins.bins) |bin| {
            if (bin.count == 0) {
                std.debug.print(" {s: >8}", .{"-"});
            } else {
                std.debug.print(" {: >8}", .{bin.mean()});
            }
        }
        std.debug.print("\n", .{});
        std.debug.print("max =", .{});
        for (bins.bins) |bin| {
            if (bin.count == 0) {
                std.debug.print(" {s: >8}", .{"-"});
            } else {
                std.debug.print(" {: >8}", .{bin.max});
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const log_count_max = 17;
    inline for (&.{
        //Ascending{},
        //Descending{},
        XorShift64{},
    }) |rng_init| {
        //inline for (&.{11}) |key_count_max| {
        //    var map = try btree.Map(u64, u64, key_count_max, order, debug).init(allocator);
        //    try bench(&map, rng);
        //}
        inline for (&.{
            11,
            //15,
            //31,
            //63,
            //127,
        }) |branch_key_count_max| {
            inline for (&.{
                //15,
                //31,
                //63,
                //127,
                branch_key_count_max,
            }) |leaf_key_count_max| {
                inline for (&.{
                    //.dynamic,
                    .linear,
                    //.binary,
                }) |branch_search| {
                    inline for (&.{
                        //.dynamic,
                        .linear,
                        //.linear_lazy,
                        //.binary,
                    }) |leaf_search| {
                        inline for (&.{
                            1,
                            //2,
                            //4,
                            //8,
                            //16,
                            //32,
                        }) |search_dynamic_cutoff| {
                            if (branch_search != .dynamic and leaf_search != .dynamic and search_dynamic_cutoff > 1) continue;
                            const Map = bptree.Map(u64, u64, equal, less_than, .{
                                .branch_key_count_max = branch_key_count_max,
                                .leaf_key_count_max = leaf_key_count_max,
                                .branch_search = branch_search,
                                .leaf_search = leaf_search,
                                .search_dynamic_cutoff = search_dynamic_cutoff,
                                .debug = debug,
                            });
                            try bench(allocator, Map, rng_init, log_count_max);
                        }
                    }
                }
            }
        }
        inline for (&.{
            11,
            //15,
            //31,
            //63,
            //127,
        }) |key_count_max| {
            const Map = btree.Map(u64, u64, equal, less_than, key_count_max, debug);
            try bench(allocator, Map, rng_init, log_count_max);
        }
        if (!debug) {
            {
                const Map = std.HashMap(u64, u64, SipHashContext, std.hash_map.default_max_load_percentage);
                try bench(allocator, Map, rng_init, log_count_max);
            }
            {
                const Map = std.AutoHashMap(u64, u64);
                try bench(allocator, Map, rng_init, log_count_max);
            }
        }
        std.debug.print("\n", .{});
    }
}
