/// AI 配置模型与端点归一化（`docs/phase6/design/04` §3）。
///
/// 纯逻辑层：不依赖 Flutter，也不依赖 `dart:io`。上游对应实现是
/// `AiConfig`（`app/src/main/java/com/fongmi/android/tv/bean/AiConfig.java`）。
///
/// **不实现**上游的 5 套提示词版本管理（推荐 / 标题提取 / 观影报告 /
/// 去广 / 分组规则）：那 5 套对应的是本轮不做的其他 AI 能力，
/// 集季识别的提示词是固定内置的。
library;

import 'tmdb_config.dart' show redactCredential;

/// AI 补全协议（`docs/phase6/design/04` §3.2）。
abstract final class AiProtocol {
  static const String openAiResponses = 'openai_responses';
  static const String openAiChat = 'openai_chat';
  static const String anthropicMessages = 'anthropic_messages';
  static const String geminiNative = 'gemini_native';

  static const String defaultProtocol = openAiResponses;

  /// 默认模型（对齐上游 `AiConfig.DEFAULT_MODEL`）。
  static const String defaultModel = 'gpt-4.1-mini';

  static const List<String> values = [
    openAiResponses,
    openAiChat,
    anthropicMessages,
    geminiNative,
  ];

  static bool isSupported(String? protocol) =>
      protocol != null && values.contains(protocol);

  static String defaultEndpoint(String protocol) => switch (protocol) {
    openAiChat => 'https://api.openai.com/v1/chat/completions',
    anthropicMessages => 'https://api.anthropic.com/v1/messages',
    geminiNative => 'https://generativelanguage.googleapis.com/v1beta',
    _ => 'https://api.openai.com/v1/responses',
  };
}

