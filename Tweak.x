// QQLocalPush - Tweak.xm
// QQ 本地推送横幅：hook QQ 消息接收流程，弹本地通知（UNUserNotificationCenter）
// 本地通知不依赖苹果远程推送（APNs），前台/后台均可弹出横幅
//
// 依赖条件（重要）：
//   1. 系统 设置 → 通知 → QQ → “允许通知” 必须打开（本地通知与远程推送共用同一权限）
//   2. 插件只在 QQ 进程内运行：QQ 在后台存活即可推送；被手动杀掉后不推送
//
// 设置文件：/var/mobile/Library/Preferences/com.qq.localpush.plist
//   Enabled        总开关            （默认 YES）
//   FrontBanner    前台也弹横幅       （默认 YES）
//   ShowContent    显示消息内容       （默认 YES，NO 则只显示“你收到一条新消息”）
//   OnlyOthers     只推送别人的消息   （默认 YES）
//   Sound          播放提示音         （默认 YES）
//   ClearOnOpen    打开 QQ 时清理已弹出的通知（默认 YES）
//   GenericFallback 启用通用回退 hook  （默认 NO，见文件末尾方案 B）

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <Foundation/Foundation.h>

// ---------------------------------------------------------------
// 设置
// ---------------------------------------------------------------
static NSString *const kQLPPrefsPath = @"/var/mobile/Library/Preferences/com.qq.localpush.plist";
static NSString *const kQLPPrefsChanged = @"com.qq.localpush/prefs-changed";

static BOOL gQLPEnabled = YES;
static BOOL gQLPFrontBanner = YES;
static BOOL gQLPShowContent = YES;
static BOOL gQLPOnlyOthers = YES;
static BOOL gQLPSound = YES;
static BOOL gQLPClearOnOpen = YES;
static BOOL gQLPGenericFallback = NO;

static NSMutableSet *QLPRecentIDs(void) {
    static NSMutableSet *ids = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ ids = [[NSMutableSet alloc] init]; });
    return ids;
}

static void QLPLoadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kQLPPrefsPath];
    if (!prefs) { return; }
    if (prefs[@"Enabled"] != nil) { gQLPEnabled = [prefs[@"Enabled"] boolValue]; }
    if (prefs[@"FrontBanner"] != nil) { gQLPFrontBanner = [prefs[@"FrontBanner"] boolValue]; }
    if (prefs[@"ShowContent"] != nil) { gQLPShowContent = [prefs[@"ShowContent"] boolValue]; }
    if (prefs[@"OnlyOthers"] != nil) { gQLPOnlyOthers = [prefs[@"OnlyOthers"] boolValue]; }
    if (prefs[@"Sound"] != nil) { gQLPSound = [prefs[@"Sound"] boolValue]; }
    if (prefs[@"ClearOnOpen"] != nil) { gQLPClearOnOpen = [prefs[@"ClearOnOpen"] boolValue]; }
    if (prefs[@"GenericFallback"] != nil) { gQLPGenericFallback = [prefs[@"GenericFallback"] boolValue]; }
}

static void QLPPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    QLPLoadPrefs();
}

// ---------------------------------------------------------------
// 本地推送横幅
// ---------------------------------------------------------------
static void QLPPushBanner(NSString *sender, NSString *text, NSString *ident, BOOL isSelf) {
    if (!gQLPEnabled) { return; }
    if (isSelf && gQLPOnlyOthers) { return; }

    // 去重（同一消息只弹一次）
    NSString *identifier = nil;
    if (ident.length > 0) {
        identifier = [@"qlp-" stringByAppendingString:ident];
        @synchronized(QLPRecentIDs()) {
            if ([QLPRecentIDs() containsObject:identifier]) { return; }
            [QLPRecentIDs() addObject:identifier];
            if ([QLPRecentIDs() count] > 300) { [QLPRecentIDs() removeAllObjects]; }
        }
    } else {
        identifier = [NSString stringWithFormat:@"qlp-%f", [NSDate date].timeIntervalSince1970];
    }

    // 前台开关
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive && !gQLPFrontBanner) { return; }

    NSString *title = (sender.length > 0) ? sender : @"QQ";
    NSString *body = (gQLPShowContent && text.length > 0) ? text : @"你收到一条新消息";

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    if (gQLPSound) { content.sound = [UNNotificationSound defaultSound]; }
    content.threadIdentifier = @"com.qq.localpush";
    content.categoryIdentifier = @"QLP_MESSAGE";

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                          withCompletionHandler:nil];
}

