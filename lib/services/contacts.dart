import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_contacts/flutter_contacts.dart';

class ContactsService {
  /// Search device contacts by name. Returns up to [maxResults] matches
  /// with their phone numbers. Requests permission on first call.
  static Future<Map<String, dynamic>> searchContacts(dynamic args) async {
    if (kIsWeb) {
      return {'ok': false, 'error': 'Contact access is not available on web.'};
    }

    final name = args is Map ? (args['name'] as String?)?.trim() ?? '' : '';
    if (name.isEmpty) {
      return {'ok': false, 'error': 'name is required'};
    }

    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) {
      return {'ok': false, 'error': 'Contacts permission was denied.'};
    }

    final all = await FlutterContacts.getContacts(withProperties: true);
    final query = name.toLowerCase();
    final matches = all
        .where((c) => c.displayName.toLowerCase().contains(query))
        .take(5)
        .map((c) {
          final phones = c.phones.map((p) => {
            'label': p.label.name,
            'number': p.number,
          }).toList();
          return {
            'name': c.displayName,
            'phones': phones,
          };
        })
        .toList();

    if (matches.isEmpty) {
      return {'ok': true, 'found': 0, 'contacts': [], 'message': 'No contacts found matching "$name".'};
    }

    return {'ok': true, 'found': matches.length, 'contacts': matches};
  }
}
