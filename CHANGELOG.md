# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/) and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Add `sequence_indent` option to `Psych::Pure.dump` to control whether sequence elements contained within mapping elements are indented.

## [0.1.4] - 2025-11-10

- Fix up comment handling preceding sequence elements.
- Properly update hashes in mutation methods that are loaded through `Psych::Pure.load`.
- Properly raise syntax errors when the parser does not finish.

## [0.1.3] - 2025-10-24

- Fix up roundtripping when using `<<` inside mappings.
- Fix up roundtripping when using duplicate keys inside mappings.
- Fix up comment handling when using duplicate keys inside mappings.

## [0.1.2] - 2025-03-04

- Fix up comment dumping to not drift around objects.
- Rely on source formatting when possible for scalar values.
- Fix up multi-line literals with the "keep" flag (|+).
- Fix up aliasing hashes that have comments loaded.

## [0.1.1] - 2025-02-13

- Fix up comment handling to preserve within hashes.
- Do not duplicate comments when the parser backtracks.
- Trim locations of sequences and mappings before trailing comments.

## [0.1.0] - 2025-02-12

### Added

- 🎉 Initial release. 🎉

[unreleased]: https://github.com/kddnewton/psych-pure/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/kddnewton/psych-pure/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/kddnewton/psych-pure/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/kddnewton/psych-pure/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/kddnewton/psych-pure/compare/24de62...v0.1.0