// 打开 QQ 时清理已弹出的通知，避免堆积
static void QLPClearDelivered(void) {
    if (!gQLPClearOnOpen) { return; }
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSMutableArray *identifiers = [NSMutableArray arrayWithCapacity:notifications.count];
        for (UNNotification *notification in notifications) {
            if ([notification.request.identifier hasPrefix:@"qlp-"]) {
                [identifiers addObject:notification.request.identifier];
            }
        }
        if (identifiers.count > 0) {
            [center removeDeliveredNotificationsWithIdentifiers:identifiers];
        }
    }];
}

// 通用字段提取（容错，用于方案 B 与消息模型取字段）
static NSString *QLPStringFromObject(id object, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        @try {
            id value = [object valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return value;
            }
        } @catch (NSException *exception) { }
    }
    return nil;
}

// ---------------------------------------------------------------
// 构造/初始化
// ---------------------------------------------------------------
%ctor {
    @autoreleasepool {
        QLPLoadPrefs();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        QLPPrefsChangedCallback,
                                        (CFStringRef)kQLPPrefsChanged,
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        // 打开 QQ 时清理已推送通知
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            QLPClearDelivered();
        }];

        // 权限自检（没有通知权限时横幅无法显示）
        [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            if (settings.authorizationStatus != UNAuthorizationStatusAuthorized) {
                NSLog(@"[QQLocalPush] WARNING: QQ 通知权限未授权，请到 设置→通知→QQ 打开“允许通知”");
            }
        }];

        NSLog(@"[QQLocalPush] loaded (enabled=%d front=%d content=%d)", gQLPEnabled, gQLPFrontBanner, gQLPShowContent);
    }
}

// ===============================================================
// 方案 A：hook QQ 消息接收入口（Frida 侦察确认后填入精确选择器）
// ---------------------------------------------------------------
// 侦察目标：AIOChatServiceModule.NTAIOChatMessageService
//          ChatRecord.NTChatRecordMessageModel
// 填入格式示例：
//
//   %hook NTAIOChatMessageService
//   - (void)onReceiveMessage:(id)message {
//       %orig;
//       NSString *sender = QLPStringFromObject(message, @[@"nickName", @"senderName", @"friendNick"]);
//       NSString *text   = QLPStringFromObject(message, @[@"msgContent", @"content", @"text"]);
//       NSString *ident  = QLPStringFromObject(message, @[@"msgUid", @"uid", @"msgSeq"]);
//       BOOL isSelf      = [[message valueForKey:@"isSelf"] boolValue];
//       QLPPushBanner(sender, text, ident, isSelf);
//   }
//   %end
//
// 注意：%hook 的方法必须真实存在，否则 Theos 编译报错。
// 精确选择器由下一步 Frida 侦察确认后补全。
// ===============================================================


// ===============================================================
// 方案 B：通用回退（默认关闭，GenericFallback=YES 启用）
// hook NSNotificationCenter，过滤消息相关通知名，尽力提取内容弹横幅。
// 优点：不依赖具体消息类；缺点：字段提取是尽力而为，可能有噪音。
// ===============================================================
%hook NSNotificationCenter

- (void)postNotification:(NSNotification *)notification {
    %orig;
    if (!gQLPEnabled || !gQLPGenericFallback) { return; }

    @autoreleasepool {
        NSString *name = notification.name ?: @"";
        NSString *lower = name.lowercaseString;
        if (![lower containsString:@"msg"] && ![lower containsString:@"message"] && ![lower containsString:@"push"]) { return; }
        if ([lower containsString:@"heartbeat"] || [lower containsString:@"sync"]
            || [lower containsString:@"selfsend"] || [lower containsString:@"statechange"]) { return; }

        id object = notification.object;
        if (!object) { return; }

        NSString *ident = QLPStringFromObject(object, @[@"msgUid", @"uid", @"msgSeq", @"messageID"]);
        NSString *sender = QLPStringFromObject(object, @[@"nickName", @"senderName", @"friendNick", @"uin"]);
        NSString *text = QLPStringFromObject(object, @[@"msgContent", @"content", @"text", @"summary", @"msgSummary"]);

        BOOL isSelf = NO;
        @try {
            id selfValue = [object valueForKey:@"isSelf"];
            if (selfValue) { isSelf = [selfValue boolValue]; }
        } @catch (NSException *exception) { }

        if (text.length > 0 || sender.length > 0) {
            QLPPushBanner(sender, text, ident, isSelf);
        }
    }
}

%end
