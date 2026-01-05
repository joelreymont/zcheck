# quickcheck-zig

A property-based testing library for Zig, inspired by Haskell's QuickCheck and Python's Hypothesis.

## Features

- **Typed generators** for integers, floats, booleans, enums, optionals, arrays, and structs
- **Automatic shrinking** to find minimal counterexamples
- **Reproducible failures** via configurable seeds
- **Environment variable** for CI iteration control

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .quickcheck = .{
        .url = "https://github.com/joelreymont/quickcheck-zig/archive/refs/heads/main.tar.gz",
        .hash = "...", // Update after first fetch
    },
},
```

Then in `build.zig`:

```zig
const quickcheck = b.dependency("quickcheck", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("quickcheck", quickcheck.module("quickcheck"));
```

## Quick Start

```zig
const std = @import("std");
const qc = @import("quickcheck");

test "addition is commutative" {
    try qc.check(struct {
        fn prop(args: struct { a: i32, b: i32 }) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.prop, .{});
}

test "sort is idempotent" {
    try qc.check(struct {
        fn prop(args: struct { arr: [8]u8 }) bool {
            var sorted1 = args.arr;
            var sorted2 = args.arr;

            std.mem.sort(u8, &sorted1, {}, std.sort.asc(u8));
            std.mem.sort(u8, &sorted2, {}, std.sort.asc(u8));
            std.mem.sort(u8, &sorted2, {}, std.sort.asc(u8));

            return std.mem.eql(u8, &sorted1, &sorted2);
        }
    }.prop, .{});
}
```

## Supported Types

The library can generate values for:

| Type | Generator Behavior |
|------|-------------------|
| `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64` | Random values with 20% boundary cases (0, 1, min, max, -1) |
| `f16`, `f32`, `f64` | Random values with 20% special cases (0, 1, -1, min, max) |
| `bool` | Uniform random |
| `enum` | Uniform random over variants |
| `?T` | 50% null, 50% generated value |
| `[N]T` | Array with each element generated |
| `struct` | Each field generated independently |

## Configuration

```zig
try qc.check(myProperty, .{
    .iterations = 1000,      // Number of test cases (default: 100)
    .seed = 12345,           // Fixed seed for reproducibility (default: timestamp)
    .max_shrinks = 200,      // Maximum shrink attempts (default: 100)
    .expect_failure = false, // Pass if property fails (for testing shrinking)
    .silent = false,         // Suppress output on failure
});
```

### Environment Variable

Set `QUICKCHECK_ITERATIONS` to control iteration count without code changes:

```bash
QUICKCHECK_ITERATIONS=10000 zig build test
```

## Shrinking

When a counterexample is found, quickcheck automatically shrinks it toward a minimal failing case:

- **Integers**: Shrink toward 0 by halving
- **Floats**: Shrink toward 0.0 by halving
- **Booleans**: `true` shrinks to `false`
- **Optionals**: `some(x)` shrinks to `null`
- **Arrays**: Elements shrink individually
- **Structs**: Fields shrink individually

Example output:
```
=== Property failed ===
Seed: 1704067200
Iteration: 42
Original: { .x = 12847, .y = -9823 }
Shrunk:   { .x = 1, .y = 0 }
```

## Constrained Generators

For more control over generated values:

```zig
var prng = std.Random.DefaultPrng.init(seed);
const random = prng.random();

// Integer in range [min, max]
const v = qc.intRange(i32, random, -100, 100);

// Random bytes
const b = qc.bytes(16, random);

// Printable ASCII string
const s = qc.asciiString(32, random);

// Choose from specific values
const choices = [_]i32{ 1, 2, 3, 4, 5 };
const c = qc.oneOf(i32, random, &choices);
```

## Running Tests

```bash
# Run library tests
zig build test

# Run with more iterations
QUICKCHECK_ITERATIONS=10000 zig build test

# Run example
zig build example && ./zig-out/bin/example
```

## License

MIT License - see [LICENSE](LICENSE) for details.
