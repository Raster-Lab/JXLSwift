# Contributing to JXLSwift

Thank you for your interest in contributing to JXLSwift! This document provides guidelines for contributing to the project.

## Development Environment

### Requirements
- Swift 6.2 or later
- Xcode 16.0+ (for macOS/iOS development)
- Access to Apple Silicon hardware recommended for testing optimizations

### Setup
```bash
git clone https://github.com/Raster-Lab/JXLSwift.git
cd JXLSwift
swift build
swift test
```

## Code Organization

The project is organized into several modules:

- **Core/**: Fundamental data structures and types
- **Encoding/**: Compression pipeline implementation
- **Hardware/**: Platform-specific optimizations
- **Format/**: JPEG XL file format support (future)

## Coding Guidelines

### British English Style Guide

JXLSwift uses **British English** throughout all source code comments, documentation,
error messages, and CLI help text. Please follow these conventions when contributing.

#### Preferred spellings

| ✅ British (use this) | ❌ American (avoid) |
|----------------------|---------------------|
| colour               | color               |
| colour space         | color space         |
| optimise             | optimize            |
| organisation         | organization        |
| serialise            | serialize           |
| initialise           | initialize          |
| synchronise          | synchronize         |
| recognise            | recognize           |
| behaviour            | behavior            |
| neighbour            | neighbor            |
| centre               | center              |

#### Exceptions — identifiers that keep American spellings

Swift standard library, Apple framework, and ArgumentParser **identifiers** retain
their canonical American spelling because they are not under our control:

- `ColorSpace`, `colorSpace` (note: `ColourSpace` is already used as a spec-level enum in the codebase)
- `ColorPrimaries` (public API, mirrored by the `ColourPrimaries` British alias)
- `CGColor`, `UIColor`, `NSColor`, `NSColorSpace`
- `EncodingOptions`, `CompressionMode` (stable public API, unchanged for backward compat.)

The British-English **type alias** `ColourPrimaries` is provided in
`Sources/JXLSwift/Core/BritishSpelling.swift` alongside the American `ColorPrimaries`.

#### Checking spelling

Run the spelling checker from the repo root:

```bash
./scripts/check-spelling.sh            # report issues
./scripts/check-spelling.sh --fix      # auto-fix issues (review with git diff)
```

CI runs this check automatically on every pull request.

### Swift Style
- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and concise

### Architecture-Specific Code
When adding platform-specific code, use conditional compilation:

```swift
#if arch(arm64)
    // Apple Silicon / ARM optimisations
    func optimisedOperation() { ... }
#elseif arch(x86_64)
    // x86-64 fallback
    func optimisedOperation() { ... }
#endif
```

### Performance
- Profile before optimizing
- Document performance characteristics
- Add benchmarks for critical paths
- Consider memory usage

## Testing

### Running Tests
```bash
swift test                    # Run all tests
swift test --filter <name>    # Run specific test
```

### Writing Tests
- Add tests for new features
- Test both ARM64 and x86-64 paths
- Include performance benchmarks
- Test edge cases and error conditions

### Test Coverage
Aim for good test coverage, especially for:
- Core compression algorithms
- Platform-specific optimizations
- Error handling
- Edge cases

## Pull Request Process

1. **Fork the repository**
2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**
   - Write clean, documented code
   - Add tests
   - Update `README.md` and `MILESTONES.md` (see [Documentation Updates](#documentation-updates-on-feature-changes) below)

4. **Test thoroughly**
   ```bash
   swift test
   swift build --configuration release
   ```

5. **Commit with clear messages**
   ```bash
   git commit -m "Add feature: brief description"
   ```

6. **Push and create PR**
   ```bash
   git push origin feature/your-feature-name
   ```

7. **PR Description**
   - Describe what changes you made
   - Explain why the changes are needed
   - Reference any related issues
   - Include performance impact if applicable

## Areas for Contribution

### High Priority
- [ ] Complete ANS entropy coding implementation
- [ ] Metal GPU acceleration
- [ ] Progressive encoding support
- [ ] Additional DCT optimizations
- [ ] Memory usage optimization

### Medium Priority
- [ ] JPEG XL file format (.jxl) support
- [ ] Metadata handling (EXIF, XMP)
- [ ] Animation support
- [ ] Additional color space support
- [ ] Better error messages

### Low Priority
- [ ] Decoding support
- [ ] Additional documentation
- [ ] More examples
- [ ] Performance benchmarks
- [ ] Cross-platform testing

## Hardware-Specific Contributions

### Apple Silicon (ARM NEON)
When contributing ARM NEON optimizations:
- Use Accelerate framework when possible
- Document performance gains
- Provide fallback implementations
- Test on real hardware

### x86-64
While x86-64 support may be removed in the future:
- Keep code separate from ARM code
- Use `#if arch(x86_64)` guards
- Document that it may be deprecated

### Metal GPU
For Metal contributions:
- Ensure graceful fallback to CPU
- Document GPU memory usage
- Consider power/thermal impact
- Test on various Apple GPU generations

## Performance Benchmarking

When adding optimizations:

1. **Measure baseline performance**
   ```swift
   measure {
       // Your code here
   }
   ```

2. **Document improvements**
   - Speedup factor
   - Memory impact
   - Platform specifics

3. **Compare across platforms**
   - Apple Silicon
   - x86-64
   - Different generations

## Documentation

### Code Documentation
Use Swift documentation comments:
```swift
/// Brief description of function
///
/// Detailed explanation if needed.
///
/// - Parameters:
///   - param1: Description
///   - param2: Description
/// - Returns: Description
/// - Throws: Description of errors
public func myFunction(param1: Type, param2: Type) throws -> ReturnType {
    // Implementation
}
```

### README Updates
Update README.md when:
- Adding new features
- Changing API
- Adding examples
- Updating requirements

### MILESTONES Updates
Update MILESTONES.md when:
- Completing a deliverable (check it off with `- [x]`)
- Completing a required test (check it off with `- [x]`)
- Changing a milestone status (⬜ Not Started → 🔶 In Progress → ✅ Complete)
- Adding new deliverables or tests not previously listed

### Documentation Updates on Feature Changes

Every feature addition, modification, or removal **must** include updates to both `README.md` and `MILESTONES.md` in the same pull request. Do not defer documentation updates to a follow-up task. Specifically:

- **README.md**: Update the Features list, Usage examples, Architecture tree, Roadmap checklist, and any other affected sections.
- **MILESTONES.md**: Update the Milestone Overview table status, check off completed deliverables and tests, and add any new items.

## Questions?

If you have questions:
- Open an issue for discussion
- Check existing issues and PRs
- Review the JPEG XL specification
- Consult the examples directory

## Code of Conduct

- Be respectful and inclusive
- Welcome newcomers
- Focus on constructive feedback
- Celebrate contributions

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
