# webdav_client_plus

## Usage

```dart
final client = WebdavClient.noAuth('http://localhost:6688/');
```

### Common settings
```dart
// Set the public request headers
client.setHeaders({'accept-charset': 'utf-8'});
// Set the connection server timeout time in milliseconds.
client.setConnectTimeout(8000);
// Set send data timeout time in milliseconds.
client.setSendTimeout(8000);
// Set transfer data time in milliseconds.
client.setReceiveTimeout(8000);
// Test whether the service can connect
try {
  await client.ping();
} catch (e) {
  print('$e');
}
```

### Read all files in a folder
```dart
await client.readDir('/');
```

### Create folder
```dart
await client.mkdir('/newFolder');
// Recursively
await client.mkdirAll('/new folder/new folder2');
```


### Remove
> If you remove the folder, some webdav services require a '/' at the end of the path.
```dart
// Delete folder
await client.remove('/new folder/new folder2/');

// Delete file
await client.remove('/new folder/text.txt');
```

### Rename
> If you rename the folder, some webdav services require a '/' at the end of the path.
```dart
await client.rename('/dir/', '/dir2/', overwrite: true);
await client.rename('/dir/test.dart', '/dir2/test2.dart', overwrite: true);
```

### Copy
- If copied a folder, it will copy all the contents.
- Some webdav services have been tested and found to delete the original contents of the target folder.
```dart
// Copy all the contents
await client.copy('/folder/folderA/', '/folder/folderB/', overwrite: true);
// Copy file
await client.copy('/folder/aa.png', '/folder/bb.png', overwrite: true);
```

### Download
```dart
// Bytes
await client.read('/folder/file', onProgress: (count, total) {
  print(count / total);
});

// Stream
await client.readFile(
  '/folder/file', 
  'file', 
  onProgress: (c, t) => print(c / t),
  cancelToken: CancelToken(),
);
```

### Upload
```dart
// upload bytes and pass conditional / metadata headers
await client.write(
  '/f/file.txt',
  Uint8List.fromList([1, 2, 3]),
  headers: {'Content-Type': 'text/plain', 'If-Match': '"etag"'},
);

// upload local file to remote file with stream
await client.writeFile('file', '/f/file');

// upload any byte stream
await client.writeStream('/f/large.bin', byteStream, contentLength);

// conditional create / update helpers
await client.create('/f/new.txt', Uint8List.fromList([1, 2, 3]));
await client.updateIfMatch('/f/file.txt', Uint8List.fromList([4]), 'etag');
```

### Advanced WebDAV helpers
```dart
// Raw request helper for custom extensions, plus REPORT/SEARCH shortcuts
final resp = await client.request<String>('REPORT', target: '/calendar');
await client.report('/calendar', '<calendar-query/>', depth: PropsDepth.one);
await client.search('/', '<basicsearch/>', depth: PropsDepth.infinity);
await client.acl('/resource', '<acl/>');
await client.bind('/collection/', segment: 'alias.txt', href: '/source.txt');
await client.unbind('/collection/', segment: 'alias.txt');
await client.rebind('/collection/', segment: 'alias.txt', href: '/source.txt');
await client.orderpatch('/ordered/', '<orderpatch/>');
await client.subscribe('/resource', subscriptionId: 'sub-1');
await client.poll('/resource', subscriptionId: 'sub-1');
await client.unsubscribe('/resource', subscriptionId: 'sub-1');
await client.syncCollection('/collection/', syncToken: 'sync-token');
final resourceTypes = await client.resourceTypes(path: '/calendar/');
final methods = await client.supportedMethods();
final liveProps = await client.supportedLiveProperties();
final reports = await client.supportedReports();
await client.expandProperty('/resource', [ExpandProperty('version-history')]);
await client.versionControl('/file.txt');
await client.checkout('/file.txt');
await client.checkin('/file.txt');
await client.uncheckout('/file.txt');
await client.label('/versions/1', labelName: 'release', action: 'add');
await client.mkworkspace('/workspace', sourceHref: '/versions/1');
await client.merge('/target', '/versions/1');
final workspaces = await client.workspaceCollectionSet();
final activities = await client.activityCollectionSet();
await client.mkactivity('/activities/a1');
await client.baselineControl('/version-controlled-collection/');
await client.versionTree('/versions/1');
await client.versionHistoryReport('/file.txt');
final creator = await client.creatorDisplayName(path: '/file.txt');
final comment = await client.comment(path: '/file.txt');
final sourceLinks = await client.source(path: '/generated.html');
final checkedIn = await client.checkedIn(path: '/file.txt');
final history = await client.versionHistory(path: '/file.txt');

// SabreDAV-style property helpers
final props = await client.propFind('/file.txt');
final allProps = await client.propFindAll('/file.txt');
final propNames = await client.propFindNames('/file.txt');
final childrenProps = await client.propFindDepth('/folder/');
final principal = await client.currentUserPrincipal();
final principalSets = await client.principalCollectionSet();
final alternateUris = await client.alternateUriSet(path: principal ?? '/');
final principalUrls = await client.principalUrl(path: principal ?? '/');
await client.principalMatch('/principals/', self: true);
await client.principalPropertySearch(
  '/principals/',
  property: 'displayname',
  match: 'Alice',
);
await client.principalSearchPropertySet('/principals/');
final owner = await client.ownerPrincipal(path: '/file.txt');
final members = await client.groupMemberSet(path: '/principals/groups/editors/');
final groups = await client.groupMembership(path: principal ?? '/');
final privileges = await client.currentUserPrivilegeSet(path: '/file.txt');
final restrictions = await client.aclRestrictions(path: '/file.txt');
final aces = await client.accessControlList(path: '/file.txt');
final inheritedAcl = await client.inheritedAclSet(path: '/file.txt');
await client.propPatch('/file.txt', [
  PropPatchOperation.remove('displayname'),
  PropPatchOperation.set('displayname', 'New name'),
]);

// Discover and refresh lock tokens
final supportedLocks = await client.supportedLocks('/file.txt');
final locks = await client.lockDiscovery('/file.txt');
await client.refreshLock('/file.txt', 'opaquelocktoken:token');

// OPTIONS discovery helpers
final allow = await client.allowedMethods();

// Resolve targets exactly like the request pipeline
final absolute = client.absoluteUrl('/file.txt');
```

### Cancel request
```dart
final cancel = CancelToken();
client.mkdir('/dir', cancel)
.catchError((err) {
  print(err.toString());
});
cancel.cancel('reason');
```

## Testing

The WebDAV integration specs build and run an Apache `mod_dav` container from `test/apache`, served under `/dav`. They need Docker with permission to build and run containers, and are skipped when `docker info` fails. Run:

```shell
dart test
```
