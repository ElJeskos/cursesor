#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, InstallerState) {
    InstallerStateReady,
    InstallerStateWorking,
    InstallerStatePermissions,
    InstallerStateSuccess,
    InstallerStateFailure,
};

@interface InstallerDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSProgressIndicator *progressIndicator;
@property(nonatomic, strong) NSButton *primaryButton;
@property(nonatomic, strong) NSButton *accessibilityButton;
@property(nonatomic, strong) NSButton *inputMonitoringButton;
@property(nonatomic) InstallerState state;
- (void)setPrimaryButtonColor:(NSColor *)color;
@end

@implementation InstallerDelegate

- (NSTextField *)labelWithFrame:(NSRect)frame font:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.font = font;
    label.textColor = color;
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    return label;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    const NSRect windowFrame = NSMakeRect(0, 0, 560, 430);
    self.window = [[NSWindow alloc] initWithContentRect:windowFrame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"Установка Game Cursor Fence";
    self.window.releasedWhenClosed = NO;
    self.window.movableByWindowBackground = YES;
    self.window.backgroundColor = [NSColor windowBackgroundColor];

    NSView *content = self.window.contentView;

    self.iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(236, 318, 88, 88)];
    self.iconView.image = [NSImage imageNamed:NSImageNameApplicationIcon];
    self.iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:self.iconView];

    self.titleLabel = [self labelWithFrame:NSMakeRect(40, 276, 480, 32)
                                      font:[NSFont systemFontOfSize:24 weight:NSFontWeightSemibold]
                                     color:[NSColor labelColor]];
    self.titleLabel.stringValue = @"Game Cursor Fence";
    [content addSubview:self.titleLabel];

    self.statusLabel = [self labelWithFrame:NSMakeRect(50, 228, 460, 42)
                                       font:[NSFont systemFontOfSize:16 weight:NSFontWeightMedium]
                                      color:[NSColor labelColor]];
    [content addSubview:self.statusLabel];

    self.detailLabel = [self labelWithFrame:NSMakeRect(55, 145, 450, 76)
                                       font:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
                                      color:[NSColor secondaryLabelColor]];
    [content addSubview:self.detailLabel];

    self.progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(270, 116, 20, 20)];
    self.progressIndicator.style = NSProgressIndicatorStyleSpinning;
    self.progressIndicator.displayedWhenStopped = NO;
    [content addSubview:self.progressIndicator];

    self.accessibilityButton = [[NSButton alloc] initWithFrame:NSMakeRect(74, 92, 200, 34)];
    self.accessibilityButton.title = @"Открыть Accessibility";
    self.accessibilityButton.bezelStyle = NSBezelStyleRounded;
    self.accessibilityButton.target = self;
    self.accessibilityButton.action = @selector(openAccessibility:);
    [content addSubview:self.accessibilityButton];

    self.inputMonitoringButton = [[NSButton alloc] initWithFrame:NSMakeRect(286, 92, 200, 34)];
    self.inputMonitoringButton.title = @"Открыть Input Monitoring";
    self.inputMonitoringButton.bezelStyle = NSBezelStyleRounded;
    self.inputMonitoringButton.target = self;
    self.inputMonitoringButton.action = @selector(openInputMonitoring:);
    [content addSubview:self.inputMonitoringButton];

    self.primaryButton = [[NSButton alloc] initWithFrame:NSMakeRect(190, 38, 180, 42)];
    self.primaryButton.bordered = NO;
    self.primaryButton.controlSize = NSControlSizeLarge;
    self.primaryButton.contentTintColor = [NSColor whiteColor];
    self.primaryButton.wantsLayer = YES;
    self.primaryButton.layer.cornerRadius = 10;
    self.primaryButton.keyEquivalent = @"\r";
    self.primaryButton.target = self;
    self.primaryButton.action = @selector(primaryAction:);
    [content addSubview:self.primaryButton];

    [self showReadyState];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)showReadyState {
    self.state = InstallerStateReady;
    self.statusLabel.stringValue = @"Установить защиту курсора для игр?";
    self.detailLabel.stringValue = @"Установка займёт меньше минуты и не потребует пароля администратора. Программа будет автоматически включаться только для активных игр GameHub и CrossOver.";
    self.statusLabel.textColor = [NSColor labelColor];
    self.primaryButton.title = @"Установить";
    self.primaryButton.enabled = YES;
    [self setPrimaryButtonColor:[NSColor controlAccentColor]];
    self.accessibilityButton.hidden = YES;
    self.inputMonitoringButton.hidden = YES;
    [self.progressIndicator stopAnimation:nil];
}

