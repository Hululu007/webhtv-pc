/// AI 辅助服务（`docs/phase9/README.md` P1-10）。
///
/// 只做「构造提示词 → 发一次补全 → 解析受限结构」。所有结果都返回给调用方，
/// 由 UI 展示并让用户确认；本层不写任何状态（不自动改标题/分组/播放地址）。
library;

import '../core/ai_assist.dart';
import '../core/ai_config.dart';
import 'ai_completion_client.dart';
import 'log_service.dart';

class AiAssistService {
  AiAssistService({
    AiConfig? config,
    AiCompletionClient? client,
    this.log,
    this.timeout = AiCompletionClient.defaultTimeout,
  }) : _config = (config ?? const AiConfig()).sanitized(),
       _client = client ?? AiCompletionClient();

  final AiConfig _config;
  final AiCompletionClient _client;
  final LogService? log;
  final Duration timeout;

  bool get isReady => _config.isReady;

  /// 执行一次辅助任务；配置未就绪或输出不合规时返回失败（不抛异常）。
  Future<AiAssistResult> run({
    required AiAssistTask task,
    required String input,
    Map<String, String> extra = const {},
  }) async {
    if (!isReady) {
      return const AiAssistResult.failure('未配置 AI：请先在设置页填写端点/密钥/模型');
    }
    if (input.trim().isEmpty) {
      return const AiAssistResult.failure('输入为空');
    }
    final prompt = buildAiAssistPrompt(task: task, input: input, extra: extra);
    final completion = await _client.complete(
      config: _config,
      prompt: prompt,
      timeout: timeout,
    );
    if (!completion.ok) {
      log?.warning(
        'AI 辅助失败 task=${task.id} status=${completion.statusCode} '
        '${completion.message}',
        scope: 'ai',
      );
      return AiAssistResult.failure(
        completion.message.isEmpty ? 'AI 请求失败' : completion.message,
      );
    }
    final parsed = parseAiAssistOutput(completion.text, task: task);
    if (!parsed.ok) {
      log?.warning(
        'AI 辅助输出不可用 task=${task.id} error=${parsed.error}',
        scope: 'ai',
      );
    } else {
      log?.info('AI 辅助完成 task=${task.id}', scope: 'ai');
    }
    return parsed;
  }
}
