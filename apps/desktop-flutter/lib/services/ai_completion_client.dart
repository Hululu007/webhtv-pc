/// AI 补全客户端（`docs/phase6/design/04` §5）。
///
/// 上游对应实现是 `AiCompletionClient`。**请求规格构造与发送分离**：
/// `buildAiRequestSpec` 是纯函数，可在无网络环境下断言请求形态
/// （对齐 Phase 5 的「L2 用请求捕获断言请求形态」纪律）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/ai_config.dart';

/// 一次补全请求的规格。
class AiRequestSpec {
  const AiRequestSpec({
    required this.url,
    required this.body,
    required this.headers,
  });

  final String url;
  final Map<String, Object?> body;
  final Map<String, String> headers;
}

/// 输出 token 上限（对齐上游 `MAX_OUTPUT_TOKENS`）。
const int aiMaxOutputTokens = 4096;

/// Anthropic 的 API 版本头（对齐上游）。
const String aiAnthropicVersion = '2023-06-01';

/// 构造请求规格（`docs/phase6/design/04` §5.1）。
AiRequestSpec buildAiRequestSpec(AiConfig config, String prompt) {
  final safe = config.sanitized();
  final body = <String, Object?>{};
  final headers = <String, String>{'Content-Type': 'application/json'};

  switch (safe.protocol) {
    case AiProtocol.openAiChat:
      body['model'] = safe.model;
      body['messages'] = [
        {'role': 'user', 'content': prompt},
      ];
      headers['Authorization'] = 'Bearer ${safe.apiKey}';
    case AiProtocol.anthropicMessages:
      body['model'] = safe.model;
      body['max_tokens'] = aiMaxOutputTokens;
      body['messages'] = [
        {'role': 'user', 'content': prompt},
      ];
      headers['x-api-key'] = safe.apiKey;
      headers['anthropic-version'] = aiAnthropicVersion;
    case AiProtocol.geminiNative:
      body['contents'] = [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
          ],
        },
      ];
      body['generationConfig'] = {'maxOutputTokens': aiMaxOutputTokens};
      headers['x-goog-api-key'] = safe.apiKey;
    default:
      body['model'] = safe.model;
      body['input'] = prompt;
      body['max_output_tokens'] = aiMaxOutputTokens;
      headers['Authorization'] = 'Bearer ${safe.apiKey}';
  }

  final userAgent = _sanitizeUserAgent(safe.customUserAgent);
  if (userAgent.isNotEmpty) headers['User-Agent'] = userAgent;

  return AiRequestSpec(
    url: safe.completionUrl,
    body: body,
    headers: headers,
  );
}

/// 用户代理清洗：含控制字符时整串丢弃（对齐上游 `sanitizeUserAgent`）。
String _sanitizeUserAgent(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  for (final code in value.codeUnits) {
    if ((code < 0x20 && code != 0x09) || code == 0x7F) return '';
  }
  return value;
}

/// 从响应体里抽取补全文本（`docs/phase6/design/04` §5.2）。
///
/// 按协议各一套，**且交叉兜底**：中转站常返回与所选协议不符的结构，
/// 兜底让"配置填得不够准"也能工作。
String extractAiCompletionText(String body, AiConfig config) {
  if (body.trim().isEmpty) return '';
  final safe = config.sanitized();

  String byProtocol() => switch (safe.protocol) {
    AiProtocol.openAiChat => _openAiChatText(body),
    AiProtocol.anthropicMessages => _anthropicText(body),
    AiProtocol.geminiNative => _geminiText(body),
    _ => _openAiResponsesText(body),
  };

  final primary = byProtocol();
  if (primary.isNotEmpty) return primary;

  // 交叉兜底：依次试其余三种。
  for (final text in [
    _openAiResponsesText(body),
    _openAiChatText(body),
    _anthropicText(body),
    _geminiText(body),
  ]) {
    if (text.isNotEmpty) return text;
  }
  return '';
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

Map<String, Object?>? _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

List<Object?> _asList(Object? value) => value is List ? value : const [];

/// `output_text` → `output[].content[].text`。
String _openAiResponsesText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final direct = root['output_text'];
  if (direct is String && direct.trim().isNotEmpty) return direct.trim();
  final buffer = StringBuffer();
  for (final item in _asList(root['output'])) {
    final map = _asMap(item);
    if (map == null) continue;
    _appendContent(buffer, map['content']);
  }
  return buffer.toString().trim();
}

