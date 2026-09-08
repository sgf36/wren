/// Getting an exported file off the device and into text.
///
/// The picker is a channel into `UIDocumentPickerViewController` rather than a
/// plugin dependency, for the same reason OCR and place lookup are: this app
/// adds native code in `AppDelegate.swift` because there is no Xcode here to
/// add files to a target with, and a pod that fails to link fails in CI where
/// it is expensive to diagnose.
///
/// What arrives is bytes, not text, and that is deliberate. A KMZ is a zip; a
/// CSV saved out of Excel is often UTF-16 or Windows-1252 rather than UTF-8.
/// Deciding here — where the bytes are still intact — beats letting a wrong
/// decode reach the parser, where it looks like a malformed file.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FileSourceUnavailable implements Exception {
  final String message;

  /// True when there is no picker at all, rather than a failure inside it, so
  /// the UI can substitute a translated message instead of showing one that
  /// came back from the OS in the OS's own words.
  final bool unsupported;

  FileSourceUnavailable(this.message, {this.unsupported = false});
  @override
  String toString() => 'FileSourceUnavailable: $message';
}

/// A file the user chose, already turned into text.
class PickedFile {
  final String name;
  final String text;

  /// The raw bytes, when the file turned out to be a picture rather than an
  /// export. Null for everything else, because nothing else needs them and
  /// carrying a whole KMZ twice would be wasteful.
  final Uint8List? imageBytes;

  const PickedFile({
    required this.name,
    required this.text,
    this.imageBytes,
  });

  /// True when the picker handed back a photograph or screenshot.
  bool get isImage => imageBytes != null;
}

abstract class FileSource {
  /// Shows the document picker. Null when the user backed out, which is not an
  /// error and must not be reported as one.
  Future<PickedFile?> pick();
}

/// The zip local-file-header magic. A KMZ is a zip and a KML is not, and the
/// extension is not reliable enough to tell them apart — users rename things,
/// and some exporters write `.kml` for a zipped file.
const _zipMagic = [0x50, 0x4b, 0x03, 0x04];

/// Whether these bytes are a picture, by their own magic numbers.
///
/// **Why this exists.** The document picker is deliberately unfiltered — see
/// PickFilePlugin — so every screenshot on the device is selectable under "From
/// a file". Choosing one is not a perverse thing to do: the app's own first
/// screen tells people to screenshot things, and "from a file" is a fair
/// description of a picture sitting in Downloads. Before this, that produced
/// "Wren could not read that file. It reads CSV, KML, KMZ, GPX, GeoJSON and
/// Google Takeout exports" — technically true, unhelpful, and phrased as though
/// the picture were malformed rather than simply in the wrong doorway.
///
/// Magic numbers rather than the extension, for the reason the zip check gives:
/// people rename things, and a content URI's display name is not a promise.
bool looksLikeImage(Uint8List b) {
  bool at(int i, List<int> want) {
    if (b.length < i + want.length) return false;
    for (var n = 0; n < want.length; n++) {
      if (b[i + n] != want[n]) return false;
    }
    return true;
  }

  // PNG, and JPEG in all its flavours: Android screenshots are PNG, most
  // cameras and every messaging app produce JPEG.
  if (at(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return true;
  if (at(0, [0xff, 0xd8, 0xff])) return true;
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return true; // GIF8
  if (at(0, [0x42, 0x4d])) return true; // BM
  // RIFF....WEBP — the size sits between the two markers.
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) {
    return true;
  }
  // HEIC and HEIF, which is what an iPhone screenshot can be: an ISO-BMFF box
  // whose type is `ftyp`, carrying one of a family of brands.
  if (at(4, [0x66, 0x74, 0x79, 0x70])) {
    const brands = ['heic', 'heix', 'hevc', 'heim', 'heis', 'hevm', 'hevs',
                    'mif1', 'msf1', 'avif'];
    if (b.length >= 12) {
      final brand = String.fromCharCodes(b.sublist(8, 12));
      if (brands.contains(brand)) return true;
    }
  }
  return false;
}

/// Turns the bytes of a picked file into text.
///
/// Exposed for tests, because every one of these cases was found in a real
/// export and none of them is reachable through the picker in a test.
String decodeFileBytes(Uint8List bytes, {String? name}) {
  if (bytes.isEmpty) throw FileSourceUnavailable('that file is empty');

  if (bytes.length >= 4 &&
      bytes[0] == _zipMagic[0] &&
      bytes[1] == _zipMagic[1] &&
      bytes[2] == _zipMagic[2] &&
      bytes[3] == _zipMagic[3]) {
    return _kmlFromZip(bytes);
  }

  // UTF-16 with a byte-order mark. Excel writes this when a sheet holds
  // anything outside Latin-1, which a list of Tokyo restaurants certainly
  // does, and decoded as UTF-8 it arrives as text separated by NUL bytes.
  if (bytes.length >= 2) {
    if (bytes[0] == 0xff && bytes[1] == 0xfe) return _utf16(bytes, 2, false);
    if (bytes[0] == 0xfe && bytes[1] == 0xff) return _utf16(bytes, 2, true);
  }

  var body = bytes;
  // A UTF-8 BOM would otherwise become an invisible character glued to the
  // first header name, so `Title` stops matching and the file reads as having
  // no name column at all.
  if (body.length >= 3 &&
      body[0] == 0xef &&
      body[1] == 0xbb &&
      body[2] == 0xbf) {
    body = Uint8List.sublistView(body, 3);
  }

  try {
    return utf8.decode(body);
  } on FormatException {
    // Not UTF-8. Latin-1 always decodes, so this cannot fail again; accented
    // names may come out wrong, but a slightly wrong name still resolves where
    // a refused file imports nothing.
    return latin1.decode(body, allowInvalid: true);
  }
}

String _utf16(Uint8List bytes, int start, bool bigEndian) {
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(
      bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : (bytes[i + 1] << 8) | bytes[i],
    );
  }
  return String.fromCharCodes(units);
}

