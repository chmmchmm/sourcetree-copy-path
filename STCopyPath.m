// SourceTree Copy Path — injected library.
//
// Adds a "Copy Path" item to the bookmark-list right-click menu and copies the
// selected repository path. The click is routed through SourceTree's own
// custom-action runner so the app shows its usual task window.
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Localized menu titles used to locate menu anchors inside the app.
// Kept as escapes so the source file stays pure ASCII.
static NSString *const kCustomActionsZh = @"\u81ea\u5b9a\u4e49\u64cd\u4f5c";   // Custom Actions
static NSString *const kOpenInTerminalZh = @"\u5728\u7ec8\u7aef\u4e2d\u6253\u5f00"; // Open in Terminal
static NSString *const kCopyPathZh = @"\u62f7\u8d1d\u8def\u5f84";              // Copy Path

static NSString *const kFallbackTitle = @"Copy Path";
static const NSInteger kMenuItemTag = 0x53544350; // 'STCP'

// Minimal repository stand-in: the app only needs a path to expand $REPO.
@interface STFakeRepo : NSObject
@property (nonatomic, copy) NSString *path;
@end

@implementation STFakeRepo
- (NSURL *)url { return self.path ? [NSURL fileURLWithPath:self.path] : nil; }
- (NSString *)name { return self.path.lastPathComponent; }
- (NSString *)description { return self.path ?: @""; }
@end

@interface STCopyPathHelper : NSObject
+ (instancetype)shared;
- (void)copySelectedRepoPath:(id)sender;
@property (nonatomic, unsafe_unretained) NSView *pendingView; // outline view that received the right click
@property (nonatomic, assign) NSInteger pendingRow;           // row under the right click
@property (nonatomic, assign) NSTimeInterval pendingTime;     // timestamp, expires
@end

@implementation STCopyPathHelper

