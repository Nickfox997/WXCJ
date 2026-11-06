WeChatAIChatTweak v7 注入包（悬浮球 · 独立窗口版）
==================================================
libmarsbridge.dylib  263.9 KB  arm64 Mach-O  iOS 14.0+
SHA256 : B1746B2139037ABB1652AD1228FA0BA379AAB6AB2E21D5D80CAE1A1A5B38B9EB

为什么改回悬浮球
---------------
设置页/我 页面插入方案两次未成功：能挂到类上，但找不到插入点。
继续盲试成本太高，先用回确定能显示的悬浮球兜住可用性。

这次和旧版的关键差别
-------------------
旧版：把 UIButton 加到 keyWindow 上
      -> 被微信自己的视图层盖住，hitTest 拿不到触摸，点击失效

新版：自建独立 UIWindow
      windowLevel = UIWindowLevelAlert + 1
      frame 只有 52x52（就球那么大），不覆盖全屏
      -> 不会被微信界面盖住
      -> 也不会拦截球以外的任何触摸

其他
----
- 拖动改的是 window.frame，不再用手势改 subview.center
- 独立窗口不需要定时补挂，不会被页面切换冲掉
- 诊断弹窗已关闭，不会再弹
- 设置页 hook 代码保留（不弹窗、无副作用），哪天能插上算白赚

如果球在但点击还是没反应
------------------------
说明微信有更高层级的窗口压着。告诉我，我把 windowLevel 再抬到
UIWindowLevelAlert + 1000，或者换 UIWindowLevelStatusBar + 1。
