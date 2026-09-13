import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// emoji 分类：tab 图标直接用该分类的代表 emoji（不引图片资源、不为分类名新增
/// l10n 文案）。
class EmojiGroup {
  const EmojiGroup(this.tabIcon, this.emojis);

  final String tabIcon;
  final List<String> emojis;
}

/// 内置精选 emoji（零第三方依赖：不联网拉包、不带外部 UI 风格，表情数量控制在
/// 常用范围内，按分类分组）。
const List<EmojiGroup> kEmojiGroups = [
  EmojiGroup('😀', [
    '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊',
    '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙', '🥲', '😋', '😛', '😜',
    '🤪', '😝', '🤗', '🤭', '🤫', '🤔', '🤐', '🤨', '😐', '😑', '😶', '😏',
    '😒', '🙄', '😬', '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕',
    '🤢', '🤮', '🤧', '🥵', '🥶', '😵', '🤯', '🤠', '🥳', '🥸', '😎', '🤓',
    '🧐', '😕', '😟', '🙁', '😮', '😯', '😲', '😳', '🥺', '😦', '😧', '😨',
    '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫', '🥱',
    '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '💩', '🤡', '👻', '👽', '👾',
    '🤖', '🎃', '😺', '😹', '😻', '😼', '😽', '🙀', '😿', '😾',
  ]),
  EmojiGroup('👍', [
    '👋', '🤚', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞', '🤟', '🤘', '🤙',
    '👈', '👉', '👆', '👇', '☝️', '👍', '👎', '✊', '👊', '🤛', '🤜', '👏',
    '🙌', '👐', '🤲', '🤝', '🙏', '✍️', '💅', '🤳', '💪', '🦾', '🦵', '🦶',
    '👂', '🦻', '👃', '🧠', '👀', '👁️', '👅', '👄', '👶', '🧑', '👨‍👩‍👧',
    '👩‍💻', '🧑‍🍳', '👮', '🕵️', '💂', '🧙', '🧛', '🧟', '🧞', '🧜', '🧚',
    '👸', '🤴', '🥷', '🦸', '🦹', '🙇', '💁', '🙅', '🙆', '🤦', '🤷', '💇',
    '💆', '🚶', '🏃', '🧍', '🧎', '🧘',
  ]),
  EmojiGroup('🐻', [
    '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮',
    '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🦇', '🐺',
    '🐗', '🐴', '🦄', '🐝', '🐛', '🦋', '🐌', '🐞', '🐜', '🕷️', '🦂', '🐢',
    '🐍', '🦎', '🐙', '🦑', '🦐', '🦀', '🐡', '🐠', '🐟', '🐬', '🐳', '🐋',
    '🦈', '🐊', '🐘', '🦒', '🦓', '🐂', '🐄', '🐑', '🐐', '🦌', '🐎', '🐇',
    '🐈', '🐕', '🦮', '🐓', '🦃', '🦚', '🦜', '🌵', '🎄', '🌲', '🌳', '🌴',
    '🌱', '🌿', '☘️', '🍀', '🍁', '🍂', '🍃', '🍄', '🌷', '🌹', '🌺', '🌸',
    '🌼', '🌻', '🌞', '🌝', '🌚', '⭐', '🌟', '✨', '⚡', '🔥', '🌈', '☀️',
    '⛅', '☁️', '🌧️', '⛈️', '❄️', '⛄', '💧', '🌊',
  ]),
  EmojiGroup('🍎', [
    '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈', '🍒',
    '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌽',
    '🥕', '🧄', '🧅', '🥔', '🍠', '🥐', '🥯', '🍞', '🥖', '🧀', '🥚', '🍳',
    '🧇', '🥞', '🥓', '🍔', '🍟', '🍕', '🌭', '🥪', '🌮', '🌯', '🥗', '🍜',
    '🍝', '🍣', '🍱', '🍚', '🍙', '🍢', '🍡', '🍧', '🍨', '🍦', '🥧', '🧁',
    '🍰', '🎂', '🍫', '🍬', '🍭', '🍩', '🍪', '☕', '🍵', '🧋', '🥤', '🍺',
    '🍻', '🥂', '🍷', '🥃', '🍸', '🍹', '🧉', '🍾', '🧊',
  ]),
  EmojiGroup('⚽', [
    '⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🎱', '🏓', '🏸', '🏒',
    '🥍', '🏑', '🥊', '🥋', '🎽', '🛹', '🛼', '🥌', '🎯', '🎣', '🤿', '🎮',
    '🕹️', '🎲', '🧩', '🎰', '🎳', '🎨', '🎭', '🎤', '🎧', '🎼', '🎹', '🥁',
    '🎸', '🎺', '🎻', '🎬', '🏆', '🥇', '🥈', '🥉', '🏅', '🎖️', '🎗️', '🎫',
    '🎟️',
  ]),
  EmojiGroup('✈️', [
    '🚗', '🚕', '🚙', '🚌', '🚎', '🏎️', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚',
    '🚛', '🚜', '🛴', '🚲', '🛵', '🏍️', '🚨', '🚔', '🚂', '🚆', '🚇', '🚊',
    '🚉', '✈️', '🛫', '🛬', '🚀', '🛸', '🚁', '⛵', '🚤', '🛳️', '⛴️', '🗺️',
    '🧭', '🏠', '🏡', '🏢', '🏥', '🏦', '🏨', '⛺', '🌆', '🌇', '🌃', '🌉',
    '🎡', '🎢', '🎠', '🗼', '🗽', '⛲', '🏖️', '🏝️', '🏔️', '🌋', '🏕️',
  ]),
  EmojiGroup('💡', [
    '💡', '🔦', '🕯️', '🪔', '🧯', '🛢️', '💸', '💵', '💴', '💶', '💷', '💰',
    '💳', '🪙', '💎', '⚖️', '🔧', '🔨', '🛠️', '⚙️', '🔩', '🪛', '🧰', '🪜',
    '🧲', '💊', '🩹', '🗿', '🛒', '📦', '📫', '📧', '✏️', '🖊️', '📝', '📁',
    '📂', '📅', '📆', '📇', '📈', '📉', '📊', '📋', '📌', '📍', '📎', '🖇️',
    '📏', '📐', '✂️', '🗑️', '🔒', '🔑', '🔍', '🔎', '🔬', '🔭', '📱', '💻',
    '⌨️', '🖥️', '🖨️', '💾', '💿', '📷', '📹', '🎥', '📞', '☎️', '📺', '📻',
    '⏰', '⏳', '⌛', '🔋', '🔌',
  ]),
  EmojiGroup('❤️', [
    '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕',
    '💞', '💓', '💗', '💖', '💘', '💝', '💟', '☮️', '✝️', '☪️', '🕉️', '☸️',
    '✡️', '🔯', '🕎', '☯️', '☦️', '⛎', '♈', '♉', '♊', '♋', '♌', '♍',
    '♎', '♏', '♐', '♑', '♒', '♓', '🆔', '⚛️', '🉑', '☢️', '☣️', '📴',
    '📳', '🈶', '🈚', '🈸', '🈺', '✴️', '🆚', '💮', '🉐', '㊙️', '㊗️', '🈴',
    '🈵', '🈹', '🈲', '🅰️', '🅱️', '🆎', '🆑', '🅾️', '🆘', '❌', '⭕', '🛑',
    '⛔', '📛', '🚫', '💯', '💢', '♨️', '🚷', '🚯', '🚳', '🚱', '🔞', '✅',
    '☑️', '✔️', '❗', '❓', '‼️', '⁉️', '⚠️', '🚸', '🔅', '🔆', '〽️', '⚜️',
    '🔱', '✳️', '❇️',
  ]),
];