String _kmlFromZip(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    throw FileSourceUnavailable('that file is a damaged archive');
  }
  // A KMZ holds doc.kml plus images. Prefer doc.kml, then any .kml, and ignore
  // everything else rather than guessing at the largest entry.
  final files = archive.files.where((f) => f.isFile).toList();
  ArchiveFile? pick;
  for (final f in files) {
    final lower = f.name.toLowerCase();
    if (lower.endsWith('doc.kml')) {
      pick = f;
      break;
    }
    if (pick == null && lower.endsWith('.kml')) pick = f;
  }
  if (pick == null) {
    throw FileSourceUnavailable('that archive holds no KML');
  }
  return decodeFileBytes(Uint8List.fromList(pick.content as List<int>));
}

/// The document picker on the device.
class DocumentFileSource implements FileSource {
  static const _channel = MethodChannel('littlebird/files');

  @override
  Future<PickedFile?> pick() async {
    try {
      final m = await _channel.invokeMapMethod<Object?, Object?>('pick');
      if (m == null) return null; // cancelled
      final bytes = m['bytes'] as Uint8List?;
      if (bytes == null) return null;
      final name = (m['name'] as String?) ?? '';
      // Checked before decoding, not after. Decoding a PNG as text succeeds --
      // latin1 always does -- and produces a screenful of mojibake that then
      // fails in the parser, where it is indistinguishable from a corrupt
      // export. The bytes are the only place the truth is still intact.
      if (looksLikeImage(bytes)) {
        return PickedFile(name: name, text: '', imageBytes: bytes);
      }
      return PickedFile(
        name: name,
        text: decodeFileBytes(bytes, name: name),
      );
    } on MissingPluginException catch (e) {
      // Printed, not swallowed. The caller turns this into "could not read that
      // file", which reads exactly like a bad file -- so on a device the one
      // thing worth knowing, that no platform answered at all, was invisible.
      debugPrint('littlebird/files has no platform handler: $e');
      throw FileSourceUnavailable(
        'choosing a file needs a platform implementation, and this build has '
        'none',
        unsupported: true,
      );
    } on PlatformException catch (e) {
      throw FileSourceUnavailable(e.message ?? e.code);
    }
  }
}

/// Writes a file the user names, through the platform's own save dialog.
///
/// Separate from sharing on purpose. A share asks another app to volunteer to
/// receive the bytes; a save puts them somewhere the user chose and can find
/// again -- which is what the Google Maps route needs, because the next step is
/// a browser file picker.
abstract class FileSaver {
  /// True when the bytes were written, false when the user cancelled.
  Future<bool> save(
    List<int> bytes, {
    required String name,
    required String mimeType,
  });
}

class DocumentFileSaver implements FileSaver {
  const DocumentFileSaver();

  static const _channel = MethodChannel('littlebird/files');

  @override
  Future<bool> save(
    List<int> bytes, {
    required String name,
    required String mimeType,
  }) async {
    try {
      final r = await _channel.invokeMethod<String>('save', {
        'bytes': Uint8List.fromList(bytes),
        'fileName': name,
        'mimeType': mimeType,
      });
      return r == 'saved';
    } on MissingPluginException {
      debugPrint('littlebird/files has no save implementation here');
      return false;
    } on PlatformException catch (e) {
      debugPrint('saving failed: $e');
      return false;
    }
  }
}

/// Records what it was asked to write, and whether it agreed to.
class StubFileSaver implements FileSaver {
  StubFileSaver({this.accept = true});

  /// False stands in for the user cancelling the save dialog.
  final bool accept;
  final saved = <({String name, String mimeType, int bytes})>[];

  @override
  Future<bool> save(
    List<int> bytes, {
    required String name,
    required String mimeType,
  }) async {
    if (!accept) return false;
    saved.add((name: name, mimeType: mimeType, bytes: bytes.length));
    return true;
  }
}

/// Returns a fixed export, so the import flow can be exercised without a
/// device. Never returns null: cancelling is tested by a source that does.
class StubFileSource implements FileSource {
  StubFileSource(this.text, {this.name = 'places.csv'});
  final String text;
  final String name;

  @override
  Future<PickedFile?> pick() async => PickedFile(name: name, text: text);
}
