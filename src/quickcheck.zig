//! Property-based testing library for Zig.
//!
//! Provides typed generators with shrinking for finding minimal counterexamples.
//! Inspired by QuickCheck/Hypothesis.
//!
//! ## Basic Usage
//!
//! ```zig
//! const qc = @import("quickcheck");
//!
//! test "addition is commutative" {
//!     try qc.check(struct {
//!         fn property(args: struct { a: i32, b: i32 }) bool {
//!             return args.a + args.b == args.b + args.a;
//!         }
//!     }.property, .{});
//! }
//! ```
//!
//! ## Supported Types
//!
//! The library can generate values for:
//! - Integers (all sizes, signed/unsigned)
//! - Floats (f16, f32, f64)
//! - Booleans
//! - Enums
//! - Optionals
//! - Fixed-size arrays
//! - Structs (composed of supported types)
//!
//! ## Shrinking
//!
//! When a counterexample is found, the library automatically shrinks it
//! toward a minimal failing case. Integers shrink toward zero, arrays
//! shrink element-by-element, and structs shrink field-by-field.
//!
//! ## Configuration
//!
//! ```zig
//! try qc.check(myProperty, .{
//!     .iterations = 1000,      // Number of test cases (default: 100)
//!     .seed = 12345,           // Fixed seed for reproducibility
//!     .max_shrinks = 200,      // Maximum shrink attempts
//! });
//! ```
//!
//! The iteration count can also be set via the `QUICKCHECK_ITERATIONS`
//! environment variable.

const std = @import("std");
const testing = std.testing;

const default_iterations: usize = 100;

/// Configuration for property tests.
pub const Config = struct {
    /// Number of random test cases to generate.
    iterations: usize = 0,
    /// Random seed (0 = use timestamp).
    seed: u64 = 0,
    /// Maximum shrink attempts per failure.
    max_shrinks: usize = 100,
    /// If true, test passes when property fails (for testing shrinking).
    expect_failure: bool = false,
    /// If true, suppress output on failure.
    silent: bool = false,
};

/// Error returned when a property test fails.
pub const PropertyError = error{
    /// A counterexample was found that falsifies the property.
    PropertyFailed,
    /// Expected the property to fail but it passed all iterations.
    ExpectedFailure,
};

/// Run a property test with the given property function.
/// The property function takes a struct of generated values and returns bool.
/// Returns error if a counterexample is found.
pub fn check(comptime property: anytype, config: Config) PropertyError!void {
    const Args = @typeInfo(@TypeOf(property)).@"fn".params[0].type.?;
    return checkType(Args, property, config);
}

fn checkType(comptime Args: type, comptime property: anytype, config: Config) PropertyError!void {
    const iterations = resolveIterations(config.iterations);
    const seed = if (config.seed == 0) blk: {
        break :blk @as(u64, @intCast(std.time.timestamp()));
    } else config.seed;

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const args = generate(Args, random);

        if (!property(args)) {
            // Found counterexample, try to shrink it
            const shrunk = shrinkLoop(Args, property, args, config.max_shrinks);

            if (config.expect_failure) {
                // Test is verifying that shrinking works - success!
                return;
            }

            if (!config.silent) {
                std.debug.print("\n=== Property failed ===\n", .{});
                std.debug.print("Seed: {}\n", .{seed});
                std.debug.print("Iteration: {}\n", .{i});
                std.debug.print("Original: {any}\n", .{args});
                std.debug.print("Shrunk:   {any}\n", .{shrunk});
            }

            return PropertyError.PropertyFailed;
        }
    }

    // If we expected a failure but property always passed, that's an error
    if (config.expect_failure) {
        return PropertyError.ExpectedFailure;
    }
}

fn resolveIterations(iterations: usize) usize {
    if (iterations != 0) return iterations;
    const env = std.process.getEnvVarOwned(std.heap.page_allocator, "QUICKCHECK_ITERATIONS") catch null;
    if (env) |raw| {
        defer std.heap.page_allocator.free(raw);
        const parsed = std.fmt.parseInt(usize, raw, 10) catch return default_iterations;
        if (parsed == 0) return default_iterations;
        return parsed;
    }
    return default_iterations;
}

