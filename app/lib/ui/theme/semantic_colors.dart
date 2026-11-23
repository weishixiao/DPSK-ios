// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import 'accent.dart';
import 'palette.dart';

/// DSH 工具调用的视觉类别。名字 → 类别的映射在 `common/tool_glyph.dart`。
enum ToolTone {
  /// bash / pwsh / job_*:终端。
  terminal,

  /// read / read_image / present:读取。
  read,

  /// write / edit / str_replace_editor:改动文件。
  edit,

  /// grep / glob:搜索。
  search,

  /// web_fetch / web_search:联网。
  web,

  /// subagent / workflow / skill / send_message:另一个智能体在干活。
  agent,

  /// todo_write / *_goal / ask_user_question:计划与协作。
  plan,

  /// MCP 工具、插件工具、未知工具。
  neutral,
}

/// 语义色扩展:与强调色**无关**的固定色。
///
/// 只有中性的几格(文字层级、代码井)随配色换色调,见 [forAccent]。
///
/// - 一张 `bash` 行在任何配色下都必须长得一样:色相本身就是语义。
/// - 所有 mono / 代码 / diff / ANSI 必须铺在 [codeWellBg] 上,**不能**直接
///   放在玻璃或页面渐变上 —— 只有固定的井底才能保证这些固定前景色的对比度。
/// - 文字类前景对其底色 ≥ 4.5(容器上的 on-色 ≥ 7)。
class DshColors extends ThemeExtension<DshColors> {
  const DshColors({
    required this.textTertiary,
    required this.textDisabled,
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.danger,
    required this.onDanger,
    required this.dangerContainer,
    required this.onDangerContainer,
    required this.info,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.diffAddBg,
    required this.diffAddFg,
    required this.diffDelBg,
    required this.diffDelFg,
    required this.diffHunkFg,
    required this.codeWellBg,
    required this.codeWellHeader,
    required this.codeWellFg,
    required this.codeWellBorder,
    required this.lineNumberFg,
    required this.ansi,
    required this.identity,
    required this.onIdentity,
    required this.toolContainers,
    required this.onToolContainers,
  });

  /// 三级文字(时间戳、摘要、占位符)。仍 ≥ 4.5,可承载信息。
  final Color textTertiary;

  /// 禁用 / 装饰。不得承载必要信息。
  final Color textDisabled;

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;

  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  /// 与 `colorScheme.error` 同值;放在这里是为了状态映射写起来对称。
  final Color danger;
  final Color onDanger;
  final Color dangerContainer;
  final Color onDangerContainer;

  final Color info;
  final Color infoContainer;
  final Color onInfoContainer;

  final Color diffAddBg;
  final Color diffAddFg;
  final Color diffDelBg;
  final Color diffDelFg;
  final Color diffHunkFg;

  /// 代码井:比页面深一档的冷灰(浅色)/ 比页面更深的墨(深色),像嵌进去的。
  final Color codeWellBg;

  /// 代码井标题条(语言名 + 复制键)。
  final Color codeWellHeader;
  final Color codeWellFg;
  final Color codeWellBorder;
  final Color lineNumberFg;

  /// SGR 30–37 + 90–97(标准 8 色 + 亮色 8 色),对 [codeWellBg] 全部 ≥ 4.5。
  final List<Color> ansi;

  /// 身份色(会话头像、设置分组图标)。8 组容器 / on-容器,固定不随 accent 转。
  final List<Color> identity;
  final List<Color> onIdentity;

  /// 工具类别色,按 [ToolTone.index] 取。
  final List<Color> toolContainers;
  final List<Color> onToolContainers;

  static DshColors of(BuildContext context) => Theme.of(context).extension<DshColors>()!;

