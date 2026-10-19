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
- The library re-exports the dio and xml types used in its public API
  (`CancelToken`, `DioException`, `DioExceptionType`, `Options`,
  `ProgressCallback`, `Response`, `ResponseBody`, `ResponseType`, `XmlElement`
  and its find/string extensions), so callers no longer need direct `dio` /
  `xml` dependencies. Code that also imports another library exporting one of
  these names, such as `Response` from `package:http`, needs a prefix or
  `hide` on one of the imports.
- Paths follow `PathMode.baseRelative` by default, the convention of rclone,
  the npm `webdav` client and webdavclient3. A path is decoded text relative
  to the base URL, with or without a leading `/`. `%`, `?` and `#` are part
  of the name, and `..` above the base throws `ArgumentError`.
  `WebdavFile.path`, `propFindRaw` / `propFindDepth` keys and discovery
  helper results are base-relative paths, or absolute URLs for resources
  outside the base. The `href` arguments of `bind`, `rebind`, `merge` and
  `mkworkspace` take the same form. Set
  `WebdavOptions(pathMode: PathMode.legacy)` to keep the previous behaviour
  until the next major release.
- `WebdavFile.parseFiles` takes the body and a function converting each href
  to a path, and no longer skips the requested resource; `WebdavFile.parse`
  takes the converted path before the raw href.
- The license changes from BSD-3-Clause to Apache-2.0. `NOTICE` keeps the
  original BSD-3-Clause notice for the upstream `webdav_client` code.

### Added

- `WebdavOptions` configures `pathMode`, headers and timeouts when creating a
  client; `WebdavClient.webdavOptions` reflects later `set*` calls.
- `MultiStatusResponse.rawHref` keeps the href as sent by the server.
- `ActiveLock.lockRoot` exposes the `DAV:lockroot` resource in the same form
  as `WebdavFile.path`, so a lock inherited from a parent collection can be
  told apart and unlocked or refreshed on its root.

### Fixed

- `mkdirAll` no longer issues MKCOL for collections above the base URL when
  it creates missing parents, and a `%XX` sequence in a listed name no longer
  turns into a different name when `WebdavFile.path` is passed back.
- Headers a request must not carry (sensitive ones after a cross-origin
  redirect, entity ones on a 303 GET) are removed from the final request
  instead of being set to `null`, which the web adapter sent as the literal
  value `null`.
- `readFile` cleanup no longer raises unhandled async errors when closing or
  deleting the partial file fails, and a failed close after the last chunk
  also removes the file.
- `lock()` reports a malformed response body as `WebdavException` instead of
  leaking an `XmlParserException`.
- `readDir`, `readProps`, `propFind` and `quotaBytes` report a PROPFIND
  response with an empty or malformed body as `WebdavException` instead of
  leaking an `XmlParserException` (or a cast error from `quotaBytes`).
- `syncCollection` sends `Depth: 0` as RFC 6578 §3.3 requires, even when the
  caller passes a `Depth` header; the `depth` argument only sets
  `DAV:sync-level`.
- `basicSearch` wraps the query in the `DAV:searchrequest` root required by
  RFC 5323 §2.3.
- `refreshLock` accepts any absolute URI as a lock token, not only
  `urn:uuid:` and `opaquelocktoken:` ones, and skips `Not` conditions.
- Digest picks its challenge by auth-scheme, so a `WWW-Authenticate` field
  listing several schemes works, and chooses the strongest supported
  algorithm; a challenge with only unsupported algorithms or qop values fails
  instead of silently using MD5 or the qop-less formula. `qop=auth-int` hashes
  the actual request body. A streamed request that cannot be retried after a
  401 leaves the client's Digest state unchanged.
- `readFile` reports a 401 as `WebdavException` instead of `StateError`, no
  longer limits the whole download to `receiveTimeout`, and removes the
  partial file when writing it fails. When the local file cannot be created,
  the response body is cancelled instead of being buffered by dio. On timeout
  or cancellation the partial file is removed before the error is thrown, even
  when closing it fails. `readFile` and `readStream` read the
  body of an unsuccessful response into the exception, releasing the
  connection.
- A 303 turns the request into a GET without entity headers, including ones
  set through `setHeaders`, and keeps HEAD as HEAD. A `Location` that cannot be parsed is no longer followed in a loop,
  and a redirect that is not followed keeps its body for the caller.
- COPY/MOVE retries a 409 once after creating the parent instead of looping,
  and no longer sends the `If` header and conditions to the parent MKCOL. A
  207 that names no member fails instead of passing as success, since
  RFC 4918 §9.8.5 sends 207 only when errors stopped the operation.
- `readProps` and `quotaBytes` use the response entry for the requested
  resource instead of the first one when a Depth 0 reply lists others.
- Download progress treats any `Content-Encoding` other than `identity` as
  compressed.
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
  entries. Response, propstat and status elements must be in `DAV:`, and a
  207 whose root is not `DAV:multistatus` is reported as malformed instead of
  as an empty success.
- `WebdavFile` reads its fields from `DAV:` properties only; a same-named
  property in another namespace stays in `customProps`. `creationdate` also
  accepts HTTP dates and lowercase RFC 3339, rejects dates outside the
  RFC 3339 grammar or calendar (such as Feb 30) instead of rolling them over,
  and two-digit RFC 850 years follow RFC 9110 §5.6.7.
- `propFind` finds the target under a base path at `Depth: 1` instead of
  returning an empty map, and no longer returns the properties of another
  resource when the response holds a single entry or names it by an absolute
  href on another origin.
- Absolute `HTTP://` and `HTTPS://` targets are recognised regardless of
  scheme case instead of being resolved as paths.
- `modifyProps` no longer gives set and remove properties in different
  namespaces the same prefix, which sent the wrong property.
- `setProps`, `modifyProps` and `propPatch` throw when a 207 carries a
  response-level error status. PROPPATCH, COPY and MOVE treat as failed a
  propstat whose `DAV:status` is missing or unparsable, a response whose own
  `DAV:status` is unparsable, and a response with neither a status nor
  propstats.

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
