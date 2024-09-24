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
    lookup_miss: Bins,
    lookup_hit: Bins,

    fn init(allocator: Allocator, log_count: usize) !Metrics {
        return .{
            .insert_miss = try Bins.init(allocator, log_count),
            .insert_hit = try Bins.init(allocator, log_count),
            .lookup_miss = try Bins.init(allocator, log_count),
            .lookup_hit = try Bins.init(allocator, log_count),
        };
    }
};

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
    a: u64,

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

fn bench_one(map: anytype, rng_init: anytype, log_count: usize, metrics: Metrics) !void {
    if (map.count() != 0) panic("Non-empty map", .{});

    const count = @as(usize, 1) << @intCast(log_count);

    var rng = rng_init;
    for (0..count) |_| {
        const k = rng.next();
        if (debug) {
            std.debug.print("writing {}, count = {}, depth = {}\n", .{ k, map.count, map.depth });
        }

        const before = rdtscp();
        _ = try map.put(k, k);
        const after = rdtscp();
        metrics.insert_miss.get(map.count()).add(after - before);

        if (debug) {
            try map.print(std.io.getStdErr().writer());
            map.validate();
        }
        //if (map.count() != count) {
        //    std.debug.print("Warning: {} duplicate keys\n", .{count - map.count()});
        //}
    }

    if (@hasDecl(@TypeOf(map.*), "validate")) map.validate();

    rng = rng_init;
    const count_before = map.count();
    for (0..count) |_| {
        const k = rng.next();
        if (debug) {
            std.debug.print("writing {}, count = {}, depth = {}\n", .{ k, map.count, map.depth });
        }

        const before = rdtscp();
        _ = try map.put(k, k);
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

    rng = rng_init;
    for (0..count) |_| {
        const k = rng.next();

        const before = rdtscp();
        const v = map.get(k);
        const after = rdtscp();
        metrics.lookup_hit.get(map.count()).add(after - before);

        if (v == null or v.? != k) {
            panic("map.get({}) == {?}", .{ k, v });
        }
    }

    // don't reinit rng
    for (0..count) |_| {
        const k = rng.next();

        const before = rdtscp();
        const v = map.get(k);
        const after = rdtscp();
        metrics.lookup_miss.get(map.count()).add(after - before);

        if (v != null) {
            panic("map.get({}) == {?}", .{ k, v });
        }
    }
}

fn bench(allocator: Allocator, comptime Map: type, rng_init: anytype, log_count: usize) !void {
    std.debug.print("{s} {s}\n", .{ @typeName(Map), @typeName(@TypeOf(rng_init)) });
    const metrics = try Metrics.init(allocator, log_count);
    for (0..log_count) |log_count_one| {
        // Try to get roughly `1 << log_count` samples per bin.
        for (0..@as(usize, 1) << @intCast(log_count - log_count_one)) |_| {
            const map_or_err = Map.init(allocator);
            var map = if (@typeInfo(@TypeOf(map_or_err)) == .ErrorUnion) try map_or_err else map_or_err;
            defer map.deinit();

            try bench_one(&map, rng_init, log_count_one, metrics);
        }
    }
    inline for (@typeInfo(Metrics).Struct.fields) |field| {
        const bins = @field(metrics, field.name);
        std.debug.print("{s: <11} min =", .{field.name});
        for (bins.bins) |bin| {
            std.debug.print(" {: >8}", .{bin.min});
        }
        std.debug.print("\n", .{});
        std.debug.print("{s: <11} avg =", .{""});
        for (bins.bins) |bin| {
            std.debug.print(" {: >8}", .{bin.mean()});
        }
        std.debug.print("\n", .{});
        std.debug.print("{s: <11} max =", .{""});
        for (bins.bins) |bin| {
            std.debug.print(" {: >8}", .{bin.max});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const log_count = 20;
    inline for (&.{
        //Ascending{},
        //Descending{},
        XorShift64{},
    }) |rng| {
        //inline for (&.{11}) |key_count_max| {
        //    var map = try btree.Map(u64, u64, key_count_max, order, debug).init(allocator);
        //    try bench(&map, rng);
        //}
        inline for (&.{
            15,
            //31,
            //63,
            //127,
        }) |branch_key_count_max| {
            inline for (&.{
                15,
                //31,
                //63,
                //127,
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
                            try bench(allocator, Map, rng, log_count);
                        }
                    }
                }
            }
        }
        {
            const Map = btree.Map(u64, u64, equal, less_than, 127, debug);
            try bench(allocator, Map, rng, log_count);
        }
        if (!debug) {
            {
                const Map = std.HashMap(u64, u64, SipHashContext, std.hash_map.default_max_load_percentage);
                try bench(allocator, Map, rng, log_count);
            }
            {
                const Map = std.AutoHashMap(u64, u64);
                try bench(allocator, Map, rng, log_count);
            }
        }
        std.debug.print("\n", .{});
    }
}
