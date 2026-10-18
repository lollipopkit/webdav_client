# Changelog

## [Unreleased]

### Security

- Cross-origin redirects now drop `Authorization`, `Cookie` and
  `Proxy-Authorization` set through `setHeaders`, not only per-request ones,
  and keep dropping them on later same-origin hops.
- `DigestAuth` no longer sends an `Authorization` header before the server's
  first challenge; that header carried a response hash computed without a
  nonce.

### Breaking

- `Auth.authorize` takes an optional `body` and `DigestAuth.authorize` returns
  `String?`: `null` before a challenge is known or when its algorithm is not
  supported, instead of an MD5 response.

### Fixed

- Digest picks its challenge by auth-scheme, so a `WWW-Authenticate` field
  listing several schemes works, and chooses the strongest supported
  algorithm; a challenge with only unsupported algorithms or qop values fails
  instead of silently using MD5 or the qop-less formula. `qop=auth-int` hashes
  the actual request body.
- `readFile` reports a 401 as `WebdavException` instead of `StateError`, no
  longer limits the whole download to `receiveTimeout`, and removes the
  partial file when writing it fails. When the local file cannot be created,
  the response body is cancelled instead of being buffered by dio. On timeout
  or cancellation the partial file is removed before the error is thrown. `readFile` and `readStream` read the
  body of an unsuccessful response into the exception, releasing the
  connection.
- A 303 turns the request into a GET without entity headers and keeps HEAD as
  HEAD. A `Location` that cannot be parsed is no longer followed in a loop,
  and a redirect that is not followed keeps its body for the caller.
- COPY/MOVE retries a 409 once after creating the parent instead of looping,
  and no longer sends the `If` header and conditions to the parent MKCOL.
- Download progress treats any `Content-Encoding` other than `identity` as
  compressed.
- `readDir` no longer returns the requested collection itself when the base
  URL has a path (e.g. `/remote.php/dav/files/<user>`). Hrefs are now compared
  against the resolved request URL, ignoring percent-encoding differences.
- `DAV:status` values are only accepted as HTTP status-lines, so text such as
  `error 200` no longer marks a propstat as successful.

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
