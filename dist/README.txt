WeChatAIChatTweak v8 注入包（修复启动闪退）
============================================
libmarsbridge.dylib  263.7 KB  arm64 Mach-O  iOS 14.0+
SHA256 : 3D6077998A7A1563704EDF86318788660DEF8B76930159D1A26C1755F54BADE4

闪退根因
--------
v7 在 __attribute__((constructor)) 里直接创建悬浮球 UIWindow。
constructor 跑在 main() 之前，那时 UIApplication 还没起来，
connectedScenes 是空的，于是退化到 initWithFrame: 建了一个
没有 windowScene 的窗口 —— iOS 13+ 的 scene 架构会对此断言，
行为就是启动闪退。

第二次能进，是因为 WCAIShouldRunSilently() 判定上次异常退出，
本次进入静默模式（不装 hook 也不建球），所以不崩。

v8 修复
-------
1. 所有 UI 一律推迟到 UIApplicationDidBecomeActiveNotification 之后创建
2. createBallWindow 改成「拿不到活跃 windowScene 就直接返回」，
   由下一次 DidBecomeActive 重试，绝不在无 scene 时建窗
3. constructor 里只保留：隐蔽层安装 + 观察者注册 + 崩溃自保护判断

预期表现
--------
装好后第一次启动就应该正常进入，不再闪退。
球会在微信界面完全出来之后出现（比之前晚约 1 秒，这是正常的）。

如果仍然闪退
------------
请给我崩溃日志，不需要越狱也能拿到：
  设置 -> 隐私与安全性 -> 分析与改进 -> 分析数据
  在列表里找 WeChat 开头、最近时间的那条（.ips 文件）
  点进去，右上角分享 -> 存储到文件，然后发给我

日志里的 "Exception Type" 和 "Triggered by Thread" 那几行最关键，
能直接指到是哪一行代码崩的。
