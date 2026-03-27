class WhatsAppService {
  static final WhatsAppService instance = WhatsAppService._();
  WhatsAppService._();

  Future<Map<String, dynamic>> toolSendWhatsAppMessage(dynamic args) async =>
      {'ok': false, 'error': 'WhatsApp messaging is not available on web.'};
}
