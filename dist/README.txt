WeChatAIChatTweak v2 注入包（含悬浮球入口）
============================================
libmarsbridge.dylib  240.7 KB  arm64 Mach-O  iOS 14.0+
SHA256 : B38DAB83809E9DFCF92BE932B21D76C218992D90FC7C35C02E4D5B643A6037AC

本版修复了什么
--------------
上一版「设置页 hook 没命中 → 兜底函数是空实现」，所以你完全看不到插件。
现在无论设置页是否命中，屏幕左侧都会挂一个 AI 悬浮球（可拖动）。

怎么判断
--------
看到球     → dylib 加载成功。点球进设置 → 调试 → 自检诊断
看不到球   → dylib 没被加载，属于注入/签名问题，跟插件代码无关

注入要求
--------
1. IPA 必须砸壳（cryptid 0）
2. dylib 必须落在 Payload/WeChat.app/Frameworks/
3. Bundle ID 保持 com.tencent.xin，entitlements 沿用原微信