/// `choices[].message.content` / `choices[].delta.content` / `choices[].text`。
String _openAiChatText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final buffer = StringBuffer();
  for (final choice in _asList(root['choices'])) {
    final map = _asMap(choice);
    if (map == null) continue;
    _appendContent(buffer, _asMap(map['message'])?['content']);
    _appendContent(buffer, _asMap(map['delta'])?['content']);
    final text = map['text'];
    if (text is String && text.trim().isNotEmpty) {
      _appendLine(buffer, text);
    }
  }
  return buffer.toString().trim();
}

/// `completion` → `content[].text`。
String _anthropicText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final buffer = StringBuffer();
  final completion = root['completion'];
  if (completion is String && completion.trim().isNotEmpty) {
    _appendLine(buffer, completion);
  }
  for (final item in _asList(root['content'])) {
    final map = _asMap(item);
    if (map != null) {
      _appendText(map, buffer);
      continue;
    }
    if (item is String && item.trim().isNotEmpty) _appendLine(buffer, item);
  }
  return buffer.toString().trim();
}

/// `text` → `candidates[].content.parts[].text`。
String _geminiText(String body) {
  final root = _asMap(_decode(body));
  if (root == null) return '';
  final buffer = StringBuffer();
  final text = root['text'];
  if (text is String && text.trim().isNotEmpty) _appendLine(buffer, text);
  for (final candidate in _asList(root['candidates'])) {
    final map = _asMap(candidate);
    if (map == null) continue;
    final content = _asMap(map['content']);
    if (content == null) continue;
    for (final part in _asList(content['parts'])) {
      final partMap = _asMap(part);
      if (partMap != null) {
        _appendText(partMap, buffer);
        continue;
      }
      if (part is String && part.trim().isNotEmpty) _appendLine(buffer, part);
    }
  }
  return buffer.toString().trim();
}

void _appendText(Map<String, Object?> map, StringBuffer buffer) {
  for (final key in const ['text', 'output_text', 'value', 'arguments']) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) {
      _appendLine(buffer, value);
      return;
    }
  }
}

void _appendContent(StringBuffer buffer, Object? content) {
  if (content == null) return;
  if (content is String) {
    _appendLine(buffer, content);
    return;
  }
  final map = _asMap(content);
  if (map != null) {
    _appendText(map, buffer);
    return;
  }
  for (final item in _asList(content)) {
    final itemMap = _asMap(item);
    if (itemMap != null) {
      _appendText(itemMap, buffer);
      continue;
    }
    if (item is String && item.trim().isNotEmpty) _appendLine(buffer, item);
  }
}

void _appendLine(StringBuffer buffer, String text) {
  final value = text.trim();
  if (value.isEmpty) return;
  if (buffer.isNotEmpty) buffer.write('\n');
  buffer.write(value);
}

/// 一次补全的结果。
class AiCompletionResult {
  const AiCompletionResult({
    required this.ok,
    required this.statusCode,
    required this.text,
    required this.message,
  });

  final bool ok;
  final int statusCode;
  final String text;

  /// 失败原因（用户可读）；成功时为空。
  final String message;

  static const AiCompletionResult configIncomplete = AiCompletionResult(
    ok: false,
    statusCode: 0,
    text: '',
    message: 'AI 服务未配置完成（需要启用、端点、API Key、模型）',
  );
}

class AiCompletionClient {
  AiCompletionClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 默认超时：连接 15s / 读 90s / 整体 105s（对齐上游）。
  static const Duration defaultTimeout = Duration(seconds: 105);

