/// Minimal RFC 4122 version 4 UUID generator.
///
/// The two legs of a transfer have to be written in a single insert while
/// already sharing a `transfer_group_id`, so the id cannot come from the
/// database `gen_random_uuid()` default — that would give each row a
/// different value. It is generated here instead.
///
/// This is deliberately a few lines rather than a new package dependency:
/// generating one opaque grouping id is the only thing the app needs, and the
/// format is fully specified.
library;

import 'dart:math';
import 'dart:typed_data';

class Uuid {
  const Uuid._();

  static final Random _random = Random.secure();

  static const String _hex = '0123456789abcdef';

  /// A random (version 4, variant 1) UUID in canonical 8-4-4-4-12 form.
  static String v4() {
    final Uint8List bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }

    // Version 4: high nibble of byte 6 is 0100.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Variant 1: top two bits of byte 8 are 10.
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) buffer.write('-');
      final int byte = bytes[i];
      buffer
        ..write(_hex[(byte >> 4) & 0x0f])
        ..write(_hex[byte & 0x0f]);
    }
    return buffer.toString();
  }
}
