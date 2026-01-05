# AGENTS.md - Guidelines for AI Agents

## Project Overview

**quickcheck-zig** is a property-based testing library for Zig. It generates random test inputs and automatically shrinks failing cases to minimal counterexamples.

## Architecture

```
src/
  quickcheck.zig    # Main library - generators, shrinking, check() API
  example.zig       # Usage examples
```

### Core Components

1. **`check()`** - Main entry point. Takes a property function and config, runs iterations.
2. **`generate()`** - Type-driven random value generation. Handles integers, floats, bools, enums, optionals, arrays, structs.
3. **`shrinkOnce()`** / **`shrinkLoop()`** - Shrinking logic to find minimal counterexamples.
4. **Constrained generators** - `intRange()`, `bytes()`, `asciiString()`, `oneOf()` for controlled generation.

## Key Design Decisions

- **Comptime type inspection**: Uses `@typeInfo` to generate values for arbitrary types
- **No allocator needed**: Fixed-size types only (no slices/dynamic arrays)
- **Boundary value bias**: 20% chance of generating edge cases (0, 1, max, min)
- **Shrinking strategy**: Binary search toward zero for numbers, null for optionals

## Contribution Guidelines

### Adding New Generators

To support a new type:

1. Add case to `generate()` switch
2. Add corresponding shrink case to `shrinkOnce()`
3. Add tests for both generation and shrinking

### Test Coverage Requirements

- Every generator must have a generation test
- Every shrink strategy must have a shrink test
- Property tests should use `.seed` for reproducibility in CI

### Code Style

- Follow Zig stdlib conventions
- Use `comptime` parameters for type-level operations
- Prefer inline switch/if for type dispatch
- Document public functions with `///` doc comments

## Common Tasks

### Run Tests
```bash
zig build test
```

### Run Tests with High Iteration Count
```bash
QUICKCHECK_ITERATIONS=10000 zig build test
```

### Add a New Constrained Generator

1. Add function to "Convenience generators" section
2. Add test in "Tests" section
3. Document in README.md

## Known Limitations

- Cannot generate slices (would need allocator)
- Cannot generate pointers
- Enum shrinking is a no-op (no meaningful ordering)
- Union types not supported

## Future Enhancements (if needed)

- Allocator-backed generators for dynamic types
- Stateful property testing
- Coverage-guided generation
- Custom shrink strategies via user callbacks
