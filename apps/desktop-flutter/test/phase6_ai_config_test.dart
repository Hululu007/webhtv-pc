/// AI 配置模型与端点归一化（`docs/phase6/design/04` §3）。
///
/// 纯逻辑：不依赖 Flutter，也不发任何网络请求。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';

void main() {
  group('协议常量', () {
    test('4 种协议与上游一致', () {
      expect(AiProtocol.values, [
        'openai_responses',
        'openai_chat',
        'anthropic_messages',
        'gemini_native',
      ]);
    });

    test('默认协议是 openai_responses', () {
      expect(AiProtocol.defaultProtocol, 'openai_responses');
    });

    test('默认端点按协议区分', () {
      expect(
        AiProtocol.defaultEndpoint('openai_responses'),
        'https://api.openai.com/v1/responses',
      );
      expect(
        AiProtocol.defaultEndpoint('openai_chat'),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        AiProtocol.defaultEndpoint('anthropic_messages'),
        'https://api.anthropic.com/v1/messages',
      );
      expect(
        AiProtocol.defaultEndpoint('gemini_native'),
        'https://generativelanguage.googleapis.com/v1beta',
      );
    });

    test('isSupported 只认 4 个值', () {
      expect(AiProtocol.isSupported('openai_chat'), isTrue);
      expect(AiProtocol.isSupported('OPENAI_CHAT'), isFalse);
      expect(AiProtocol.isSupported(null), isFalse);
      expect(AiProtocol.isSupported('nonsense'), isFalse);
    });
  });

  group('sanitized：归一化', () {
    test('非法协议回落默认', () {
      final config = const AiConfig(protocol: 'nonsense').sanitized();
      expect(config.protocol, AiProtocol.defaultProtocol);
    });

    test('端点为空时按协议填默认', () {
      final config = const AiConfig(protocol: 'openai_chat').sanitized();
      expect(config.endpoint, AiProtocol.defaultEndpoint('openai_chat'));
    });

    test('模型为空时填默认', () {
      final config = const AiConfig().sanitized();
      expect(config.model, AiProtocol.defaultModel);
    });

    test('apiKey 去空白', () {
      final config = const AiConfig(apiKey: '  sk-abc  ').sanitized();
      expect(config.apiKey, 'sk-abc');
    });

    test('已填的端点不被默认值覆盖', () {
      final config = const AiConfig(
        endpoint: 'https://api.deepseek.com/v1',
      ).sanitized();
      expect(config.endpoint, 'https://api.deepseek.com/v1');
    });
  });

  group('isReady / isModelFetchReady', () {
    test('未启用 → 未就绪', () {
      final config = const AiConfig(
        endpoint: 'https://x/v1',
        apiKey: 'k',
        model: 'm',
      ).sanitized();
      expect(config.isReady, isFalse);
    });

    test('缺 key → 未就绪', () {
      final config = const AiConfig(
        enabled: true,
        endpoint: 'https://x/v1',
        model: 'm',
      ).sanitized();
      expect(config.isReady, isFalse);
    });

    test('四项齐备 → 就绪', () {
      final config = const AiConfig(
        enabled: true,
        endpoint: 'https://x/v1',
        apiKey: 'k',
        model: 'm',
      ).sanitized();
      expect(config.isReady, isTrue);
    });

    test('拉模型列表不需要 model，但需要 key', () {
      final config = const AiConfig(
        endpoint: 'https://x/v1',
        apiKey: 'k',
      ).sanitized();
      expect(config.isModelFetchReady, isTrue);
      final noKey = const AiConfig(endpoint: 'https://x/v1').sanitized();
      expect(noKey.isModelFetchReady, isFalse);
    });

    // **锁住 `sanitized()` 与就绪判定的真实交互**（变异自检发现）：
    //
    // `isReady` 里对 `endpoint` / `model` 的非空检查是**永真**的——
    // 因为它先调 `sanitized()`，而 `sanitized()` 会按协议填默认端点、
    // 并填默认模型（`AiProtocol.defaultModel`），两者都不可能为空。
    // 因此 `isReady` 实际只取决于 `enabled` 与 `apiKey`（`isModelFetchReady`
    // 只取决于 `apiKey`）。
    //
    // 这条用例把「端点/模型留空也照样就绪」这个**真实语义**钉住：
    // 若将来有人改掉 `sanitized()` 的默认值填充，这条会失败并提醒他
    // 重新审查 `isReady`/`isModelFetchReady` 那两行永真条件。
    test('enabled+key 齐备但端点/模型留空 → 默认值填充后仍就绪', () {
      final config = const AiConfig(enabled: true, apiKey: 'k').sanitized();
      expect(config.endpoint, isNotEmpty, reason: 'sanitized 按协议填默认端点');
      expect(config.model, isNotEmpty, reason: 'sanitized 填默认模型');
      expect(
        config.isReady,
        isTrue,
        reason:
            '端点与模型都有默认值，用户只需 enabled + 填 key。'
            '这也意味着 isReady 里的 endpoint/model 非空检查是永真的。',
      );
      // 反过来：只有 enabled 没有 key 就不行（key 没有默认值）。
      expect(const AiConfig(enabled: true).sanitized().isReady, isFalse);
    });
  });

  group('cleanBaseEndpoint', () {
    test('去掉 query 与 fragment', () {
      expect(
        cleanBaseEndpoint('https://x/v1?a=1#frag'),
        'https://x/v1',
      );
    });

    test('去掉尾部斜杠', () {
      expect(cleanBaseEndpoint('https://x/v1///'), 'https://x/v1');
    });
  });

  group('completionUrl：端点归一化（§3.5）', () {
    test('openai_responses：基址补 /v1/responses', () {
      final config = const AiConfig(
        protocol: 'openai_responses',
        endpoint: 'https://api.openai.com',
      ).sanitized();
      expect(config.completionUrl, 'https://api.openai.com/v1/responses');
    });

    test('openai_responses：已是 /v1 只补路径段', () {
      final config = const AiConfig(
        protocol: 'openai_responses',
        endpoint: 'https://api.openai.com/v1',
      ).sanitized();
      expect(config.completionUrl, 'https://api.openai.com/v1/responses');
    });

    test('openai_responses：已是完整端点原样', () {
      final config = const AiConfig(
        protocol: 'openai_responses',
        endpoint: 'https://api.openai.com/v1/responses',
      ).sanitized();
      expect(config.completionUrl, 'https://api.openai.com/v1/responses');
    });

    test('openai_chat：补 chat/completions', () {
      final config = const AiConfig(
        protocol: 'openai_chat',
        endpoint: 'https://api.deepseek.com/v1',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://api.deepseek.com/v1/chat/completions',
      );
    });

    test('anthropic_messages：补 messages', () {
      final config = const AiConfig(
        protocol: 'anthropic_messages',
        endpoint: 'https://api.anthropic.com/v1',
      ).sanitized();
      expect(config.completionUrl, 'https://api.anthropic.com/v1/messages');
    });

    test('gemini_native：补 /v1beta/models/<model>:generateContent', () {
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: 'https://generativelanguage.googleapis.com',
        model: 'gemini-2.0-flash',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://generativelanguage.googleapis.com/v1beta/'
        'models/gemini-2.0-flash:generateContent',
      );
    });

    test('gemini_native：端点已含 :generateContent 原样', () {
      const url =
          'https://x/v1beta/models/gemini-2.0-flash:generateContent';
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: url,
      ).sanitized();
      expect(config.completionUrl, url);
    });

    test('gemini_native：端点以 /models 结尾只补模型段', () {
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: 'https://x/v1beta/models',
        model: 'gemini-2.0-flash',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://x/v1beta/models/gemini-2.0-flash:generateContent',
      );
    });

    test('model 带 models/ 前缀时不重复', () {
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: 'https://x',
        model: 'models/gemini-2.0-flash',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://x/v1beta/models/gemini-2.0-flash:generateContent',
      );
    });
  });

  group('脱敏', () {
    test('redactedApiKey 不含完整 key', () {
      final config = const AiConfig(apiKey: 'sk-1234567890abcdef').sanitized();
      expect(config.redactedApiKey, isNot(contains('1234567890abcdef')));
    });

    test('toJson 保留原 key（落盘需要），但 redactedApiKey 用于展示', () {
      final config = const AiConfig(apiKey: 'sk-abc').sanitized();
      expect(config.toJson()['apiKey'], 'sk-abc');
      expect(config.redactedApiKey, isNot('sk-abc'));
    });
  });

  group('fromJson 往返', () {
    test('缺字段用默认', () {
      final config = AiConfig.fromJson(const {});
      expect(config.protocol, AiProtocol.defaultProtocol);
      expect(config.enabled, isFalse);
    });

    test('完整往返', () {
      const original = AiConfig(
        enabled: true,
        protocol: 'anthropic_messages',
        endpoint: 'https://api.anthropic.com/v1',
        apiKey: 'sk-x',
        model: 'claude-3-5-sonnet',
        customUserAgent: 'MyUA/1.0',
      );
      final restored = AiConfig.fromJson(original.toJson());
      expect(restored.enabled, original.enabled);
      expect(restored.protocol, original.protocol);
      expect(restored.endpoint, original.endpoint);
      expect(restored.apiKey, original.apiKey);
      expect(restored.model, original.model);
      expect(restored.customUserAgent, original.customUserAgent);
    });

    test('非法类型不抛异常', () {
      final config = AiConfig.fromJson(const {
        'enabled': 'yes',
        'protocol': 42,
        'apiKey': ['x'],
      });
      expect(config.enabled, isFalse);
      expect(config.protocol, AiProtocol.defaultProtocol);
      expect(config.apiKey, '');
    });
  });
}