  /// [accent] 配色下的一套:语义色、ANSI、身份色、工具色原样不动(色相本身
  /// 就是语义);中性的那几格 —— 三级 / 禁用文字、代码井、行号、diff 标题 ——
  /// 换成这套配色的中性色。雾蓝直接返回 [light] / [dark]。
  static DshColors forAccent(Brightness brightness, AppAccent accent) {
    final dark = brightness == Brightness.dark;
    final base = dark ? DshColors.dark : DshColors.light;
    final n = NeutralTones.forAccent(accent);
    if (identical(n, NeutralTones.defaults)) return base;
    return dark
        ? base.copyWith(
            textTertiary: n.paperFaint,
            textDisabled: n.paperGhost,
            diffHunkFg: n.paperMuted,
            codeWellBg: n.codeWellDark,
            codeWellHeader: n.codeWellHeaderDark,
            codeWellFg: n.paper,
            codeWellBorder: n.codeWellBorderDark,
            lineNumberFg: n.lineNumberDark,
          )
        : base.copyWith(
            textTertiary: n.inkFaint,
            textDisabled: n.inkGhost,
            diffHunkFg: n.inkMuted,
            codeWellBg: n.codeWell,
            codeWellHeader: n.codeWellHeader,
            codeWellFg: n.ink,
            codeWellBorder: n.codeWellBorder,
            lineNumberFg: n.lineNumber,
          );
  }

  /// 工具类别的 (容器, on-容器)。
  (Color, Color) tool(ToolTone tone) => (toolContainers[tone.index], onToolContainers[tone.index]);

