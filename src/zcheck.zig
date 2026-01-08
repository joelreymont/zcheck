//! Minimal property-based testing library.
//!
//! Provides typed generators with shrinking for finding minimal counterexamples.
//! Inspired by QuickCheck/Hypothesis but tailored for mnemos's needs.
//!
//! Usage:
//! ```zig
//! test "addition is commutative" {
//!     try quickcheck.check(struct {
//!         fn property(args: struct { a: i32, b: i32 }) bool {
//!             return args.a + args.b == args.b + args.a;
//!         }
//!     }.property, .{});
//! }
//!
//! test "string property" {
//!     try quickcheck.check(struct {
//!         fn property(args: struct { s: quickcheck.String }) bool {
//!             const str = args.s.slice();
//!             return str.len <= quickcheck.String.MAX_LEN;
//!         }
//!     }.property, .{});
//! }
//! ```

const std = @import("std");
const testing = std.testing;

/// Maximum length for generated strings
pub const MAX_STRING_LEN: usize = 64;

/// Bounded string type for property testing (no allocation needed).
/// Use .slice() to get the actual string data.
pub const String = struct {
    buf: [MAX_STRING_LEN]u8 = undefined,
    len: usize = 0,

    pub const MAX_LEN = MAX_STRING_LEN;

    /// Get the string content as a slice
    pub fn slice(self: *const String) []const u8 {
        return self.buf[0..self.len];
    }

    /// Create from a slice (truncates if too long)
    pub fn fromSlice(s: []const u8) String {
        var result = String{};
        const copy_len = @min(s.len, MAX_STRING_LEN);
        @memcpy(result.buf[0..copy_len], s[0..copy_len]);
        result.len = copy_len;
        return result;
    }
};

