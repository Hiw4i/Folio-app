import 'package:flutter/widgets.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

enum DocumentFormat { pdf, docx, pptx, txt, markdown }

extension DocumentFormatPresentation on DocumentFormat {
  String get extension => switch (this) {
    DocumentFormat.pdf => 'pdf',
    DocumentFormat.docx => 'docx',
    DocumentFormat.pptx => 'pptx',
    DocumentFormat.txt => 'txt',
    DocumentFormat.markdown => 'md',
  };

  String? get iconPath => switch (this) {
    DocumentFormat.pdf => 'assets/icons/pdf.svg',
    DocumentFormat.docx => 'assets/icons/docx.svg',
    DocumentFormat.txt => 'assets/icons/txt.svg',
    DocumentFormat.pptx => null,
    DocumentFormat.markdown => null,
  };

  IconData get icon => switch (this) {
    DocumentFormat.pdf => LucideIcons.fileText,
    DocumentFormat.docx => LucideIcons.fileText,
    DocumentFormat.pptx => LucideIcons.presentation,
    DocumentFormat.txt => LucideIcons.fileText,
    DocumentFormat.markdown => LucideIcons.fileCode,
  };

  static DocumentFormat? fromFileName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return null;
    }
    return switch (name.substring(dot + 1).toLowerCase()) {
      'pdf' => DocumentFormat.pdf,
      'docx' => DocumentFormat.docx,
      'pptx' => DocumentFormat.pptx,
      'txt' => DocumentFormat.txt,
      'md' => DocumentFormat.markdown,
      _ => null,
    };
  }
}

sealed class DocumentSource {
  const DocumentSource();

  String get value;
}

DocumentSource documentSourceFromJson(Map<String, Object?> json) {
  final value = json['value'];
  if (value is! String) {
    throw const FormatException('Document source is missing its value.');
  }
  return switch (json['type']) {
    'file' => FileDocumentSource(value),
    'uri' => UriDocumentSource(value),
    _ => throw const FormatException('Unsupported document source type.'),
  };
}

@immutable
class FileDocumentSource extends DocumentSource {
  const FileDocumentSource(this.path);

  final String path;

  @override
  String get value => path;
}

@immutable
class UriDocumentSource extends DocumentSource {
  const UriDocumentSource(this.uri);

  final String uri;

  @override
  String get value => uri;
}

@immutable
class DocumentEntry {
  const DocumentEntry({
    required this.id,
    required this.source,
    required this.name,
    required this.format,
    required this.sizeBytes,
    required this.modifiedAt,
    this.createdAt,
    this.lastOpenedAt,
    this.isAvailable = true,
  });

  final String id;
  final DocumentSource source;
  final String name;
  final DocumentFormat format;
  final int sizeBytes;
  final DateTime modifiedAt;
  final DateTime? createdAt;
  final DateTime? lastOpenedAt;
  final bool isAvailable;

  String get nameWithExtension =>
      DocumentFormatPresentation.fromFileName(name) == null
      ? '$name.${format.extension}'
      : name;

  /// Creation time when known, otherwise the last modification time.
  /// Older cached entries may not have [createdAt] yet.
  DateTime get effectiveCreatedAt => createdAt ?? modifiedAt;

  static const Object _notProvided = Object();

  DocumentEntry copyWith({
    String? id,
    DocumentSource? source,
    String? name,
    DocumentFormat? format,
    int? sizeBytes,
    DateTime? modifiedAt,
    Object? createdAt = _notProvided,
    Object? lastOpenedAt = _notProvided,
    bool? isAvailable,
  }) {
    return DocumentEntry(
      id: id ?? this.id,
      source: source ?? this.source,
      name: name ?? this.name,
      format: format ?? this.format,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      createdAt: identical(createdAt, _notProvided)
          ? this.createdAt
          : createdAt as DateTime?,
      lastOpenedAt: identical(lastOpenedAt, _notProvided)
          ? this.lastOpenedAt
          : lastOpenedAt as DateTime?,
      isAvailable: isAvailable ?? this.isAvailable,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'source': <String, Object?>{
      'type': source is FileDocumentSource ? 'file' : 'uri',
      'value': source.value,
    },
    'name': name,
    'format': format.name,
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt.toUtc().toIso8601String(),
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'lastOpenedAt': lastOpenedAt?.toUtc().toIso8601String(),
    'isAvailable': isAvailable,
  };

  factory DocumentEntry.fromJson(Map<String, Object?> json) {
    final source = json['source'];
    final formatName = json['format'];
    final modifiedAt = json['modifiedAt'];
    final createdAt = json['createdAt'];
    final lastOpenedAt = json['lastOpenedAt'];
    if (json['id'] is! String ||
        source is! Map ||
        json['name'] is! String ||
        formatName is! String ||
        json['sizeBytes'] is! num ||
        modifiedAt is! String) {
      throw const FormatException('Invalid cached document entry.');
    }
    final format = DocumentFormat.values.where((item) {
      return item.name == formatName;
    }).firstOrNull;
    if (format == null) {
      throw const FormatException('Unsupported cached document format.');
    }
    return DocumentEntry(
      id: json['id']! as String,
      source: documentSourceFromJson(source.cast<String, Object?>()),
      name: json['name']! as String,
      format: format,
      sizeBytes: (json['sizeBytes']! as num).toInt(),
      modifiedAt: DateTime.parse(modifiedAt),
      createdAt: createdAt is String ? DateTime.parse(createdAt) : null,
      lastOpenedAt: lastOpenedAt is String
          ? DateTime.parse(lastOpenedAt)
          : null,
      isAvailable: json['isAvailable'] as bool? ?? true,
    );
  }
}

String stableDocumentId(DocumentSource source) {
  return switch (source) {
    FileDocumentSource(:final path) => 'file:${path.replaceAll('\\', '/')}',
    UriDocumentSource(:final uri) => 'uri:$uri',
  };
}
