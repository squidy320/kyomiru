import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class AndroidHttpBridgeResponse {
  const AndroidHttpBridgeResponse({
    required this.statusCode,
    required this.body,
    this.error,
  });

  final int statusCode;
  final String body;
  final String? error;
}

class AndroidHttpBridge {
  static const MethodChannel _channel = MethodChannel('kyomiru/android_http');

  static Future<AndroidHttpBridgeResponse?> request({
    required String url,
    required String method,
    Map<String, String> headers = const {},
    String? body,
  }) async {
    if (!Platform.isAndroid) return null;
    final payload = <String, dynamic>{
      'url': url,
      'method': method,
      'headers': headers,
      if (body != null) 'body': body,
    };
    final raw =
        await _channel.invokeMapMethod<String, dynamic>('request', payload);
    if (raw == null) return null;
    return AndroidHttpBridgeResponse(
      statusCode: (raw['statusCode'] as num?)?.toInt() ?? -1,
      body: (raw['body'] ?? '').toString(),
      error: raw['error']?.toString(),
    );
  }

  static String encodeJsonBody(Map<String, dynamic> data) => jsonEncode(data);
}

