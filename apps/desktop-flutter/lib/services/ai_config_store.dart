/// AI 配置持久化（`<configDir>/settings.json` 的 `ai` 段）。
///
/// 为什么独立成段（`docs/phase6/design/04` §4）：`settings.json` 已有
/// `tmdb`（凭据）、`sync`（同步白名单）、`ui`（界面偏好）三段，各自有独立
/// store。AI 配置含凭据，与 `ui` 的语义与生命周期都不同，混进去会让任何
/// 一方保存时覆盖另一方的键。沿用同样的「读改写、只替换自己那一段」模式。
///
/// 与 `UiPreferencesStore` 相同的**串行化写盘队列**：`_persist` 是
/// 「写 tmp → 删旧 → 改名」三步，并发时两个调用会在同一个 `.tmp` 上互相
/// 踩（Windows 上 delete/rename 原子性比 POSIX 差），最终可能把整个
/// `settings.json` 弄丢。
library;

import 'dart:convert';
import 'dart:io';

import '../core/ai_config.dart';
import 'log_service.dart';

class AiConfigStore {
  AiConfigStore({required this.path, LogService? log}) : _log = log;

  /// `settings.json` 的绝对路径（`AppPaths.settingsPath`）。
  final String path;

  // ignore_for_file: prefer_initializing_formals
  final LogService? _log;

  AiConfig _config = const AiConfig();
  bool _loaded = false;

  /// 当前配置（始终是归一化后的）。
  AiConfig get config => _config;

  /// 是否已成功读取过磁盘内容。
  bool get loaded => _loaded;

  /// 从磁盘读取。文件不存在或解析失败时保持默认值并记日志（不阻塞启动）。
  Future<void> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        _loaded = true;
        return;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _loaded = true;
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _config = AiConfig.fromJson(decoded['ai']);
      }
      _loaded = true;
    } catch (error) {
      _log?.warning('读取 AI 配置失败，使用默认值：$error', scope: 'ai');
      _config = const AiConfig();
      _loaded = true;
    }
  }

  /// 保存配置。写盘失败**不影响**当前会话（内存里已生效），只记日志。
  Future<bool> save(AiConfig next) {
    _config = next.sanitized();
    return _persist();
  }

  /// 写盘队列尾：串行化所有 `_persist` 调用。
  Future<void> _persistQueue = Future<void>.value();

  Future<bool> _persist() {
    final result = _persistQueue.then((_) => _doPersist());
    // 队列推进不能被单次失败阻塞：吞掉错误后继续接受下一次写盘。
    _persistQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _doPersist() async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final existing = <String, Object?>{};
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            existing.addAll(decoded.cast<String, Object?>());
          }
        } catch (_) {
          // 旧文件损坏 → 直接覆盖，不把损坏内容带进新文件。
        }
      }
      existing['ai'] = _config.toJson();

      final temporary = File('$path.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(existing),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(path);
      return true;
    } catch (error) {
      _log?.error('保存 AI 配置失败：$error', scope: 'ai');
      return false;
    }
  }
}
