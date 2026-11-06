# 编译与注入说明（P0 骨架）

## 0. 前提校验（在越狱/远程 Linux 上做，不是装完再排查）

```bash
# 必须已砸壳：cryptid 必须为 0
otool -l WeChat.app/WeChat | grep -A4 LC_ENCRYPTION_INFO_64
# 期望看到 cryptid 0

# 架构
lipo -info WeChat.app/WeChat
# 期望 arm64（6s 及更早机型还需 arm64e 切片）

# 若存在 __RESTRICT 段需移除，否则注入的 dylib 会被 dyld 拒载
otool -l WeChat.app/WeChat | grep -A1 __RESTRICT
```

## 1. 编译

```bash
export THEOS=~/theos
cd WeChatAIChatTweak
make clean && make
```

产物：`.theos/obj/libmmwechat_util.dylib`（Makefile 的 `after-all` 已自动改名 + `ldid -S` 伪签）。

> 若 `ldid` 不在 PATH，先 `brew install ldid`（macOS）或 `apt install ldid`（Linux）。

## 2. 注入（全能签）

1. 微信 IPA → 全能签打开；
2. **注入插件** → 选择 `libmmwechat_util.dylib`；
3. **bundle id 必须保持 `com.tencent.xin`**（不要用"随机 bundle id"）；
4. **勾选「保留原始 entitlements」**（否则推送/分享/支付残缺）；
5. 用**固定证书**签名 → 安装。

以后升级只需重做第 1–5 步，覆盖安装（**不要卸载 App**），数据容器会保留。

## 3. 首次启动验收（对应 02 文档的验收表）

| 检查 | 期望 |
|---|---|
| 打开微信 → 我 → 设置 | 右下角出现「AI」圆钮，点开是设置页 |
| 设置页 → 调试 → 运行状态 | 显示 `wx<版本> / hook N·M`，N ≥ 1 才说明收消息 hook 成功 |
| 设置页 → 大模型接口 | 填 `api_url`（如 `https://api.xxx.com/v1`）、`api_key`、`model` |
| 登录后前 60 秒 | `run_log` **不应**有任何 `gen` 记录（同步窗口闸门生效） |
| 给某人连发 5 条消息 | 落库正好 5 条，弹窗不重复出现 |
| 对方发图/语音 | 库里有 `[发来一张图片]` 占位，上下文不断 |
| 弹窗 | 3 条可编辑、有情绪/机会/风险、有时机建议 |
| 改 3 个字点发送 | 微信里是改后的文本 |
| 断网测试 | 弹窗仍出内容，标题带「降级模板」 |

## 4. 已知需要在真机编译后校准的点

骨架按"零依赖 + 多候选选择器"写的，以下位置在真机编译/运行后可能需要微调（都已集中，改动量小）：

1. **`WCAICommon.h` 的选择器候选表** —— 用"运行状态"里显示的 `hook N·M` 判断，M 非 0 说明有未命中项，按微信版本补候选。
2. **`imp_implementationWithBlock` 的签名** —— 历史加载方法在不同版本可能返回 `void`（通过回调传数据）。若该校准失败，`history ingest` 会静默跳过，功能降级为"从下次进入会话开始积累"，不影响其它模块。
3. **`CMessageWrap` 的字段名** —— 已做多候选 KVC（`m_nsContent` / `content` 等），个别版本可能不同。
4. **设置页入口** —— 已 hook 三个候选 VC 的 `viewWillAppear:`；若都不命中，需按实际类名补一个。

## 5. 目录

```
src/WCAICommon.h        类名/选择器集中表（唯一允许出现微信私有名的文件）
src/WCAIEntry.m         constructor + 延迟挂 hook + 版本探测 + 去重 + 免打扰
src/WCAIStore.h/.m      sqlite3 + 串行队列 + 7 表 + 索引 + 快照备份
src/WCAIInterceptor.m   三道闸门 + 占位符 + 预热 + 编排 + 唯一发送出口
src/WCAIPrompt.m        固定顺序 Prompt + 防注入分隔 + 语气卡 + 降级模板
src/WCAILLM.m           NSURLSession + 8s/30s + 重试 + JSON 容错链
src/WCAIPreviewVC.m     独立 UIWindow 弹窗 + 就地编辑 + 时机建议
src/WCAISettingsVC.m    微信内自建设置 + 联系人档案 + 备份
```

## 6. 构建是主号安全构建

`Makefile` 里 `-DWCAI_DISABLE_AUTO=1`，且 `WCAIAutoEngine.m` 被 `filter-out` 排除在编译列表外；`config` 表不建任何 `auto_*` 列；设置页无自动模式入口。三层都拆掉，进程内不存在自动发送代码路径。