+ (instancetype)shared {
    static id shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

// The app localizes its own menus (no .lproj for Chinese), so detect the
// language from the menu it actually built.
static BOOL STMenuIsEnglish(NSMenu *menu) {
    if (!menu) return YES;
    return [menu indexOfItemWithTitle:@"Open in Terminal"] >= 0
        && [menu indexOfItemWithTitle:kOpenInTerminalZh] < 0;
}

// Name of the first configured custom action, used to match the action dict.
static NSString *STConfiguredActionName(void) {
    @try {
        id delegate = [NSApp delegate];
        id actions = [delegate valueForKey:@"customActions"];
        if ([actions isKindOfClass:[NSArray class]]) {
            for (NSDictionary *action in (NSArray *)actions) {
                id name = [action valueForKey:@"name"];
                if ([name isKindOfClass:[NSString class]] && [name length] > 0) return name;
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

static NSString *STDisplayTitle(NSMenu *menu) {
    if (STMenuIsEnglish(menu)) return kFallbackTitle; // English UI → English label
    NSString *configured = STConfiguredActionName();
    return configured.length ? configured : kCopyPathZh;
}

// Depth-first search for the bookmark outline view inside a window.
static NSView *FindBookmarkOutlineView(NSView *root) {
    if (!root) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        NSView *v = stack.lastObject;
        [stack removeLastObject];
        if ([NSStringFromClass([v class]) isEqualToString:@"STRepoBrowserBookmarkOutlineView"]) return v;
        if ([v isKindOfClass:[NSView class]]) [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

// Collect the repository paths the user is acting on: the row that received the
// right click when known, otherwise the highlighted rows.
- (NSArray<NSString *> *)selectedRepoPaths {
    NSMutableArray *paths = [NSMutableArray array];
    BOOL hasPending = (self.pendingView != nil) && (self.pendingRow >= 0)
                      && (NSDate.date.timeIntervalSince1970 - self.pendingTime < 30);
    for (NSWindow *w in [NSApp orderedWindows]) {
        if (![NSStringFromClass([w.windowController class]) isEqualToString:@"STRepoBrowserWindowController"]) continue;
        NSView *outline = FindBookmarkOutlineView(w.contentView);
        if (![outline isKindOfClass:[NSOutlineView class]]) continue;

        if (hasPending && outline == self.pendingView) {
            id node = [(NSOutlineView *)outline itemAtRow:self.pendingRow];
            id p = [node valueForKey:@"path"];
            if ([p isKindOfClass:[NSString class]] && [p length] > 0) {
                [paths addObject:p];
                continue;
            }
        }

        NSIndexSet *idx = [(NSOutlineView *)outline selectedRowIndexes];
        NSInteger row = (NSInteger)idx.firstIndex;
        while (row >= 0) {
            id node = [(NSOutlineView *)outline itemAtRow:row];
            id p = [node valueForKey:@"path"];
            if ([p isKindOfClass:[NSString class]] && [p length] > 0) [paths addObject:p];
            NSUInteger next = [idx indexGreaterThanIndex:(NSUInteger)row];
            row = (next == NSNotFound) ? -1 : (NSInteger)next;
        }
    }
    return paths;
}

// Hand the action to SourceTree itself so it runs the script (and shows its
// task window) exactly like a built-in custom action.
- (BOOL)runNativeActionForPath:(NSString *)path window:(NSWindow *)window {
    id delegate = [NSApp delegate];
    SEL sel = NSSelectorFromString(@"performCustomAction:forRepo:withSHAs:withFiles:window:");
    if (!delegate || ![delegate respondsToSelector:sel]) return NO;

    id action = nil;
    id actions = [delegate valueForKey:@"customActions"];
    if ([actions isKindOfClass:[NSArray class]]) {
        for (NSDictionary *candidate in (NSArray *)actions) {
            NSString *wanted = STConfiguredActionName();
            if (wanted && [[candidate valueForKey:@"name"] isEqual:wanted]) { action = candidate; break; }
        }
    }
    if (!action) return NO;

    STFakeRepo *repo = [STFakeRepo new];
    repo.path = path;

    typedef void (*Fn)(id, SEL, id, id, id, id, id);
    @try {
        ((Fn)objc_msgSend)(delegate, sel, action, repo, nil, nil, window);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

- (void)copySelectedRepoPath:(id)sender {
    NSArray<NSString *> *paths = [self selectedRepoPaths];
    NSString *text = paths.count ? [paths componentsJoinedByString:@"\n"] : @"";

    NSWindow *bookmarkWindow = nil;
    for (NSWindow *w in [NSApp orderedWindows]) {
        if ([NSStringFromClass([w.windowController class]) isEqualToString:@"STRepoBrowserWindowController"]) {
            bookmarkWindow = w;
            break;
        }
    }

    if (paths.count == 1 && [self runNativeActionForPath:paths.firstObject window:bookmarkWindow]) return;

    // Fallback: write the clipboard directly.
    if (text.length) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:text forType:NSPasteboardTypeString];
    }
}

@end

// Ensure the top-level bookmark menu contains the item.
static void STSetupWindow(NSWindow *window) {
    if (![NSStringFromClass([window.windowController class]) isEqualToString:@"STRepoBrowserWindowController"]) return;
    NSView *outline = FindBookmarkOutlineView(window.contentView);
    NSMenu *rootMenu = outline.menu;
    if (!rootMenu) return;

    // Drop entries an older build may have placed in the Custom Actions submenu.
    for (NSMenuItem *it in [rootMenu.itemArray copy]) {
        NSMenu *sub = it.submenu;
        if (![sub.title isEqualToString:kCustomActionsZh] && ![sub.title isEqualToString:@"Custom Actions"]) continue;
        for (NSMenuItem *subItem in [sub.itemArray copy]) {
            if (subItem.tag == kMenuItemTag) [sub removeItem:subItem];
        }
    }

    NSString *title = STDisplayTitle(rootMenu);

    // Keep a single entry; refresh its title if the configuration changed.
    for (NSMenuItem *it in rootMenu.itemArray) {
        if (it.tag == kMenuItemTag) {
            it.title = title;
            it.enabled = YES;
            return;
        }
    }

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:@selector(copySelectedRepoPath:)
                                          keyEquivalent:@""];
    item.target = [STCopyPathHelper shared];
    item.tag = kMenuItemTag;
    item.enabled = YES;

    // Place it right after "Open in Terminal" so it groups with the file actions.
    NSArray<NSString *> *anchors = @[
        kOpenInTerminalZh, @"Open in Terminal",
        @"\u5728 Finder \u4e2d\u663e\u793a", @"Show in Finder"
    ];
    NSInteger anchor = -1;
    for (NSString *title in anchors) {
        NSInteger idx = [rootMenu indexOfItemWithTitle:title];
        if (idx >= 0) { anchor = idx; break; }
    }
    if (anchor >= 0) {
        [rootMenu insertItem:item atIndex:anchor + 1];
    } else if (rootMenu.numberOfItems > 6) {
        [rootMenu insertItem:item atIndex:6]; // Safe fallback: stay in the file-action group
    } else {
        [rootMenu addItem:item];
    }
}

static void STSetupAllWindows(void) {
    for (NSWindow *w in [NSApp windows]) STSetupWindow(w);
}

// Remember which row was right-clicked; the table only highlights on left click.
static NSMenu *(*STOrigMenuForEvent)(id, SEL, NSEvent *);

static NSMenu *STMenuForEvent(id self, SEL _cmd, NSEvent *event) {
    @try {
        if ([(id)self respondsToSelector:@selector(rowAtPoint:)]) {
            NSPoint pt = [(NSTableView *)self convertPoint:event.locationInWindow fromView:nil];
            NSInteger row = [(NSTableView *)self rowAtPoint:pt];
            STCopyPathHelper *h = [STCopyPathHelper shared];
            h.pendingView = self;
            h.pendingRow = row;
            h.pendingTime = NSDate.date.timeIntervalSince1970;
        }
    } @catch (NSException *e) { }
    return STOrigMenuForEvent ? STOrigMenuForEvent(self, _cmd, event) : nil;
}

static void STInstallMenuForEventHook(void) {
    Class c = NSClassFromString(@"STRepoBrowserBookmarkOutlineView");
    if (!c) return;
    SEL sel = @selector(menuForEvent:);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (method_getImplementation(m) == (IMP)STMenuForEvent) return;
    STOrigMenuForEvent = (NSMenu *(*)(id, SEL, NSEvent *))method_getImplementation(m);
    method_setImplementation(m, (IMP)STMenuForEvent);
}

@interface STCopyPathBootstrap : NSObject
@end

@implementation STCopyPathBootstrap
+ (void)load {
    STInstallMenuForEventHook();
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ STSetupAllWindows(); });
    }];
    [nc addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
        STSetupWindow(n.object);
    }];
    [nc addObserverForName:NSWindowDidBecomeMainNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
        STSetupWindow(n.object);
    }];
    // Also run once when the library is injected into an already running app.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ STSetupAllWindows(); });
}
@end