/// 去掉 `?query` 与 `#fragment`，并去掉尾部 `/`。
String cleanBaseEndpoint(String endpoint) {
  var value = endpoint.trim();
  final query = value.indexOf('?');
  if (query >= 0) value = value.substring(0, query);
  final fragment = value.indexOf('#');
  if (fragment >= 0) value = value.substring(0, fragment);
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 末段是否是 `vN` 形态（`v1`、`v1beta`）。
bool _endsWithVersionSegment(String url) {
  final last = url.substring(url.lastIndexOf('/') + 1);
  if (last.length < 2 || last[0] != 'v') return false;
  var i = 1;
  while (i < last.length && _isDigit(last.codeUnitAt(i))) {
    i++;
  }
  if (i == 1) return false;
  final suffix = last.substring(i);
  return suffix.isEmpty || suffix == 'beta' || suffix == 'alpha';
}

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

String _stripGeminiPrefix(String model) =>
    model.startsWith('models/') ? model.substring('models/'.length) : model;

/// AI 配置（`docs/phase6/design/04` §3.1）。
class AiConfig {
  const AiConfig({
    this.enabled = false,
    this.protocol = AiProtocol.defaultProtocol,
    this.endpoint = '',
    this.apiKey = '',
    this.model = '',
    this.customUserAgent = '',
  });

  final bool enabled;
  final String protocol;
  final String endpoint;
  final String apiKey;
  final String model;
  final String customUserAgent;

  /// 归一化后的副本：非法协议回落默认、空端点按协议填默认、空模型填默认。
  AiConfig sanitized() {
    final safeProtocol = AiProtocol.isSupported(protocol)
        ? protocol
        : AiProtocol.defaultProtocol;
    final endpointText = endpoint.trim();
    final modelText = model.trim();
    return AiConfig(
      enabled: enabled,
      protocol: safeProtocol,
      endpoint: endpointText.isEmpty
          ? AiProtocol.defaultEndpoint(safeProtocol)
          : endpointText,
      apiKey: apiKey.trim(),
      model: modelText.isEmpty ? AiProtocol.defaultModel : modelText,
      customUserAgent: customUserAgent.trim(),
    );
  }

  /// 是否可用于补全（四项齐备）。
  bool get isReady {
    final safe = sanitized();
    return safe.enabled &&
        safe.endpoint.isNotEmpty &&
        safe.apiKey.isNotEmpty &&
        safe.model.isNotEmpty;
  }

  /// 是否可用于拉取模型列表（不需要 model）。
  bool get isModelFetchReady {
    final safe = sanitized();
    return safe.endpoint.isNotEmpty && safe.apiKey.isNotEmpty;
  }

  /// 展示用的脱敏 key。复用 TMDB 凭据的脱敏实现，行为一致。
  String get redactedApiKey => redactCredential(apiKey);

  /// 归一化后的补全端点（`docs/phase6/design/04` §3.5）。
  ///
  /// 用户填基址也能用：按协议补路径段；已是完整端点则原样。
  String get completionUrl {
    final safe = sanitized();
    final base = cleanBaseEndpoint(safe.endpoint);
    switch (safe.protocol) {
      case AiProtocol.openAiChat:
        return _appendCompletionPath(base, 'chat/completions');
      case AiProtocol.anthropicMessages:
        return _appendCompletionPath(base, 'messages');
      case AiProtocol.geminiNative:
        return _geminiGenerateContentUrl(base, safe.model);
      default:
        return _appendCompletionPath(base, 'responses');
    }
  }

  static String _appendCompletionPath(String endpoint, String path) {
    if (endpoint.isEmpty) return '';
    if (endpoint.endsWith('/$path')) return endpoint;
    if (_endsWithVersionSegment(endpoint)) return '$endpoint/$path';
    return '$endpoint/v1/$path';
  }

  static String _geminiGenerateContentUrl(String endpoint, String model) {
    if (endpoint.contains(':generateContent')) return endpoint;
    final modelPath = 'models/${_stripGeminiPrefix(model)}';
    // 端点已写到 `/models`：只补模型段**并保留 `:generateContent` 方法后缀**。
    //
    // 【brief 缺陷】原文写的是
    //     return '$endpoint/$modelPath'.replaceFirst('/models/models/', '/models/');
    // 它**漏掉了 `:generateContent`**，于是 `https://x/v1beta/models` 会算出
    // `https://x/v1beta/models/gemini-2.0-flash`——一个不是补全接口的地址。
    // brief 自己的用例「端点以 /models 结尾只补模型段」期望的是
    // `.../gemini-2.0-flash:generateContent`，即**实现与它的测试矛盾**。
    // 这里按测试（= 正确行为）修正。
    if (endpoint.endsWith('/models')) {
      return '$endpoint/${_stripGeminiPrefix(model)}:generateContent';
    }
    var value = endpoint;
    if (!_endsWithVersionSegment(value)) value = '$value/v1beta';
    return '$value/$modelPath:generateContent';
  }

  AiConfig copyWith({
    bool? enabled,
    String? protocol,
    String? endpoint,
    String? apiKey,
    String? model,
    String? customUserAgent,
  }) => AiConfig(
    enabled: enabled ?? this.enabled,
    protocol: protocol ?? this.protocol,
    endpoint: endpoint ?? this.endpoint,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    customUserAgent: customUserAgent ?? this.customUserAgent,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'protocol': protocol,
    'endpoint': endpoint,
    'apiKey': apiKey,
    'model': model,
    'customUserAgent': customUserAgent,
  };

  /// 容错读取：字段类型不对时用默认值，不抛异常。
  static AiConfig fromJson(Object? value) {
    if (value is! Map) return const AiConfig();
    final map = value.cast<Object?, Object?>();
    return AiConfig(
      enabled: map['enabled'] == true,
      protocol: map['protocol'] is String
          ? map['protocol']! as String
          : AiProtocol.defaultProtocol,
      endpoint: map['endpoint'] is String ? map['endpoint']! as String : '',
      apiKey: map['apiKey'] is String ? map['apiKey']! as String : '',
      model: map['model'] is String ? map['model']! as String : '',
      customUserAgent: map['customUserAgent'] is String
          ? map['customUserAgent']! as String
          : '',
    ).sanitized();
  }

  @override
  String toString() =>
      'AiConfig(enabled=$enabled, protocol=$protocol, endpoint=$endpoint, '
      'apiKey=$redactedApiKey, model=$model)';
}