  /// 发一次补全请求。
  Future<AiCompletionResult> complete({
    required AiConfig config,
    required String prompt,
    Duration timeout = defaultTimeout,
  }) async {
    final safe = config.sanitized();
    if (!safe.isReady) return AiCompletionResult.configIncomplete;

    final spec = buildAiRequestSpec(safe, prompt);
    try {
      final response = await _client
          .post(
            Uri.parse(spec.url),
            headers: spec.headers,
            body: jsonEncode(spec.body),
          )
          .timeout(timeout);
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return AiCompletionResult(
          ok: false,
          statusCode: response.statusCode,
          text: '',
          message: 'HTTP ${response.statusCode}',
        );
      }
      final text = extractAiCompletionText(body, safe);
      if (text.isEmpty) {
        return AiCompletionResult(
          ok: false,
          statusCode: response.statusCode,
          text: '',
          message: '接口已响应，但没有解析到 AI 输出',
        );
      }
      return AiCompletionResult(
        ok: true,
        statusCode: response.statusCode,
        text: text,
        message: '',
      );
    } on TimeoutException {
      return const AiCompletionResult(
        ok: false,
        statusCode: 0,
        text: '',
        message: '请求超时',
      );
    } on SocketException catch (error) {
      return AiCompletionResult(
        ok: false,
        statusCode: 0,
        text: '',
        message: '网络错误：${error.message}',
      );
    } catch (error) {
      return AiCompletionResult(
        ok: false,
        statusCode: 0,
        text: '',
        message: '$error',
      );
    }
  }

  void close() => _client.close();
}

/// 拉取模型列表（`docs/phase6/design/04` §7.6）。
///
/// OpenAI 兼容端点走 `/v1/models`，Gemini 走 `/v1beta/models`。
/// **失败返回空列表**（不是错误）：模型名可以手填，拉列表只是便利。
Future<List<String>> fetchAiModelList(AiConfig config) async {
  final safe = config.sanitized();
  if (!safe.isModelFetchReady) return const [];
  final base = cleanBaseEndpoint(safe.endpoint);
  final url = safe.protocol == AiProtocol.geminiNative
      ? '${_geminiModelsBase(base)}/models'
      : '${_openAiModelsBase(base)}/models';

  final client = http.Client();
  try {
    final response = await client
        .get(Uri.parse(url), headers: _modelFetchHeaders(safe))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    return _parseModelList(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
  } catch (_) {
    return const [];
  } finally {
    client.close();
  }
}

Map<String, String> _modelFetchHeaders(AiConfig config) {
  if (config.protocol == AiProtocol.geminiNative) {
    return {'x-goog-api-key': config.apiKey};
  }
  final headers = {'Authorization': 'Bearer ${config.apiKey}'};
  if (config.protocol == AiProtocol.anthropicMessages) {
    headers['x-api-key'] = config.apiKey;
    headers['anthropic-version'] = aiAnthropicVersion;
  }
  final userAgent = _sanitizeUserAgent(config.customUserAgent);
  if (userAgent.isNotEmpty) headers['User-Agent'] = userAgent;
  return headers;
}

/// 模型列表基址：把完整补全端点退回其 `/v1` 父级。
String _openAiModelsBase(String base) {
  if (base.endsWith('/v1')) return base;
  for (final suffix in const ['/responses', '/chat/completions', '/messages']) {
    if (base.endsWith(suffix)) {
      return base.substring(0, base.length - suffix.length);
    }
  }
  return '$base/v1';
}

String _geminiModelsBase(String base) {
  if (base.endsWith('/models')) {
    return base.substring(0, base.length - '/models'.length);
  }
  final marker = base.indexOf('/models/');
  if (marker >= 0) return base.substring(0, marker);
  if (endsWithVersionSegment(base)) return base;
  return '$base/v1beta';
}

List<String> _parseModelList(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const [];
    final result = <String>[];
    for (final key in const ['data', 'models']) {
      final list = decoded[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id'] ?? item['name'] ?? item['baseModelId'];
        if (id is String && id.trim().isNotEmpty) {
          result.add(
            id.startsWith('models/') ? id.substring('models/'.length) : id.trim(),
          );
        }
      }
    }
    result.sort();
    return result;
  } catch (_) {
    return const [];
  }
}