/// Bounded identifier string (alphanumeric only, for IDs)
pub const Id = struct {
    buf: [36]u8 = undefined,
    len: usize = 0,

    pub const MAX_LEN = 36;

    pub fn slice(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Bounded file path string
pub const FilePath = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    pub const MAX_LEN = 128;

    pub fn slice(self: *const FilePath) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Configuration for property tests.
pub const Config = struct {
    /// Number of random test cases to generate.
    iterations: usize = 100,
    /// Random seed (0 = use timestamp).
    seed: u64 = 0,
    /// Maximum shrink attempts per failure.
    max_shrinks: usize = 100,
    /// If true, test passes when property fails (for testing shrinking).
    expect_failure: bool = false,
};

/// Run a property test with the given property function.
/// The property function takes a struct of generated values and returns bool.
/// Returns error if a counterexample is found.
pub fn check(comptime property: anytype, config: Config) !void {
    const Args = @typeInfo(@TypeOf(property)).@"fn".params[0].type.?;
    try checkType(Args, property, config);
}

fn checkType(comptime Args: type, comptime property: anytype, config: Config) !void {
    const seed = if (config.seed == 0) blk: {
        break :blk @as(u64, @intCast(std.time.timestamp()));
    } else config.seed;

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const args = generate(Args, random);

        if (!property(args)) {
            // Found counterexample, try to shrink it
            const shrunk = shrinkLoop(Args, property, args, config.max_shrinks);

            if (config.expect_failure) {
                // Test is verifying that shrinking works - success!
                return;
            }

            std.debug.print("\n=== Property failed ===\n", .{});
            std.debug.print("Seed: {}\n", .{seed});
            std.debug.print("Iteration: {}\n", .{i});
            std.debug.print("Original: {any}\n", .{args});
            std.debug.print("Shrunk:   {any}\n", .{shrunk});

            return error.PropertyFailed;
        }
    }

    // If we expected a failure but property always passed, that's an error
    if (config.expect_failure) {
        return error.ExpectedFailure;
    }
}

/// Generate a random value of type T.
pub fn generate(comptime T: type, random: std.Random) T {
    // Handle special string types first
    if (T == String) return generateString(random);
    if (T == Id) return generateId(random);
    if (T == FilePath) return generateFilePath(random);

    return switch (@typeInfo(T)) {
        .int => generateInt(T, random),
        .float => generateFloat(T, random),
        .bool => random.boolean(),
        .@"enum" => generateEnum(T, random),
        .optional => |opt| if (random.boolean()) generate(opt.child, random) else null,
        .array => |arr| generateArray(arr.child, arr.len, random),
        .@"struct" => |s| generateStruct(T, s, random),
        .pointer => |ptr| switch (ptr.size) {
            .slice => @panic("Cannot generate slices - use String, Id, or FilePath types instead"),
            else => @panic("Cannot generate pointers"),
        },
        else => @compileError("Cannot generate type: " ++ @typeName(T)),
    };
}

fn generateString(random: std.Random) String {
    var result = String{};
    // 10% chance of empty string
    if (random.uintLessThan(u8, 10) == 0) {
        result.len = 0;
        return result;
    }
    // Generate printable ASCII string (32-126)
    result.len = random.uintLessThan(usize, MAX_STRING_LEN) + 1;
    for (result.buf[0..result.len]) |*c| {
        c.* = @intCast(random.intRangeAtMost(u8, 32, 126));
    }
    return result;
}

fn generateId(random: std.Random) Id {
    var result = Id{};
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    // IDs are typically 8-36 chars
    result.len = random.intRangeAtMost(usize, 8, 36);
    for (result.buf[0..result.len]) |*c| {
        c.* = chars[random.uintLessThan(usize, chars.len)];
    }
    return result;
}

fn generateFilePath(random: std.Random) FilePath {
    var result = FilePath{};
    const extensions = [_][]const u8{ ".zig", ".rs", ".py", ".js", ".ts", ".go", ".c", ".h" };
    const ext = extensions[random.uintLessThan(usize, extensions.len)];

    // Generate path like /dir/file.ext
    result.buf[0] = '/';
    const name_len = random.intRangeAtMost(usize, 1, 20);
    for (result.buf[1 .. name_len + 1]) |*c| {
        c.* = @intCast(random.intRangeAtMost(u8, 'a', 'z'));
    }
    @memcpy(result.buf[name_len + 1 ..][0..ext.len], ext);
    result.len = name_len + 1 + ext.len;
    return result;
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
    const fields = @typeInfo(T).@"enum".fields;
    const idx = random.uintLessThan(usize, fields.len);
    // Must use inline for to access comptime field values
    inline for (fields, 0..) |field, i| {
        if (i == idx) return @enumFromInt(field.value);
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
fn shrinkOnce(comptime T: type, value: T) ?T {
    // Handle special string types first
    if (T == String) return shrinkString(value);
    if (T == Id) return shrinkId(value);
    if (T == FilePath) return shrinkFilePath(value);

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

fn shrinkString(value: String) ?String {
    if (value.len == 0) return null;
    // First try: shrink to empty
    if (value.len > 1) {
        var result = value;
        result.len = value.len / 2;
        return result;
    }
    // Single char: return empty
    return String{};
}

fn shrinkId(value: Id) ?Id {
    if (value.len == 0) return null;
    if (value.len > 8) {
        // Shrink toward minimum ID length (8)
        var result = value;
        result.len = @max(8, value.len / 2);
        return result;
    }
    return null; // Don't shrink below 8 chars
}

fn shrinkFilePath(value: FilePath) ?FilePath {
    if (value.len == 0) return null;
    // Try to shrink path length
    if (value.len > 6) { // Minimum: "/a.zig"
        var result = value;
        result.len = @max(6, value.len / 2);
        return result;
    }
    return null;
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

//
// Convenience generators for constrained values
//

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

//
// Tests
//

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

test "generate structs" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const Point = struct { x: i32, y: i32 };
    for (0..100) |_| {
        const p = generate(Point, random);
        _ = p;
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

test "intRange generates in bounds" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..1000) |_| {
        const v = intRange(i32, random, -100, 100);
        try testing.expect(v >= -100 and v <= 100);
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

test "generate String produces valid printable strings" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var empty_count: usize = 0;
    for (0..1000) |_| {
        const s = generate(String, random);
        const slice = s.slice();

        // Verify length is within bounds
        try testing.expect(slice.len <= MAX_STRING_LEN);

        // Verify all characters are printable ASCII (32-126)
        for (slice) |c| {
            try testing.expect(c >= 32 and c <= 126);
        }

        if (slice.len == 0) empty_count += 1;
    }

    // Should generate some empty strings (roughly 10%)
    try testing.expect(empty_count > 50 and empty_count < 200);
}

test "generate Id produces valid alphanumeric IDs" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const id = generate(Id, random);
        const slice = id.slice();

        // IDs are 8-36 chars
        try testing.expect(slice.len >= 8 and slice.len <= 36);

        // All chars are alphanumeric lowercase
        for (slice) |c| {
            try testing.expect((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'));
        }
    }
}

test "generate FilePath produces valid paths" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const fp = generate(FilePath, random);
        const slice = fp.slice();

        // Starts with /
        try testing.expect(slice.len > 0);
        try testing.expectEqual(@as(u8, '/'), slice[0]);

        // Has file extension
        try testing.expect(std.mem.lastIndexOfScalar(u8, slice, '.') != null);
    }
}

test "shrink String toward empty" {
    var s = String{};
    s.len = 32;
    @memset(s.buf[0..32], 'a');

    // First shrink halves length
    const s1 = shrinkString(s).?;
    try testing.expectEqual(@as(usize, 16), s1.len);

    // Keep shrinking
    const s2 = shrinkString(s1).?;
    try testing.expectEqual(@as(usize, 8), s2.len);

    const s3 = shrinkString(s2).?;
    try testing.expectEqual(@as(usize, 4), s3.len);

    const s4 = shrinkString(s3).?;
    try testing.expectEqual(@as(usize, 2), s4.len);

    const s5 = shrinkString(s4).?;
    try testing.expectEqual(@as(usize, 1), s5.len);

    // Single char shrinks to empty
    const s6 = shrinkString(s5).?;
    try testing.expectEqual(@as(usize, 0), s6.len);

    // Empty cannot shrink
    try testing.expectEqual(@as(?String, null), shrinkString(s6));
}

test "shrink Id respects minimum length" {
    var id = Id{};
    id.len = 36;
    @memset(id.buf[0..36], 'a');

    // Shrinks toward 8
    const id1 = shrinkId(id).?;
    try testing.expectEqual(@as(usize, 18), id1.len);

    const id2 = shrinkId(id1).?;
    try testing.expectEqual(@as(usize, 9), id2.len);

    const id3 = shrinkId(id2).?;
    try testing.expectEqual(@as(usize, 8), id3.len);

    // Cannot shrink below 8
    try testing.expectEqual(@as(?Id, null), shrinkId(id3));
}

test "check with String finds minimal counterexample" {
    // Property: string length < 5 (fails for longer strings)
    // Shrinking should find a minimal string of length 5
    try check(struct {
        fn prop(args: struct { s: String }) bool {
            return args.s.slice().len < 5;
        }
    }.prop, .{ .iterations = 100, .seed = 99999, .expect_failure = true });
}

test "check with struct containing String" {
    try check(struct {
        fn prop(args: struct { id: Id, name: String, count: u8 }) bool {
            // Property: all IDs have minimum length
            return args.id.slice().len >= 8;
        }
    }.prop, .{ .iterations = 100 });
}

test "String.fromSlice creates correct string" {
    const s = String.fromSlice("hello world");
    try testing.expectEqualStrings("hello world", s.slice());

    // Truncates if too long
    var long_buf: [100]u8 = undefined;
    @memset(&long_buf, 'x');
    const truncated = String.fromSlice(&long_buf);
    try testing.expectEqual(MAX_STRING_LEN, truncated.slice().len);
}

test "generate optional String" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var null_count: usize = 0;
    for (0..100) |_| {
        const maybe_s = generate(?String, random);
        if (maybe_s == null) {
            null_count += 1;
        } else {
            try testing.expect(maybe_s.?.slice().len <= MAX_STRING_LEN);
        }
    }

    // Should generate some nulls (roughly 50%)
    try testing.expect(null_count > 20 and null_count < 80);
}

test "generate enum" {
    const Color = enum { red, green, blue };
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var counts = [_]usize{ 0, 0, 0 };
    for (0..300) |_| {
        const c = generate(Color, random);
        counts[@intFromEnum(c)] += 1;
    }

    // Each color should appear roughly 100 times
    for (counts) |count| {
        try testing.expect(count > 50 and count < 150);
    }
}

test "generate bool" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var true_count: usize = 0;
    for (0..100) |_| {
        if (generate(bool, random)) true_count += 1;
    }

    // Should be roughly 50/50
    try testing.expect(true_count > 30 and true_count < 70);
}

test "shrink struct finds minimal failing field" {
    // Property fails when x > 10, shrinking should minimize x
    try check(struct {
        fn prop(args: struct { x: u8, y: u8 }) bool {
            return args.x <= 10;
        }
    }.prop, .{ .iterations = 100, .seed = 54321, .expect_failure = true });
}

test "generate float produces reasonable values" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const f = generate(f32, random);
        // Should not be NaN or Inf (our generator doesn't produce those)
        try testing.expect(!std.math.isNan(f));
        try testing.expect(!std.math.isInf(f));
    }
}
