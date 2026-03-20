import 'package:flutter_test/flutter_test.dart';
import 'package:road_mate_flutter/models/whatsapp_contact.dart';

void main() {
  group('WhatsAppContact.fromMemoryLine', () {
    test('parses possessive format', () {
      final contact = WhatsAppContact.fromMemoryLine("mom's whatsapp is +1234567890");
      expect(contact, isNotNull);
      expect(contact!.name, 'Mom');
      expect(contact.phoneNumber, '+1234567890');
    });

    test('parses colon format', () {
      final contact = WhatsAppContact.fromMemoryLine("Alice WhatsApp: +44123456789");
      expect(contact, isNotNull);
      expect(contact!.name, 'Alice');
      expect(contact.phoneNumber, '+44123456789');
    });

    test('parses "whatsapp for" format', () {
      final contact = WhatsAppContact.fromMemoryLine("whatsapp for Bob: +1 (408) 555-1234");
      expect(contact, isNotNull);
      expect(contact!.name, 'Bob');
      expect(contact.phoneNumber, '+14085551234');
    });

    test('parses number format', () {
      final contact = WhatsAppContact.fromMemoryLine("John's WhatsApp number is +1-408-555-9876");
      expect(contact, isNotNull);
      expect(contact!.name, 'John');
      expect(contact.phoneNumber, '+14085559876');
    });

    test('cleans phone number with spaces and dashes', () {
      final contact = WhatsAppContact.fromMemoryLine("Sarah's whatsapp is +1 (650) 555-0123");
      expect(contact, isNotNull);
      expect(contact!.phoneNumber, '+16505550123');
    });

    test('adds +1 to 10-digit US numbers', () {
      final contact = WhatsAppContact.fromMemoryLine("Tom's whatsapp is 4085551234");
      expect(contact, isNotNull);
      expect(contact!.phoneNumber, '+14085551234');
    });

    test('returns null for lines without whatsapp keyword', () {
      final contact = WhatsAppContact.fromMemoryLine("Alice's phone is 1234567890");
      expect(contact, isNull);
    });

    test('returns null for lines without valid phone number', () {
      final contact = WhatsAppContact.fromMemoryLine("mom's whatsapp is unknown");
      expect(contact, isNull);
    });

    test('capitalizes multi-word names', () {
      final contact = WhatsAppContact.fromMemoryLine("mary jane's whatsapp is +1234567890");
      expect(contact, isNotNull);
      expect(contact!.name, 'Mary Jane');
    });
  });
}
