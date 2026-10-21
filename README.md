# QQLocalPush — QQ 本地推送横幅插件

不依赖苹果远程推送（APNs）的 QQ 消息横幅插件：hook QQ 内部消息接收流程，直接调用
`UNUserNotificationCenter` 弹本地通知，**前台、后台都能弹横幅**。

适合场景：QQ 远程推送收不到（服务端没发 / Quantumult X 等代理阻断 APNs / apsd 异常），
但 QQ 本身在后台存活——本插件让 QQ 自己"喊话"，绕过 APNs。

## 文件说明

| 文件 | 作用 |
|---|---|
| `Tweak.xm` | 插件源码（本地通知逻辑 + 设置 + 去重 + hook） |
| `Makefile` | Theos 构建脚本 |
| `control` | deb 包信息 |
| `QQLocalPush.plist` | Substrate/Substitute 注入过滤（只注入 com.tencent.mqq） |

## 必要条件（不满足则横幅不显示）

1. **系统通知权限**：设置 → 通知 → QQ → 打开"允许通知"
   （本地通知与远程推送共用同一权限，关了什么都弹不出来）
2. **QQ 进程存活**：插件跑在 QQ 内部，QQ 在后台活着就能推；
   QQ 被手动杀掉（多任务界面划掉）后不推送
3. **iOS 15+**（UNUserNotificationCenter API）

## 编译（需要 Theos，macOS 或 Linux）

```bash
# 1. 安装 Theos（macOS 示例）
sudo git clone --recursive https://github.com/theos/theos.git /opt/theos

# 2. 编译打包
cd QQLocalPush
make package

# 产物：packages/com.qq.localpush_1.0.0_iphoneos-arm.deb
```

> Linux 编译 Theos tweak 需要装好 theos + ldid + clang 工具链；
> 也可以把工程上传到 GitHub Actions（theos-action）自动编译。

## 安装

```bash
# 方式一：拷贝到手机后
dpkg -i com.qq.localpush_1.0.0_iphoneos-arm.deb
killall -9 QQ        # 重启 QQ 生效（或注销 SpringBoard）
uicache -p /Applications/QQ.app   # 可选，刷新图标缓存
```

或把 deb 丢到手机用 Sileo/Filza 安装。

## 设置（可选）

设置文件 `/var/mobile/Library/Preferences/com.qq.localpush.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Enabled</key>        <true/>   <!-- 总开关 -->
    <key>FrontBanner</key>    <true/>   <!-- 前台也弹横幅 -->
    <key>ShowContent</key>    <true/>   <!-- 显示消息内容 -->
    <key>OnlyOthers</key>     <true/>   <!-- 只推送别人的消息 -->
    <key>Sound</key>          <true/>   <!-- 播放提示音 -->
    <key>ClearOnOpen</key>    <true/>   <!-- 打开 QQ 时清理已弹通知 -->
    <key>GenericFallback</key><false/>  <!-- 通用回退 hook，默认关 -->
</dict>
</plist>
```

修改后执行 `killall -9 QQ` 重启 QQ 生效（插件启动时读取）。

## 工作原理

1. `Tweak.xm` 的 `%ctor` 在 QQ 启动时加载设置、注册权限自检和"打开 QQ 清理通知"观察者
2. hook 命中 QQ 的消息接收入口 → 提取 发送者/内容/消息ID → `QLPPushBanner()`
3. `QLPPushBanner()` 构造 `UNMutableNotificationContent` 并以 `trigger:nil`（立即触发）投递
   —— `trigger:nil` 的本地通知**无论前后台都会展示横幅**，这是与远程推送的关键区别
4. 同一消息 ID 去重，避免重复弹；打开 QQ 时自动清理已弹出的通知

## 当前状态 / 待办

- ✅ 本地通知框架、设置系统、去重、前后台逻辑：已完成
- ⏳ 方案 A 的消息 hook 精确选择器：需要用 Frida 对运行中的 QQ 侦察确认后
  填入 `Tweak.xm` 中标注的位置（QQ 用 NT 架构，消息类是
  `AIOChatServiceModule.NTAIOChatMessageService` / `ChatRecord.NTChatRecordMessageModel`，
  需枚举其方法确认"收到消息"的入口签名）
- ✅ 方案 B 通用回退：`postNotification:` + 消息名过滤，已内置，默认关闭，
  可在设置里开 `GenericFallback` 应急

## 调试

```bash
# 手机上看插件日志（需要 deviceconsole / socat 等工具）
idevicesyslog | grep QQLocalPush
```

日志会打印加载状态与通知权限警告。