  /// 由稳定字符串(会话 id、工作目录)映射到 identity 下标。
  ///
  /// 不用 `String.hashCode`:Dart 不保证它跨进程稳定,重启后颜色会整体重排。
  /// 这里用固定的 FNV-1a。
  static int identityIndex(String key, [int slots = 8]) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash % slots;
  }

  static const light = DshColors(
    textTertiary: Color(0xFF6B6B6B),
    textDisabled: Color(0xFFA6A6A6),
    // 状态色一律低饱和:鲜绿 / 鲜红一出现,界面立刻变成"运维面板"。
    success: Color(0xFF6B6B6B),
    onSuccess: Color(0xFFFAFAFA),
    successContainer: Color(0xFFE8E8E8),
    onSuccessContainer: Color(0xFF2E2E2E),
    warning: Color(0xFF6B6B6B),
    onWarning: Color(0xFFFAFAFA),
    warningContainer: Color(0xFFE8E8E8),
    onWarningContainer: Color(0xFF2E2E2E),
    danger: Color(0xFF4D4D4D),
    onDanger: Color(0xFFFAFAFA),
    dangerContainer: Color(0xFFE8E8E8),
    onDangerContainer: Color(0xFF2E2E2E),
    info: Color(0xFF6B6B6B),
    infoContainer: Color(0xFFE8E8E8),
    onInfoContainer: Color(0xFF2E2E2E),
    diffAddBg: Color(0xFFF2F2F2),
    diffAddFg: Color(0xFF4D4D4D),
    diffDelBg: Color(0xFFE8E8E8),
    diffDelFg: Color(0xFF4D4D4D),
    diffHunkFg: Color(0xFF4D4D4D),
    codeWellBg: Color(0xFFF2F2F2),
    codeWellHeader: Color(0xFFE8E8E8),
    codeWellFg: Color(0xFF1A1A1A),
    codeWellBorder: Color(0xFFD9D9D9),
    lineNumberFg: Color(0xFF808080),
    // 浅色井底上的 ANSI:"白"必须映射成深灰,否则在浅底上看不见。
    ansi: [
      Color(0xFF1A1A1A),
      Color(0xFF4D4D4D),
      Color(0xFF4D4D4D),
      Color(0xFF4D4D4D),
      Color(0xFF4D4D4D),
      Color(0xFF4D4D4D),
      Color(0xFF4D4D4D),
      Color(0xFF4D4D4D),
      Color(0xFF6B6B6B),
      Color(0xFF6B6B6B),
      Color(0xFF6B6B6B),
      Color(0xFF6B6B6B),
      Color(0xFF6B6B6B),
      Color(0xFF6B6B6B),
      Color(0xFF6B6B6B),
      Color(0xFF2E2E2E),
    ],
    identity: [
      Color(0xFFE8E8E8), // 晴蓝
      Color(0xFFE8E8E8), // 薰衣
      Color(0xFFE8E8E8), // 藕荷
      Color(0xFFE8E8E8), // 珊瑚
      Color(0xFFE8E8E8), // 麦黄
      Color(0xFFE8E8E8), // 苔绿
      Color(0xFFE8E8E8), // 薄荷
      Color(0xFFE8E8E8), // 湖青
    ],
    onIdentity: [
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
    ],
    // 顺序 = ToolTone:terminal, read, edit, search, web, agent, plan, neutral
    toolContainers: [
      Color(0xFFE8E8E8),
      Color(0xFFE8E8E8),
      Color(0xFFE8E8E8),
      Color(0xFFE8E8E8),
      Color(0xFFE8E8E8),
      Color(0xFFE8E8E8),
      Color(0xFFE8E8E8),
      Color(0xFFE8E8E8),
    ],
    onToolContainers: [
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
    ],
  );

  static const dark = DshColors(
    textTertiary: Color(0xFFA6A6A6),
    textDisabled: Color(0xFF6B6B6B),
    success: Color(0xFFC4C4C4),
    onSuccess: Color(0xFF1A1A1A),
    successContainer: Color(0xFF2E2E2E),
    onSuccessContainer: Color(0xFFD9D9D9),
    warning: Color(0xFFC4C4C4),
    onWarning: Color(0xFF1A1A1A),
    warningContainer: Color(0xFF2E2E2E),
    onWarningContainer: Color(0xFFE8E8E8),
    danger: Color(0xFFA6A6A6),
    onDanger: Color(0xFF1A1A1A),
    dangerContainer: Color(0xFF2E2E2E),
    onDangerContainer: Color(0xFFD9D9D9),
    info: Color(0xFFC4C4C4),
    infoContainer: Color(0xFF2E2E2E),
    onInfoContainer: Color(0xFFE8E8E8),
    diffAddBg: Color(0xFF2E2E2E),
    diffAddFg: Color(0xFFC4C4C4),
    diffDelBg: Color(0xFF2E2E2E),
    diffDelFg: Color(0xFFC4C4C4),
    diffHunkFg: Color(0xFFC4C4C4),
    // 夜里的井底比页面更深:代码像嵌进纸里,而不是浮在上面。
    codeWellBg: Color(0xFF1A1A1A),
    codeWellHeader: Color(0xFF1A1A1A),
    codeWellFg: Color(0xFFE8E8E8),
    codeWellBorder: Color(0xFF2E2E2E),
    lineNumberFg: Color(0xFF6B6B6B),
    ansi: [
      Color(0xFF808080),
      Color(0xFFA6A6A6),
      Color(0xFFA6A6A6),
      Color(0xFFA6A6A6),
      Color(0xFFA6A6A6),
      Color(0xFFA6A6A6),
      Color(0xFFA6A6A6),
      Color(0xFFD9D9D9),
      Color(0xFFA6A6A6),
      Color(0xFFC4C4C4),
      Color(0xFFC4C4C4),
      Color(0xFFC4C4C4),
      Color(0xFFC4C4C4),
      Color(0xFFC4C4C4),
      Color(0xFFC4C4C4),
      Color(0xFFF2F2F2),
    ],
    identity: [
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
    ],
    onIdentity: [
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
    ],
    toolContainers: [
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
      Color(0xFF2E2E2E),
    ],
    onToolContainers: [
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
      Color(0xFFD9D9D9),
    ],
  );

  @override
  DshColors copyWith({
    Color? textTertiary,
    Color? textDisabled,
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? danger,
    Color? onDanger,
    Color? dangerContainer,
    Color? onDangerContainer,
    Color? info,
    Color? infoContainer,
    Color? onInfoContainer,
    Color? diffAddBg,
    Color? diffAddFg,
    Color? diffDelBg,
    Color? diffDelFg,
    Color? diffHunkFg,
    Color? codeWellBg,
    Color? codeWellHeader,
    Color? codeWellFg,
    Color? codeWellBorder,
    Color? lineNumberFg,
    List<Color>? ansi,
    List<Color>? identity,
    List<Color>? onIdentity,
    List<Color>? toolContainers,
    List<Color>? onToolContainers,
  }) {
    return DshColors(
      textTertiary: textTertiary ?? this.textTertiary,
      textDisabled: textDisabled ?? this.textDisabled,
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      dangerContainer: dangerContainer ?? this.dangerContainer,
      onDangerContainer: onDangerContainer ?? this.onDangerContainer,
      info: info ?? this.info,
      infoContainer: infoContainer ?? this.infoContainer,
      onInfoContainer: onInfoContainer ?? this.onInfoContainer,
      diffAddBg: diffAddBg ?? this.diffAddBg,
      diffAddFg: diffAddFg ?? this.diffAddFg,
      diffDelBg: diffDelBg ?? this.diffDelBg,
      diffDelFg: diffDelFg ?? this.diffDelFg,
      diffHunkFg: diffHunkFg ?? this.diffHunkFg,
      codeWellBg: codeWellBg ?? this.codeWellBg,
      codeWellHeader: codeWellHeader ?? this.codeWellHeader,
      codeWellFg: codeWellFg ?? this.codeWellFg,
      codeWellBorder: codeWellBorder ?? this.codeWellBorder,
      lineNumberFg: lineNumberFg ?? this.lineNumberFg,
      ansi: ansi ?? this.ansi,
      identity: identity ?? this.identity,
      onIdentity: onIdentity ?? this.onIdentity,
      toolContainers: toolContainers ?? this.toolContainers,
      onToolContainers: onToolContainers ?? this.onToolContainers,
    );
  }

  @override
  DshColors lerp(DshColors? other, double t) {
    if (other is! DshColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    List<Color> mixAll(List<Color> a, List<Color> b) => [for (var i = 0; i < a.length; i++) mix(a[i], b[i])];
    return DshColors(
      textTertiary: mix(textTertiary, other.textTertiary),
      textDisabled: mix(textDisabled, other.textDisabled),
      success: mix(success, other.success),
      onSuccess: mix(onSuccess, other.onSuccess),
      successContainer: mix(successContainer, other.successContainer),
      onSuccessContainer: mix(onSuccessContainer, other.onSuccessContainer),
      warning: mix(warning, other.warning),
      onWarning: mix(onWarning, other.onWarning),
      warningContainer: mix(warningContainer, other.warningContainer),
      onWarningContainer: mix(onWarningContainer, other.onWarningContainer),
      danger: mix(danger, other.danger),
      onDanger: mix(onDanger, other.onDanger),
      dangerContainer: mix(dangerContainer, other.dangerContainer),
      onDangerContainer: mix(onDangerContainer, other.onDangerContainer),
      info: mix(info, other.info),
      infoContainer: mix(infoContainer, other.infoContainer),
      onInfoContainer: mix(onInfoContainer, other.onInfoContainer),
      diffAddBg: mix(diffAddBg, other.diffAddBg),
      diffAddFg: mix(diffAddFg, other.diffAddFg),
      diffDelBg: mix(diffDelBg, other.diffDelBg),
      diffDelFg: mix(diffDelFg, other.diffDelFg),
      diffHunkFg: mix(diffHunkFg, other.diffHunkFg),
      codeWellBg: mix(codeWellBg, other.codeWellBg),
      codeWellHeader: mix(codeWellHeader, other.codeWellHeader),
      codeWellFg: mix(codeWellFg, other.codeWellFg),
      codeWellBorder: mix(codeWellBorder, other.codeWellBorder),
      lineNumberFg: mix(lineNumberFg, other.lineNumberFg),
      ansi: mixAll(ansi, other.ansi),
      identity: mixAll(identity, other.identity),
      onIdentity: mixAll(onIdentity, other.onIdentity),
      toolContainers: mixAll(toolContainers, other.toolContainers),
      onToolContainers: mixAll(onToolContainers, other.onToolContainers),
    );
  }
}
