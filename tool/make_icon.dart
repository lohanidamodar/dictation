import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Draws the application icon, the same microphone the tray shows.
///
/// Generated rather than committed, so there is one definition of what the
/// icon looks like — `ui_host.dart` draws this shape into a 32×32 bitmap at
/// runtime, and this draws it at every size Explorer and the installer ask
/// for. A hand-made .ico beside it would drift.
void main(List<String> argv) {
  final out = File(argv.isNotEmpty ? argv.first : 'installer/dictation.ico');
  out.parent.createSync(recursive: true);

  // 256 for high-DPI, 16 because the taskbar and title bars still use it.
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  out.writeAsBytesSync(_ico([for (final s in sizes) (s, _draw(s))]));

  stdout.writeln('${out.path}  '
      '${(out.lengthSync() / 1024).round()} KB  '
      '(${sizes.join(", ")})');
}

/// Slate plate, white microphone — legible at 16 pixels, which is the size
/// that decides whether an icon works.
const _plate = (0x24, 0x2A, 0x3C);
const _glyph = (0xF2, 0xF4, 0xF8);

/// Renders one square of BGRA pixels, top row first.
Uint8List _draw(int size) {
  final pixels = Uint8List(size * size * 4);

  // Three samples per axis. At 16 pixels the difference between this and
  // hard edges is the difference between a microphone and a smudge.
  const samples = 3;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var plate = 0.0, glyph = 0.0;
      for (var sy = 0; sy < samples; sy++) {
        for (var sx = 0; sx < samples; sx++) {
          final u = (x + (sx + 0.5) / samples) / size;
          final v = (y + (sy + 0.5) / samples) / size;
          if (_inPlate(u, v)) plate += 1;
          if (_inMicrophone(u, v)) glyph += 1;
        }
      }
      const total = samples * samples;
      plate /= total;
      glyph /= total;

      // The glyph sits on the plate, so its coverage also counts as opacity.
      final alpha = math.max(plate, glyph);
      final mix = alpha == 0 ? 0.0 : glyph / alpha;

      final i = (y * size + x) * 4;
      pixels[i] = _blend(_plate.$3, _glyph.$3, mix);
      pixels[i + 1] = _blend(_plate.$2, _glyph.$2, mix);
      pixels[i + 2] = _blend(_plate.$1, _glyph.$1, mix);
      pixels[i + 3] = (alpha * 255).round();
    }
  }
  return pixels;
}

int _blend(int from, int to, double t) => (from + (to - from) * t).round();

/// A rounded square with a little breathing room, the shape every platform's
/// icon guidelines settled on.
bool _inPlate(double x, double y) {
  const inset = 0.045, radius = 0.20;
  final left = inset, right = 1 - inset;
  final dx = math.max(math.max(left + radius - x, x - (right - radius)), 0.0);
  final dy = math.max(math.max(left + radius - y, y - (right - radius)), 0.0);
  if (x < left || x > right || y < left || y > right) return false;
  return dx * dx + dy * dy <= radius * radius;
}

/// The microphone, in the same proportions the tray icon uses, inset so it
/// does not touch the edge of the plate.
bool _inMicrophone(double x, double y) {
  const scale = 0.78;
  final u = (x - 0.5) / scale;
  final v = (y - 0.5) / scale + 0.5;

  double distance(double cx, double cy) =>
      math.sqrt(math.pow(u - cx, 2) + math.pow(v - cy, 2));

  // Capsule.
  const radius = 0.156, top = 0.1875, bottom = 0.594;
  final withinX = u.abs() <= radius;
  if (withinX && v >= top && v <= bottom) return true;
  if (distance(0, top) <= radius || distance(0, bottom) <= radius) return true;

  // Cradle: an arc under the capsule.
  final cradle = distance(0, 0.5625);
  if (v > 0.5625 && cradle >= 0.266 && cradle <= 0.3125) return true;

  // Stem and base.
  if (u.abs() <= 0.0375 && v >= 0.84 && v <= 0.906) return true;
  if (u.abs() <= 0.156 && v >= 0.906 && v <= 0.9375) return true;

  return false;
}

/// Packs the images into an .ico.
///
/// Uncompressed 32-bit bitmaps: an .ico may hold PNGs instead, and would be
/// smaller for the 256, but that needs a PNG encoder for one build artefact.
Uint8List _ico(List<(int, Uint8List)> images) {
  final encoded = [for (final (size, pixels) in images) _dib(size, pixels)];

  const dirEntry = 16;
  var offset = 6 + dirEntry * images.length;

  final header = BytesBuilder()
    ..add(_u16(0)) // reserved
    ..add(_u16(1)) // 1 = icon
    ..add(_u16(images.length));

  for (var i = 0; i < images.length; i++) {
    final size = images[i].$1;
    header
      ..addByte(size == 256 ? 0 : size) // 0 means 256
      ..addByte(size == 256 ? 0 : size)
      ..addByte(0) // palette size: none, this is true colour
      ..addByte(0) // reserved
      ..add(_u16(1)) // colour planes
      ..add(_u16(32)) // bits per pixel
      ..add(_u32(encoded[i].length))
      ..add(_u32(offset));
    offset += encoded[i].length;
  }

  final file = BytesBuilder()..add(header.toBytes());
  for (final image in encoded) {
    file.add(image);
  }
  return file.toBytes();
}

/// One image: a BITMAPINFOHEADER, the pixels bottom-up, then an AND mask.
///
/// The height in the header is doubled because it describes the colour rows
/// and the mask rows together. The mask is unused for 32-bit images — the
/// alpha channel does that work — but the format still requires it.
Uint8List _dib(int size, Uint8List pixels) {
  final out = BytesBuilder()
    ..add(_u32(40)) // header size
    ..add(_u32(size))
    ..add(_u32(size * 2))
    ..add(_u16(1))
    ..add(_u16(32))
    ..add(_u32(0)) // BI_RGB, uncompressed
    ..add(_u32(size * size * 4))
    ..add(_u32(0)) // pixels per metre: irrelevant for an icon
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0));

  for (var y = size - 1; y >= 0; y--) {
    out.add(Uint8List.sublistView(pixels, y * size * 4, (y + 1) * size * 4));
  }

  // Mask rows are 1 bit per pixel and padded to a 4-byte boundary.
  final maskRow = ((size + 31) ~/ 32) * 4;
  out.add(Uint8List(maskRow * size));

  return out.toBytes();
}

Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
