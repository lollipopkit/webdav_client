/// A Dart library for WebDAV client operations.
/// This library provides a simple and efficient way to interact with WebDAV
/// servers. It includes authentication, file operations, and WebDAV-specific
/// extension helpers.
library;

// Types from dependencies that appear in the public API.
export 'package:dio/dio.dart'
    show
        CancelToken,
        DioException,
        DioExceptionType,
        Options,
        ProgressCallback,
        Response,
        ResponseBody,
        ResponseType;
export 'package:xml/xml.dart'
    show XmlElement, XmlFindExtension, XmlStringExtension;

export 'src/auth.dart';
export 'src/client/client.dart';
export 'src/enums.dart';
export 'src/models/webdav_file.dart';