/// Generate a random value of type T.
pub fn generate(comptime T: type, random: std.Random) T {
    return switch (@typeInfo(T)) {
        .int => generateInt(T, random),
        .float => generateFloat(T, random),
        .bool => random.boolean(),
        .@"enum" => generateEnum(T, random),
        .optional => |opt| if (random.boolean()) generate(opt.child, random) else null,
        .array => |arr| generateArray(arr.child, arr.len, random),
        .@"struct" => |s| generateStruct(T, s, random),
        .pointer => |ptr| switch (ptr.size) {
            .slice => @panic("Cannot generate slices (need allocator)"),
            else => @panic("Cannot generate pointers"),
        },
        else => @compileError("Cannot generate type: " ++ @typeName(T)),
    };
}

fn generateInt(comptime T: type, random: std.Random) T {
    // 20% chance of boundary values
    if (random.uintLessThan(u8, 5) == 0) {
        const boundaries = [_]T{
            0,
            1,
            std.math.maxInt(T),
            if (@typeInfo(T).int.signedness == .signed) std.math.minInt(T) else 0,
            if (@typeInfo(T).int.signedness == .signed) -1 else std.math.maxInt(T),
        };
        return boundaries[random.uintLessThan(usize, boundaries.len)];
    }
    return random.int(T);
}

fn generateFloat(comptime T: type, random: std.Random) T {
    // 20% chance of special values
    if (random.uintLessThan(u8, 5) == 0) {
        const specials = [_]T{ 0.0, 1.0, -1.0, std.math.floatMin(T), std.math.floatMax(T) };
        return specials[random.uintLessThan(usize, specials.len)];
    }
    return @as(T, @floatFromInt(random.int(i32))) / 1000.0;
}

fn generateEnum(comptime T: type, random: std.Random) T {
    const info = @typeInfo(T).@"enum";
    // Generate index at runtime, then map to enum value at comptime
    const idx = random.uintLessThan(usize, info.fields.len);
    return indexToEnum(T, idx);
}

fn indexToEnum(comptime T: type, idx: usize) T {
    const fields = @typeInfo(T).@"enum".fields;
    inline for (fields, 0..) |field, i| {
        if (i == idx) {
            return @enumFromInt(field.value);
        }
    }
    unreachable;
}

fn generateArray(comptime Child: type, comptime len: usize, random: std.Random) [len]Child {
    var result: [len]Child = undefined;
    for (&result) |*elem| {
        elem.* = generate(Child, random);
    }
    return result;
}

fn generateStruct(comptime T: type, comptime s: std.builtin.Type.Struct, random: std.Random) T {
    var result: T = undefined;
    inline for (s.fields) |field| {
        @field(result, field.name) = generate(field.type, random);
    }
    return result;
}

/// Shrink a value toward a simpler form that still fails the property.
fn shrinkLoop(comptime T: type, comptime property: anytype, initial: T, max_attempts: usize) T {
    var current = initial;
    var attempts: usize = 0;

    while (attempts < max_attempts) {
        if (shrinkOnce(T, current)) |simpler| {
            if (!property(simpler)) {
                current = simpler;
                attempts = 0; // Reset on progress
                continue;
            }
        }
        attempts += 1;

        // Try shrinking each field independently for structs
        if (@typeInfo(T) == .@"struct") {
            if (shrinkStructField(T, current, property)) |simpler| {
                current = simpler;
                attempts = 0;
                continue;
            }
        }

        break;
    }

    return current;
}

/// Try to shrink a value one step.
pub fn shrinkOnce(comptime T: type, value: T) ?T {
    return switch (@typeInfo(T)) {
        .int => shrinkInt(T, value),
        .float => shrinkFloat(T, value),
        .bool => if (value) false else null,
        .optional => if (value != null) @as(T, null) else null,
        .array => |arr| shrinkArray(arr.child, arr.len, value),
        .@"struct" => |s| shrinkStruct(T, s, value),
        .@"enum" => null, // Can't shrink enums meaningfully
        else => null,
    };
}

fn shrinkInt(comptime T: type, value: T) ?T {
    if (value == 0) return null;
    if (value > 0) {
        if (value == 1) return 0;
        return @divTrunc(value, 2);
    }
    // Negative: shrink toward 0
    if (value == -1) return 0;
    return @divTrunc(value, 2);
}

fn shrinkFloat(comptime T: type, value: T) ?T {
    if (value == 0.0) return null;
    if (@abs(value) < 0.001) return 0.0;
    return value / 2.0;
}

fn shrinkArray(comptime Child: type, comptime len: usize, value: [len]Child) ?[len]Child {
    // Try to shrink each element
    var result = value;
    for (&result, 0..) |*elem, i| {
        if (shrinkOnce(Child, value[i])) |simpler| {
            elem.* = simpler;
            return result;
        }
    }
    return null;
}

