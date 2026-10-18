import 'package:flutter/material.dart';

/// 带标签的勾选框（老板 2026-10-15）：一行 = 勾框 + 标签，**整体居中**（与
/// 全宽提交按钮成一系，视觉上绑成一组），整行可点（不止小勾框——触摸目标
/// 才是整行）。
///
/// 首个用途：「墓碑消息」弹层里的「应用于本机所有秘境」——设置项的**作用域**
/// 开关：勾选 → 设置写入全局键，对本机所有空间生效（各空间自己的 per-space
/// 覆盖被清除，回退全局值）；不勾 → 只写当前空间（per-space 键，默认）。
/// 做成通用组件：效果好的话每个配置项弹层都能挂一个。
///
/// 纯受控组件：状态由调用方（弹层的 State）持有，本组件只负责渲染与回调。
class LabeledCheckbox extends StatelessWidget {
  const LabeledCheckbox({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  /// 勾选框标签（如「应用于本机所有秘境」）。
  final String label;

  /// 当前勾选态。
  final bool value;

  /// 勾选态变化（整行点击 / 点勾框都走这里）。
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: () => onChanged(!value),
      child: Padding(
        // 左右 24 = 与弹层标题/备注的左右留白一致；纵向 4 别挤
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
        child: Row(
          // 整体居中：勾框+标签作为一组居中排布，与下方全宽提交按钮成一系
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              // 默认 24px 的勾框在这一行里偏大，收一档与 13px 标签相称
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 8),
            // Flexible：标签再长也只压缩到行宽内（不溢出）；短标签时随勾框
            // 一起居中
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
