/// Model for WhatsApp contacts parsed from memory.
class WhatsAppContact {
  final String name;
  final String phoneNumber;

  WhatsAppContact({
    required this.name,
    required this.phoneNumber,
  });

  /// Parse a WhatsApp contact from a memory line.
  ///
  /// Supports various formats:
  /// - "mom's whatsapp is +1234567890"
  /// - "Alice WhatsApp: +44123456789"
  /// - "whatsapp for Bob: +1..."
  /// - "Bob's WhatsApp number is +1..."
  static WhatsAppContact? fromMemoryLine(String line) {
    final normalizedLine = line.toLowerCase().trim();

    // Must contain "whatsapp" keyword
    if (!normalizedLine.contains('whatsapp')) {
      return null;
    }

    // Try to extract phone number (starts with + or is all digits)
    final phoneRegex = RegExp(r'\+?[\d\s\-\(\)]+');
    final phoneMatches = phoneRegex.allMatches(line);

    String? phoneNumber;
    for (final match in phoneMatches) {
      final candidate = match.group(0)!;
      // Must have at least 7 digits to be valid
      final digitCount = candidate.replaceAll(RegExp(r'\D'), '').length;
      if (digitCount >= 7) {
        phoneNumber = _cleanPhoneNumber(candidate);
        break;
      }
    }

    if (phoneNumber == null) {
      return null;
    }

    // Extract name (text before "whatsapp" or "'s")
    String name = '';

    // Pattern 1: "Name's whatsapp..."
    final possessiveMatch = RegExp(r"^([^']+)'s\s+whatsapp", caseSensitive: false)
        .firstMatch(normalizedLine);
    if (possessiveMatch != null) {
      name = possessiveMatch.group(1)!.trim();
    }

    // Pattern 2: "Name WhatsApp:..."
    if (name.isEmpty) {
      final colonMatch = RegExp(r'^([^:]+)\s+whatsapp\s*:', caseSensitive: false)
          .firstMatch(normalizedLine);
      if (colonMatch != null) {
        name = colonMatch.group(1)!.trim();
      }
    }

    // Pattern 3: "whatsapp for Name..."
    if (name.isEmpty) {
      final forMatch = RegExp(r'whatsapp\s+for\s+([^:]+?)(?:\s+is|\s*:)', caseSensitive: false)
          .firstMatch(normalizedLine);
      if (forMatch != null) {
        name = forMatch.group(1)!.trim();
      }
    }

    // Pattern 4: "Name WhatsApp number is..."
    if (name.isEmpty) {
      final numberMatch = RegExp(r"^([^']+)'s?\s+whatsapp\s+number", caseSensitive: false)
          .firstMatch(normalizedLine);
      if (numberMatch != null) {
        name = numberMatch.group(1)!.trim();
      }
    }

    // Default: use first word if nothing else works
    if (name.isEmpty) {
      name = normalizedLine.split(RegExp(r'\s+'))[0];
    }

    // Capitalize first letter of each word
    name = name.split(' ')
        .map((word) => word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1))
        .join(' ');

    return WhatsAppContact(
      name: name,
      phoneNumber: phoneNumber,
    );
  }

  /// Clean phone number by removing spaces, dashes, parentheses.
  static String _cleanPhoneNumber(String phone) {
    String cleaned = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');

    // Ensure it starts with + for international format
    if (!cleaned.startsWith('+')) {
      // If it's a US number without country code, add +1
      if (cleaned.length == 10) {
        cleaned = '+1$cleaned';
      } else if (cleaned.length == 11 && cleaned.startsWith('1')) {
        cleaned = '+$cleaned';
      }
    }

    return cleaned;
  }

  @override
  String toString() => '$name: $phoneNumber';
}