- (void)showWorkingState:(NSString *)message {
    self.state = InstallerStateWorking;
    self.statusLabel.stringValue = message;
    self.detailLabel.stringValue = @"Пожалуйста, не закрывайте это окно.";
    self.statusLabel.textColor = [NSColor labelColor];
    self.primaryButton.title = @"Установка…";
    self.primaryButton.enabled = NO;
    [self setPrimaryButtonColor:[[NSColor secondaryLabelColor] colorWithAlphaComponent:0.24]];
    self.accessibilityButton.hidden = YES;
    self.inputMonitoringButton.hidden = YES;
    [self.progressIndicator startAnimation:nil];
}

- (void)showPermissionState {
    self.state = InstallerStatePermissions;
    self.statusLabel.stringValue = @"Разрешите управление мышью";
    self.detailLabel.stringValue = @"Откройте оба раздела ниже и включите Game Cursor Fence. После этого вернитесь сюда и нажмите «Проверить снова».";
    self.statusLabel.textColor = [NSColor systemOrangeColor];
    self.primaryButton.title = @"Проверить снова";
    self.primaryButton.enabled = YES;
    [self setPrimaryButtonColor:[NSColor controlAccentColor]];
    self.accessibilityButton.hidden = NO;
    self.inputMonitoringButton.hidden = NO;
    [self.progressIndicator stopAnimation:nil];
}

- (void)showSuccessState {
    self.state = InstallerStateSuccess;
    self.statusLabel.stringValue = @"Готово — Game Cursor Fence установлен";
    self.detailLabel.stringValue = @"Программа уже запущена и будет автоматически работать в активных играх GameHub и CrossOver. Теперь это окно можно закрыть.";
    self.statusLabel.textColor = [NSColor systemGreenColor];
    self.primaryButton.title = @"Готово";
    self.primaryButton.enabled = YES;
    [self setPrimaryButtonColor:[NSColor systemGreenColor]];
    self.accessibilityButton.hidden = YES;
    self.inputMonitoringButton.hidden = YES;
    [self.progressIndicator stopAnimation:nil];
}

- (void)showFailureState:(NSString *)details {
    self.state = InstallerStateFailure;
    self.statusLabel.stringValue = @"Не удалось завершить установку";
    self.detailLabel.stringValue = details.length > 0 ? details : @"Повторите попытку. Если ошибка сохраняется, перезапустите Mac и снова откройте установщик.";
    self.statusLabel.textColor = [NSColor systemRedColor];
    self.primaryButton.title = @"Повторить";
    self.primaryButton.enabled = YES;
    [self setPrimaryButtonColor:[NSColor controlAccentColor]];
    self.accessibilityButton.hidden = YES;
    self.inputMonitoringButton.hidden = YES;
    [self.progressIndicator stopAnimation:nil];
}

- (void)setPrimaryButtonColor:(NSColor *)color {
    NSColor *resolvedColor = [color colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]] ?: color;
    self.primaryButton.layer.backgroundColor = resolvedColor.CGColor;
}

- (void)primaryAction:(id)sender {
    (void)sender;
    switch (self.state) {
        case InstallerStateReady:
        case InstallerStateFailure:
            [self showWorkingState:@"Устанавливаем Game Cursor Fence…"];
            [self runBackendWithArguments:@[]];
            break;
        case InstallerStatePermissions:
            [self showWorkingState:@"Проверяем разрешения macOS…"];
            [self runBackendWithArguments:@[@"--restart-only"]];
            break;
        case InstallerStateSuccess:
            [NSApp terminate:nil];
            break;
        case InstallerStateWorking:
            break;
    }
}

- (void)openAccessibility:(id)sender {
    (void)sender;
    [self openSystemSettingsURL:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
}

- (void)openInputMonitoring:(id)sender {
    (void)sender;
    [self openSystemSettingsURL:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"];
}

- (void)openSystemSettingsURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)runBackendWithArguments:(NSArray<NSString *> *)arguments {
    NSString *backendPath = [[NSBundle mainBundle] pathForResource:@"Install" ofType:@"command"];
    if (!backendPath) {
        [self showFailureState:@"В установщике отсутствует служебный компонент Install.command."];
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    NSMutableArray<NSString *> *taskArguments = [NSMutableArray arrayWithObject:backendPath];
    [taskArguments addObjectsFromArray:arguments];
    task.arguments = taskArguments;

    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = outputPipe;

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
        int status = finishedTask.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            InstallerDelegate *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (status == 0) {
                [strongSelf showSuccessState];
            } else if (status == 2) {
                [strongSelf showPermissionState];
            } else {
                NSString *details = [strongSelf conciseErrorFromOutput:output];
                [strongSelf showFailureState:details];
            }
        });
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        [self showFailureState:launchError.localizedDescription];
    }
}

- (NSString *)conciseErrorFromOutput:(NSString *)output {
    NSString *trimmed = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return @"Установщик завершился с ошибкой без дополнительного сообщения.";
    }
    if (trimmed.length > 280) {
        return [trimmed substringFromIndex:trimmed.length - 280];
    }
    return trimmed;
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        InstallerDelegate *delegate = [[InstallerDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