fn shrinkStruct(comptime T: type, comptime s: std.builtin.Type.Struct, value: T) ?T {
    var result = value;
    inline for (s.fields) |field| {
        const field_val = @field(value, field.name);
        if (shrinkOnce(field.type, field_val)) |simpler| {
            @field(result, field.name) = simpler;
            return result;
        }
    }
    return null;
}

fn shrinkStructField(comptime T: type, value: T, comptime property: anytype) ?T {
    const s = @typeInfo(T).@"struct";
    inline for (s.fields) |field| {
        const field_val = @field(value, field.name);
        if (shrinkOnce(field.type, field_val)) |simpler| {
            var candidate = value;
            @field(candidate, field.name) = simpler;
            if (!property(candidate)) {
                return candidate;
            }
        }
    }
    return null;
}

// ============================================================================
// Convenience generators for constrained values
// ============================================================================

/// Generate an integer in a specific range [min, max].
pub fn intRange(comptime T: type, random: std.Random, min: T, max: T) T {
    std.debug.assert(min <= max);
    if (min == max) return min;

    const range: u64 = @intCast(@as(i128, max) - @as(i128, min) + 1);
    const offset: T = @intCast(random.uintLessThan(u64, range));
    return min + offset;
}

/// Generate an array of random bytes.
pub fn bytes(comptime len: usize, random: std.Random) [len]u8 {
    var result: [len]u8 = undefined;
    random.bytes(&result);
    return result;
}

/// Generate a random ASCII string (printable characters).
pub fn asciiString(comptime len: usize, random: std.Random) [len]u8 {
    var result: [len]u8 = undefined;
    for (&result) |*c| {
        c.* = intRange(u8, random, 32, 126); // Printable ASCII
    }
    return result;
}

/// Generate one of the provided values uniformly at random.
pub fn oneOf(comptime T: type, random: std.Random, choices: []const T) T {
    const idx = random.uintLessThan(usize, choices.len);
    return choices[idx];
}

// ============================================================================
// Tests
// ============================================================================

test "generate integers" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const v = generate(i32, random);
        _ = v;
    }

    for (0..100) |_| {
        const v = generate(u64, random);
        _ = v;
    }
}

test "generate floats" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const v = generate(f32, random);
        _ = v;
    }

    for (0..100) |_| {
        const v = generate(f64, random);
        _ = v;
    }
}

test "generate booleans" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var true_count: usize = 0;
    var false_count: usize = 0;

    for (0..1000) |_| {
        if (generate(bool, random)) {
            true_count += 1;
        } else {
            false_count += 1;
        }
    }

    // Should have a reasonable distribution
    try testing.expect(true_count > 400);
    try testing.expect(false_count > 400);
}

test "generate enums" {
    const Color = enum { red, green, blue };

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var counts = [_]usize{ 0, 0, 0 };
    for (0..1000) |_| {
        const c = generate(Color, random);
        counts[@intFromEnum(c)] += 1;
    }

    // Each value should appear at least once
    try testing.expect(counts[0] > 0);
    try testing.expect(counts[1] > 0);
    try testing.expect(counts[2] > 0);
}

test "generate optionals" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var null_count: usize = 0;
    var some_count: usize = 0;

    for (0..1000) |_| {
        const v = generate(?i32, random);
        if (v == null) {
            null_count += 1;
        } else {
            some_count += 1;
        }
    }

    // Should have both null and some values
    try testing.expect(null_count > 100);
    try testing.expect(some_count > 100);
}

test "generate structs" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const Point = struct { x: i32, y: i32 };
    for (0..100) |_| {
        const p = generate(Point, random);
        _ = p;
    }
}

test "generate nested structs" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const Inner = struct { value: u8 };
    const Outer = struct { a: Inner, b: Inner };

    for (0..100) |_| {
        const o = generate(Outer, random);
        _ = o;
    }
}

test "generate arrays" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const arr = generate([4]u8, random);
        _ = arr;
    }
}

test "shrink integers toward zero" {
    try testing.expectEqual(@as(i32, 50), shrinkInt(i32, 100).?);
    try testing.expectEqual(@as(i32, 0), shrinkInt(i32, 1).?);
    try testing.expectEqual(@as(?i32, null), shrinkInt(i32, 0));
    try testing.expectEqual(@as(i32, -50), shrinkInt(i32, -100).?);
    try testing.expectEqual(@as(i32, 0), shrinkInt(i32, -1).?);
}