/// 表情面板：输入栏下方的常驻网格（打开时键盘收起，二者互斥——同微信）。
///
/// 只负责「选了哪个 emoji」，插入输入框由调用方（聊天页）完成——面板不持有
/// TextEditingController，便于独立复用与测试。
class EmojiPanel extends StatefulWidget {
  const EmojiPanel({
    super.key,
    required this.onEmojiSelected,
    this.onBackspace,
    this.onDismiss,
  });

  /// 点选 emoji：回调字符，由调用方插到光标处。
  final ValueChanged<String> onEmojiSelected;

  /// 退格：面板常驻时键盘收起，输入框没有删除键，故面板自带一个。
  final VoidCallback? onBackspace;

  /// 收起面板回到键盘（点输入框等价，此按钮只是显性入口）。
  final VoidCallback? onDismiss;

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  int _activeGroup = 0;
  final _gridController = ScrollController();

  @override
  void dispose() {
    _gridController.dispose();
    super.dispose();
  }

  void _selectGroup(int index) {
    if (index == _activeGroup) return;
    setState(() => _activeGroup = index);
    // 切分类回到顶部（保留在上一分类的滚动位置会显得错乱）
    if (_gridController.hasClients) {
      _gridController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = kEmojiGroups[_activeGroup];
    return SizedBox(
      // 固定高度：面板挂在输入栏 Column（mainAxisSize.min，主轴向无界）里，
      // 网格必须拿到确定高度才能用 Expanded
      height: 232,
      child: Column(
        children: [
          Expanded(
            child: GridView.builder(
              controller: _gridController,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: group.emojis.length,
              itemBuilder: (context, index) => InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => widget.onEmojiSelected(group.emojis[index]),
                child: Center(
                  child: Text(
                    group.emojis[index],
                    // 关掉系统字体缩放跟随：emoji 只按面板格子大小排版
                    textScaler: TextScaler.noScaling,
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
              ),
            ),
          ),
          _buildTabBar(theme),
        ],
      ),
    );
  }

  /// 底部分类条：分类 tab（可横向滚动，窄屏不挤）+ 右侧退格/回键盘。
  Widget _buildTabBar(ThemeData theme) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: kEmojiGroups.length,
              itemBuilder: (context, index) => _EmojiTab(
                icon: kEmojiGroups[index].tabIcon,
                selected: index == _activeGroup,
                onTap: () => _selectGroup(index),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.backspace_outlined, size: 20),
            tooltip: l10n.delete,
            onPressed: widget.onBackspace,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_alt_outlined, size: 20),
            tooltip: l10n.chatPageEmojiKeyboard,
            onPressed: widget.onDismiss,
          ),
        ],
      ),
    );
  }
}

class _EmojiTab extends StatelessWidget {
  const _EmojiTab({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 44,
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
        ),
        child: Center(
          child: Text(
            icon,
            textScaler: TextScaler.noScaling,
            style: const TextStyle(fontSize: 22),
          ),
        ),
      ),
    );
  }
}
