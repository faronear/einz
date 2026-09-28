import 'package:flutter/material.dart';

/// 弹层里的卡片网格容器：**卡片排不下时在这一块内部滚动**（老板 2026-09-28 实测 mac
/// 桌面端：「切换我的秘境」卡片排到两行以上，把整个窗口调矮，弹层底部就出现黄黑斜条纹
/// 和 "Bottom overflowed by N pixels"，内容是死的、被盖住的卡片看不见也够不到）。
///
/// 为什么只让卡片区滚：**标题和底部的添加/新建按钮是随时要用的入口**，滚出去就找不回来
/// 了——它们固定在两端，中间那块才是可变的。
///
/// 高度从哪来：`Flexible(loose)` 直接吃**弹层那个 Column 分给它的剩余空间**——标题、各种
/// 间距、底部按钮都是 Column 里排在它前后的非弹性子项，Column 在分配弹性空间之前已经把
/// 它们挨个量过一遍（`RenderFlex._computeSizes` 的第一趟），所以这里拿到的就是"除掉它们
/// 之后还剩多少"。这样不用猜任何数值：窗口（或者框架给弹层的高度上限，见
/// `bottom_sheet.dart` 的 9/16）变化时自动跟着变。**因此它必须是弹层 Column 的直接子项。**
///
/// 为什么是 `ListView(shrinkWrap: true)` 而不是 `SingleChildScrollView`：前者"有就到
/// 内容、没有再到上限"，卡片本来就排得下时它跟直接放一个 Wrap 一模一样（不滚动、弹层
/// 依旧贴着内容）；后者会把高度吃满上限，只有一两张卡时下面空一大截。
class ScrollableCardArea extends StatelessWidget {
  const ScrollableCardArea({super.key, required this.child});

  /// 卡片网格本身（`LayoutBuilder + Wrap`）：宽度照旧由父级传下去，这里只约束高度。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      fit: FlexFit.loose,
      child: Scrollbar(
        child: ListView(shrinkWrap: true, children: [child]),
      ),
    );
  }
}
