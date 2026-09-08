import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wren/src/file_source.dart';
import 'package:wren/src/place_files.dart';

/// Every case here came out of a real export. None of them is a hypothetical:
/// Excel writes UTF-16, Google Earth writes KMZ, and a BOM glued to the first
/// header name is why a perfectly good CSV reads as having no name column.
void main() {
  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  group('a picture is recognised as one, so it can be read rather than refused', () {
    // Reported by a tester on 2026-09-07: choosing a screenshot under "From a
    // file" answered "Wren could not read that file. It reads CSV, KML, KMZ,
    // GPX, GeoJSON and Google Takeout exports." The picker is unfiltered by
    // necessity, so the app has to recognise a picture and route it to OCR.
    test('PNG, which is what an Android screenshot is', () {
      expect(
        looksLikeImage(bytes([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                              0, 0, 0, 13])),
        isTrue,
      );
    });

    test('JPEG, which is what it becomes once it has been through a chat app',
        () {
      expect(looksLikeImage(bytes([0xff, 0xd8, 0xff, 0xe0, 0, 16])), isTrue);
    });

    test('HEIC, which is what an iPhone screenshot can be', () {
      // ISO-BMFF: a four-byte size, then `ftyp`, then the brand.
      final heic = <int>[
        0, 0, 0, 24,
        ...utf8.encode('ftyp'),
        ...utf8.encode('heic'),
        ...List.filled(8, 0),
      ];
      expect(looksLikeImage(bytes(heic)), isTrue);
    });

    test('WebP needs both markers, not just RIFF', () {
      final webp = <int>[
        ...utf8.encode('RIFF'), 0, 0, 0, 0, ...utf8.encode('WEBP'),
      ];
      expect(looksLikeImage(bytes(webp)), isTrue);
      // A RIFF that is not a WebP -- a WAV, say -- must not be taken for one.
      final wav = <int>[
        ...utf8.encode('RIFF'), 0, 0, 0, 0, ...utf8.encode('WAVE'),
      ];
      expect(looksLikeImage(bytes(wav)), isFalse);
    });

    test('the exports Wren actually reads are NOT taken for pictures', () {
      // The expensive failure is the other direction: a CSV routed to OCR
      // would read as a picture of nothing and lose a real import.
      expect(looksLikeImage(bytes(utf8.encode('name,lat'))), isFalse);
      expect(looksLikeImage(bytes(utf8.encode('<?xml version="1.0"?><kml/>'))),
          isFalse);
      expect(looksLikeImage(bytes(utf8.encode('{"type":"FeatureCollection"}'))),
          isFalse);
      // A KMZ is a zip, and zips must keep going to the KML reader.
      expect(looksLikeImage(bytes([0x50, 0x4b, 0x03, 0x04, 0, 0])), isFalse);
    });

    test('a truncated header does not read off the end', () {
      expect(looksLikeImage(bytes([])), isFalse);
      expect(looksLikeImage(bytes([0x89])), isFalse);
      expect(looksLikeImage(bytes([0xff, 0xd8])), isFalse);
      expect(looksLikeImage(bytes([0x52, 0x49, 0x46, 0x46])), isFalse);
    });
  });

  test('plain UTF-8', () {
    expect(decodeFileBytes(bytes(utf8.encode('name\nBao'))), 'name\nBao');
  });

  test('a UTF-8 BOM is removed, not left glued to the first header', () {
    // Left in place, the header becomes "﻿Title", stops matching "title",
    // and the file is refused for having no name column.
    final withBom = bytes([0xef, 0xbb, 0xbf, ...utf8.encode('Title,Lat\nX,1')]);
    final text = decodeFileBytes(withBom);
    expect(text.startsWith('Title'), isTrue);
    expect(readPlaceFile(text).places.single.name, 'X');
  });

  test('UTF-16 little-endian, as Excel writes it', () {
    // Decoded as UTF-8 this arrives as text separated by NUL bytes, and the
    // parser sees one enormous unusable field.
    final out = <int>[0xff, 0xfe];
    for (final u in 'Title\nBao'.codeUnits) {
      out.addAll([u & 0xff, u >> 8]);
    }
    expect(decodeFileBytes(bytes(out)), 'Title\nBao');
  });

  test('UTF-16 big-endian', () {
    final out = <int>[0xfe, 0xff];
    for (final u in 'Title'.codeUnits) {
      out.addAll([u >> 8, u & 0xff]);
    }
    expect(decodeFileBytes(bytes(out)), 'Title');
  });

  test('bytes that are not valid UTF-8 fall back rather than refusing', () {
    // Windows-1252, so 0xE9 is é. Latin-1 always decodes, so a file exported
    // from an older tool imports with a slightly wrong accent rather than not
    // at all — and a slightly wrong name still resolves.
    final text = decodeFileBytes(bytes([0x43, 0x61, 0x66, 0xe9]));
    expect(text, 'Café');
  });

  test('an empty file is refused', () {
    expect(
      () => decodeFileBytes(bytes([])),
      throwsA(isA<FileSourceUnavailable>()),
    );
  });

  group('KMZ', () {
    Uint8List kmz(Map<String, String> entries) {
      final archive = Archive();
      for (final e in entries.entries) {
        final data = utf8.encode(e.value);
        archive.add(ArchiveFile.bytes(e.key, data));
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    const kml =
        '<kml><Placemark><name>Time Out Market</name>'
        '<Point><coordinates>-9.1459,38.7071</coordinates></Point>'
        '</Placemark></kml>';

    test('doc.kml is found inside the archive', () {
      final text = decodeFileBytes(kmz({'doc.kml': kml}));
      expect(readPlaceFile(text).places.single.name, 'Time Out Market');
    });

    test('doc.kml wins over other KML in the same archive', () {
      final text = decodeFileBytes(
        kmz({
          'files/other.kml':
              '<kml><Placemark><name>Wrong</name></Placemark></kml>',
          'doc.kml': kml,
        }),
      );
      expect(readPlaceFile(text).places.single.name, 'Time Out Market');
    });

    test('a KMZ is recognised by its bytes, whatever it is named', () {
      // Some exporters write .kml for a zipped file, and users rename things.
      final text = decodeFileBytes(kmz({'doc.kml': kml}), name: 'places.kml');
      expect(readPlaceFile(text).places, hasLength(1));
    });

    test('an archive holding no KML says so', () {
      expect(
        () => decodeFileBytes(kmz({'readme.txt': 'nothing here'})),
        throwsA(isA<FileSourceUnavailable>()),
      );
    });

    test('a truncated archive is reported, not crashed on', () {
      final full = kmz({'doc.kml': kml});
      final half = Uint8List.sublistView(full, 0, full.length ~/ 2);
      expect(
        () => decodeFileBytes(half),
        throwsA(isA<FileSourceUnavailable>()),
      );
    });
  });
}
