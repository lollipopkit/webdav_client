# Changelog

## [Unreleased]

### Fixed

- `readDir` no longer returns the requested collection itself when the base
  URL has a path (e.g. `/remote.php/dav/files/<user>`). Hrefs are now compared
  against the resolved request URL, ignoring percent-encoding differences.
- `DAV:status` values are only accepted as HTTP status-lines, so text such as
  `error 200` no longer marks a propstat as successful.
- Hrefs are decoded exactly once and kept as sent when they are not valid
  percent-encoding, so a bare `%` no longer makes `readDir` throw and
  `%2541` is no longer read as `A`. Raw non-ASCII characters in hrefs are
  kept instead of making parsing throw. Surrounding whitespace is trimmed from
  hrefs and lock tokens.
- Multi-Status parsing only reads the `DAV:response` children of the root, so
  property values containing `response` elements no longer add phantom
  entries. Response, propstat and status elements must be in `DAV:`.
- `WebdavFile` reads its fields from `DAV:` properties only; a same-named
  property in another namespace stays in `customProps`. `creationdate` also
  accepts HTTP dates and lowercase RFC 3339, rejects dates outside the
  RFC 3339 grammar or calendar (such as Feb 30) instead of rolling them over,
  and two-digit RFC 850 years follow RFC 9110 §5.6.7.
- `propFind` finds the target under a base path at `Depth: 1` instead of
  returning an empty map, and no longer returns the properties of another
  resource when the response holds a single entry.
- Absolute `HTTP://` and `HTTPS://` targets are recognised regardless of
  scheme case instead of being resolved as paths.
- `modifyProps` no longer gives set and remove properties in different
  namespaces the same prefix, which sent the wrong property.
- `setProps`, `modifyProps` and `propPatch` throw when a 207 carries a
  response-level error status.

## [2.0.0]

### Breaking

- The `xml` constraint moved from `^6.0.0` to `^7.0.1`. `xml` 7 deprecates the
  `namespace` arguments in favour of `namespaceUri`, which does not exist in 6,
  so both versions cannot be supported at once. `XmlElement` appears in the
  return types of `propFind`, `propFindRaw`, `accessControlList`, and
  `aclRestrictions`, so dependents pinned to `xml` 6 will not resolve against
  this release.
- The SDK constraint moved from `>=3.0.0 <4.0.0` to `^3.11.0`. `xml` 7.0.1
  requires Dart 3.11, so the previous floor could not be honoured; it is now
  declared accurately rather than failing during resolution.
- Remaining dependency floors were raised to the versions this release is
  tested against: `convert` `^3.1.2`, `crypto` `^3.0.7`, `dio` `^5.11.0`.
- Sources moved from `src/client.dart`, `src/dio.dart`, `src/file.dart`, and
  `src/utils.dart` into `src/client/`, `src/models/`, and `src/internal/`.
  Importing `package:webdav_client_plus/webdav_client_plus.dart` is unaffected;
  direct imports of the old `src/` paths are not.
- GET and PUT no longer issue an OPTIONS preflight. Servers that relied on the
  preflight to create an implicit session see one fewer request.

### Added

- Access control (RFC 3744): `acl`, `accessControlList`, `aclRestrictions`,
  `currentUserPrivilegeSet`, `currentUserPrincipal`, `inheritedAclSet`,
  `ownerPrincipal`, `groupMemberSet`, `groupMembership`,
  `principalCollectionSet`, `principalMatch`, `principalPropertySearch`,
  `principalSearchPropertySet`, `principalUrl`, `alternateUriSet`.
- Versioning (RFC 3253): `versionControl`, `checkin`, `checkout`, `uncheckout`,
  `checkedIn`, `checkedOut`, `versionTree`, `versionHistory`,
  `versionHistoryReport`, `label`, `merge`, `baselineControl`, `mkactivity`,
  `mkworkspace`, `expandProperty`, `predecessorSet`, `successorSet`,
  `activityCollectionSet`, `workspaceCollectionSet`.
- Bindings (RFC 5842): `bind`, `unbind`, `rebind`.
- Collection synchronization (RFC 6578): `syncCollection`.
- Property access: `propFind`, `propFindAll`, `propFindDepth`, `propFindNames`,
  `propFindRaw`, `propPatch`, `orderpatch`, `mkdirWithProps`,
  `supportedMethods`, `supportedLiveProperties`, `supportedReports`,
  `resourceTypes`, `quotaBytes`, `source`, `comment`, `creatorDisplayName`.
  `propFindRaw` reports per-property status codes rather than collapsing them.
- Locking: `lockDiscovery`, `supportedLocks`, `refreshLock`.
- Transport: `request` runs arbitrary verbs through the built-in auth stack,
  with `report`, `search`, `options`, and `head` built on top. Also added
  `readStream`, `writeStream`, `create`, `updateIfMatch`, and `absoluteUrl`.
- Subscriptions: `subscribe`, `unsubscribe`, `poll`.
- Multi-Status parsing: `parseMultiStatus`, `parseMultiStatusToMap`,
  `MultiStatusResponse`, and `MultiStatusPropstat`, carrying per-property
  status codes together with `<d:error>`, `<d:responsedescription>`, and
  `<d:location>`.

### Changed

- `copy` accepts `Depth: 0` per RFC 4918 §9.8 and rejects unsupported depths.
- Lock tokens are read from the `Lock-Token` response header first, with the
  XML body retained as a fallback (RFC 4918 §§9.10.1, 10.5).
- Requests carrying an `If` header now also send `Cache-Control: no-cache` and
  `Pragma: no-cache` (RFC 4918 §10.4.5).
- DELETE responses with 207 Multi-Status report per-member diagnostics.

### Fixed

- `Destination` and `If` header URLs are percent-encoded. Paths containing a
  space or any non-ASCII character previously produced an invalid header value,
  which servers such as dufs rejected with `400 Invalid Destination`, breaking
  `copy`, `move`, and `rename` on those paths. Existing `%XX` escapes are left
  intact, so pre-encoded input such as `%2F` is not double-encoded.
- A 3xx response with no `Location` header now reports `No location header
  found` instead of a generic failure. The raw `request` escape hatch still
  returns the response unchanged.
- Cancelling a `readFile` no longer raises `PathNotFoundException` when the
  partial download has already been removed. The cleanup runs from an unawaited
  cancel handler, so the error surfaced as an unhandled async error rather than
  reaching the caller.
- `resolveAgainstBaseUrl` strips dot-segments per RFC 4918 §8.3.
- `resolveAgainstBaseUrl` treats leading-slash references as server-root URLs.
- `WebdavFile` retains custom property XML, so empty and structured values
  survive PROPFIND parsing.
- `WebdavFile` parsing accepts every 2xx propstat status, so entries from
  compliant servers are no longer dropped.

## [1.0.0]

- Initial release of the project.
