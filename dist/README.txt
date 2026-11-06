WeChatAIChatTweak v9 注入包（回退到 keyWindow 方案）
====================================================
libmarsbridge.dylib  263.4 KB  arm64 Mach-O  iOS 14.0+
SHA256 : 71621874AE8EB0D78278D5D3EA6B2F2AC87A6513650126F21D9383C8204464F8

v7/v8 为什么一直闪退
-------------------
v7 用独立 UIWindow 承载悬浮球，在微信这种多窗口管理的 App 里不稳定。
v8 想靠「推迟到 App 激活后创建」修掉，但同时又犯了一个更严重的错误：
把通知观察者注册提前到了静默判断之前。

结果是：即使 WCAIShouldRunSilently() 判定上次崩溃、进入静默模式，
观察者仍然会触发建球 —— 静默模式救不回来，于是每次启动都崩。

也就是「一直闪退」而不是「闪退一次」。

v9 的改动
---------
1. 弃用独立 UIWindow，回到 v3 的 keyWindow 方案（你验证过能正常启动）
2. 点击改用 UITapGestureRecognizer
   v3 的点击失效很可能是 UIPanGestureRecognizer 和 UIButton 的
   touchUpInside 互相干扰 —— 两者都加在同一个 button 上时，
   pan 会抢走 touch 跟踪，button 收不到 touchUpInside
3. installSettingsEntry 去掉「扫描全部类 + 批量 hook」，
   退回固定候选表（批量 hook 不该碰的类是另一个崩溃嫌疑）
4. 保留：WCAIInstallStealth、消息 hook、面板全部功能

如果你现在微信起不来
--------------------
先用全能签重签一个没注入 dylib 的干净微信 IPA，把微信恢复。
确认能正常启动之后，再试这个 v9。

如果 v9 还是闪退
----------------
必须要崩溃日志了，不需要越狱：
  设置 -> 隐私与安全性 -> 分析与改进 -> 分析数据
  找 WeChat 开头、时间最新的那条 .ips
  点进去 -> 右上角分享 -> 存储到文件
重点关注 Exception Type、Triggered by Thread、以及最上面的
几个 WeChat 帧（能看到崩在哪个方法）。
