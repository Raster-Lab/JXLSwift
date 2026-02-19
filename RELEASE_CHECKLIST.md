# Release Checklist for v1.0.0

This document provides a step-by-step checklist for creating a v1.0.0 release of JXLSwift.

## Pre-Release Validation

### Code Quality
- [x] All tests pass on all platforms (macOS ARM64, macOS x86-64, Linux x86-64)
- [x] Code coverage ≥ 95% verified with `make coverage`
- [x] Memory safety validation complete (ASan, TSan, UBSan)
- [x] Security scanning complete (CodeQL)
- [x] Fuzzing tests pass with no crashes (51 tests)
- [x] Thread safety tests pass (51 tests)
- [x] Performance benchmarks run successfully

### Documentation
- [x] API documentation generated with DocC
- [x] README.md is up to date
- [x] CHANGELOG.md includes v1.0.0 release notes
- [x] Migration guide is complete
- [x] Performance guide is complete
- [x] Coverage guide is complete
- [x] Man pages are generated

### Version Management
- [x] VERSION file updated to `1.0.0`
- [x] CHANGELOG.md has [1.0.0] entry with release date
- [x] Package.swift platform requirements verified
- [x] All milestone deliverables completed (13/13 milestones)

## Release Process

### 1. Final Code Review
- [ ] Review all changes since last release
- [ ] Ensure no TODO or FIXME comments in production code
- [ ] Verify all documentation is accurate
- [ ] Check for any hardcoded values that should be configurable

### 2. Create Release Branch
```bash
git checkout main
git pull origin main
git checkout -b release/1.0.0
```

### 3. Update Version Files
- [x] Update `VERSION` to `1.0.0`
- [x] Update `CHANGELOG.md` with final release date
- [x] Create `RELEASE_NOTES_1.0.0.md`

### 4. Run Final Tests
```bash
# Run full test suite
swift test

# Run with code coverage
make coverage

# Verify coverage threshold
./scripts/generate-coverage-report.sh --threshold 95

# Run sanitizer tests
swift test -Xswiftc -sanitize=address
swift test -Xswiftc -sanitize=thread
swift test -Xswiftc -sanitize=undefined
```

### 5. Build Release Artifacts
```bash
# Build in release mode
swift build -c release

# Build command-line tool
swift build -c release --product jxl-tool

# Generate documentation
make docc-html

# Generate man pages
make man
```

### 6. Create Git Tag
```bash
# Commit version updates
git add VERSION CHANGELOG.md RELEASE_NOTES_1.0.0.md
git commit -m "Release v1.0.0"

# Create annotated tag
git tag -a v1.0.0 -m "Release v1.0.0 - Initial stable release"

# Push to repository
git push origin release/1.0.0
git push origin v1.0.0
```

### 7. Create GitHub Release

Go to https://github.com/Raster-Lab/JXLSwift/releases/new

- **Tag:** `v1.0.0`
- **Title:** `JXLSwift 1.0.0 - Initial Stable Release`
- **Description:** Copy content from `RELEASE_NOTES_1.0.0.md`
- **Attachments:** None required (Swift Package Manager will use the tag)
- **Mark as latest release:** ✓

### 8. Update Main Branch
```bash
# Merge release branch back to main
git checkout main
git merge release/1.0.0
git push origin main
```

### 9. Announce Release

**GitHub:**
- [ ] Create release on GitHub with release notes
- [ ] Post announcement in Discussions

**Documentation:**
- [ ] Update README.md badge if needed
- [ ] Update documentation website (if applicable)

**Community:**
- [ ] Post to Swift forums (if applicable)
- [ ] Update package registry listings (if applicable)

## Post-Release Tasks

### Verification
- [ ] Verify Swift Package Manager can resolve `1.0.0`
- [ ] Test installation with `make install`
- [ ] Verify man pages are accessible
- [ ] Check GitHub release page displays correctly
- [ ] Verify all CI checks pass on release tag

### Prepare for Next Release
- [ ] Create `CHANGELOG.md` [Unreleased] section
- [ ] Update `VERSION` to `1.1.0-dev` on main branch
- [ ] Close completed milestones
- [ ] Create milestone for v1.1.0 (if needed)

### Monitor
- [ ] Watch for issue reports related to v1.0.0
- [ ] Monitor CI for any platform-specific issues
- [ ] Track performance metrics
- [ ] Collect community feedback

## Rollback Plan

If critical issues are discovered after release:

### Option 1: Hotfix Release
1. Create branch from v1.0.0 tag
2. Apply minimal fix
3. Create v1.0.1 release
4. Deprecate v1.0.0

### Option 2: Yank Release
1. Delete GitHub release (if not widely adopted)
2. Delete git tag
3. Fix issues
4. Re-release as v1.0.0

## Release Artifacts Checklist

- [x] `VERSION` file at 1.0.0
- [x] `CHANGELOG.md` with v1.0.0 entry
- [x] `RELEASE_NOTES_1.0.0.md` with comprehensive notes
- [ ] Git tag `v1.0.0` pushed
- [ ] GitHub release created
- [ ] All CI checks passing
- [ ] Documentation deployed

## Success Criteria

A successful v1.0.0 release meets these criteria:

- ✅ All tests pass on all supported platforms
- ✅ Code coverage ≥ 95%
- ✅ No memory safety issues (ASan, TSan, UBSan)
- ✅ No security vulnerabilities (CodeQL)
- ✅ Complete API documentation
- ✅ Comprehensive user guides
- ✅ Git tag created and pushed
- ✅ GitHub release created
- ✅ Swift Package Manager integration working
- ✅ Command-line tool installable and functional

---

**Release Manager:** Follow this checklist step-by-step to ensure a smooth v1.0.0 release.

**Last Updated:** 2026-02-19
**Status:** Ready for release
