WeChatAIChatTweak v4 注入包（设置页原生入口，已移除悬浮球）
=============================================================
libmarsbridge.dylib  242 KB  arm64 Mach-O  iOS 14.0+
SHA256 : 92C9427D81CBBF7D508E3AEBED3A8078F635606E4E6456857025B1ABE778787C

变更
----
[移除] 右下角常驻悬浮球全部代码
       installFloatBall / placeFloatBall / dragBall: / currentKeyWindow
       及相关 UIButton、UIPanGestureRecognizer、NSTimer 补挂逻辑
[新增] 设置页原生 Cell 入口
       位置：微信【我 → 设置】内「关于微信」上方
       样式：原生 Cell + 灯泡图标 + 文字「AI 助手」+ 右侧箭头 + 深色模式自适应
       点击：present 已有的 AI 助手配置面板（面板本身零改动）
[保留] 左上角消息触发预览浮窗（WCAIPreviewVC）完全未动
[保留] 面板内全部配置项与「当前构建禁用全自动」提示文案

实现方式
--------
Hook WXSettingViewController 的四个数据源方法，遵循微信自身渲染逻辑：
  tableView:numberOfRowsInSection:        插入点 section 多一行
  tableView:cellForRowAtIndexPath:        插入点返回我们的 cell，其余 index 减一映射
  tableView:didSelectRowAtIndexPath:      我们的行开面板，其余透传
  tableView:willDisplayCell:forRowAtIndexPath:
                                          运行时探测「关于微信」的真实位置

插入位置不硬编码 section 序号——微信各版本设置页结构不同，硬编码必错。
改为显示时探测「关于微信」所在行，探测到后 reload 一次让插入生效。

分身兼容
--------
代码内无任何 bundleIdentifier / com.tencent 硬编码判断，
改过 Bundle ID 的分身微信可直接使用。

验证要点
--------
1. 微信【我 → 设置】，在「关于微信」上方应出现「AI 助手」一行
2. 点它应弹出配置面板
3. 首次进设置页列表可能闪一下（探测到位置后 reload 一次），之后不再闪
4. 右下角不应再有任何悬浮球
