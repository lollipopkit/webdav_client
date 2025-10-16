# Changelog

### Unreleased
- Removed redundant OPTIONS preflights before GET/PUT operations to reduce latency and follow RFC 4918 guidance.
- Normalized `resolveAgainstBaseUrl` output to strip dot-segments per RFC 4918 §8.3, avoiding malformed Destination headers.
- Surfaced per-member diagnostics for DELETE 207 Multi-Status responses to match SabreDAV behaviour.
- Added `WebdavClient.options()` to expose DAV capabilities without custom plumbing.
- Added `WebdavClient.request()` so advanced WebDAV verbs (REPORT, SEARCH, etc.) reuse the built-in auth stack.
- Added `parseMultiStatus` and companion data types to mirror SabreDAV diagnostics for RFC 4918 Multi-Status bodies.
- Added `WebdavClient.propFindRaw` to expose per-property status codes similar to SabreDAV’s propFind helpers.
- Enriched `MultiStatusResponse` with DAV error metadata (`<d:error>`, `<d:responsedescription>`, `<d:location>`).
- Preserved custom property XML in `WebdavFile` so empty or structured values survive PROPFIND parsing.
- Treated all 2xx PROPFIND propstat statuses as success when parsing `WebdavFile`, avoiding dropped entries from compliant servers.
- Reused `parseMultiStatusToMap` inside `propFindRaw` and exposed top-level Multi-Status codes for SabreDAV parity.

### [1.0.0]
- Initial release of the project.