test "shrink floats toward zero" {
    const shrunk1 = shrinkFloat(f32, 10.0).?;
    try testing.expect(shrunk1 == 5.0);

    const shrunk2 = shrinkFloat(f32, 0.0001).?;
    try testing.expect(shrunk2 == 0.0);

    try testing.expectEqual(@as(?f32, null), shrinkFloat(f32, 0.0));
}

test "shrink booleans" {
    try testing.expectEqual(@as(bool, false), shrinkOnce(bool, true).?);
    try testing.expectEqual(@as(?bool, null), shrinkOnce(bool, false));
}

test "shrink optionals" {
    try testing.expectEqual(@as(?i32, null), shrinkOnce(?i32, @as(?i32, 42)).?);
    try testing.expectEqual(@as(??i32, null), shrinkOnce(?i32, null));
}

test "shrink arrays" {
    const arr = [_]i32{ 10, 20, 30 };
    const shrunk = shrinkOnce([3]i32, arr).?;
    // First element should be shrunk
    try testing.expectEqual(@as(i32, 5), shrunk[0]);
    try testing.expectEqual(@as(i32, 20), shrunk[1]);
    try testing.expectEqual(@as(i32, 30), shrunk[2]);
}

test "shrink structs" {
    const Point = struct { x: i32, y: i32 };
    const p = Point{ .x = 100, .y = 200 };
    const shrunk = shrinkOnce(Point, p).?;
    // First field should be shrunk
    try testing.expectEqual(@as(i32, 50), shrunk.x);
    try testing.expectEqual(@as(i32, 200), shrunk.y);
}

test "check passes for true property" {
    try check(struct {
        fn prop(_: struct { a: u8, b: u8 }) bool {
            return true;
        }
    }.prop, .{ .iterations = 10 });
}

test "check fails for false property" {
    // Use expect_failure to verify shrinking works without printing noise
    try check(struct {
        fn prop(args: struct { a: u8 }) bool {
            return args.a == 0; // Fails for most values
        }
    }.prop, .{ .iterations = 100, .seed = 12345, .expect_failure = true });
}

test "check with custom seed is reproducible" {
    const prop = struct {
        fn prop(args: struct { a: i32 }) bool {
            return args.a != 42;
        }
    }.prop;

    // Same seed should produce same result
    const result1 = check(prop, .{ .seed = 99999, .iterations = 10, .silent = true });
    const result2 = check(prop, .{ .seed = 99999, .iterations = 10, .silent = true });

    try testing.expectEqual(result1, result2);
}

test "intRange generates in bounds" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..1000) |_| {
        const v = intRange(i32, random, -100, 100);
        try testing.expect(v >= -100 and v <= 100);
    }
}

test "intRange with same min and max" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..10) |_| {
        const v = intRange(i32, random, 42, 42);
        try testing.expectEqual(@as(i32, 42), v);
    }
}

test "bytes generates correct length" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const b = bytes(16, random);
    try testing.expectEqual(@as(usize, 16), b.len);
}

test "asciiString generates printable chars" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const s = asciiString(32, random);
        for (s) |c| {
            try testing.expect(c >= 32 and c <= 126);
        }
    }
}

test "oneOf selects from choices" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const choices = [_]i32{ 1, 2, 3, 4, 5 };

    for (0..100) |_| {
        const v = oneOf(i32, random, &choices);
        var found = false;
        for (choices) |c| {
            if (v == c) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "addition is commutative" {
    try check(struct {
        fn prop(args: struct { a: i16, b: i16 }) bool {
            // Use smaller type to avoid overflow issues in test
            const sum1 = @as(i32, args.a) + @as(i32, args.b);
            const sum2 = @as(i32, args.b) + @as(i32, args.a);
            return sum1 == sum2;
        }
    }.prop, .{});
}

test "multiplication is commutative" {
    try check(struct {
        fn prop(args: struct { a: i16, b: i16 }) bool {
            const prod1 = @as(i64, args.a) * @as(i64, args.b);
            const prod2 = @as(i64, args.b) * @as(i64, args.a);
            return prod1 == prod2;
        }
    }.prop, .{});
}

test "array reverse twice is identity" {
    try check(struct {
        fn prop(args: struct { arr: [8]u8 }) bool {
            var reversed1: [8]u8 = undefined;
            var reversed2: [8]u8 = undefined;

            // Reverse once
            for (args.arr, 0..) |v, i| {
                reversed1[7 - i] = v;
            }

            // Reverse again
            for (reversed1, 0..) |v, i| {
                reversed2[7 - i] = v;
            }

            // Should equal original
            return std.mem.eql(u8, &args.arr, &reversed2);
        }
    }.prop, .{});
}
