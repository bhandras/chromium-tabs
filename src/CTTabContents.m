#import "CTTabContents.h"
#import "CTTabStripModel2.h"
#import "CTBrowser.h"

NSString* const CTTabContentsDidCloseNotification =
@"CTTabContentsDidCloseNotification";

@implementation CTTabContents {
    BOOL isApp_;
    BOOL isLoading_;
    BOOL isWaitingForResponse_;
    BOOL isCrashed_;
    BOOL isVisible_;
    BOOL isSelected_;
    BOOL isTeared_;
    id delegate_;
    unsigned int closedByUserGesture_;
    NSView *view_;
    NSString *title_;
    NSImage *icon_;
    CTBrowser *browser_;
    CTTabContents* parentOpener_;
}
@synthesize delegate = delegate_;
@synthesize closedByUserGesture = closedByUserGesture_;
@synthesize view = view_;
@synthesize isApp = isApp_;
@synthesize browser = browser_;
@synthesize isLoading = isLoading_;
@synthesize isCrashed = isCrashed_;
@synthesize isWaitingForResponse = isWaitingForResponse_;
@synthesize title = title_;
@synthesize icon = icon_;

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString*)key {
    if ([key isEqualToString:@"isLoading"] ||
        [key isEqualToString:@"isWaitingForResponse"] ||
        [key isEqualToString:@"isCrashed"] ||
        [key isEqualToString:@"isVisible"] ||
        [key isEqualToString:@"title"] ||
        [key isEqualToString:@"icon"] ||
        [key isEqualToString:@"parentOpener"] ||
        [key isEqualToString:@"isSelected"] ||
        [key isEqualToString:@"isTeared"]) {
        return YES;
    }
    return [super automaticallyNotifiesObserversForKey:key];
}


-(id)initWithBaseTabContents:(CTTabContents*)baseContents {
    // subclasses should probably override this
    self.parentOpener = baseContents;
    return [super init];
}

#pragma mark -
#pragma mark Properties

-(BOOL)hasIcon {
    return YES;
}

- (CTTabContents*)parentOpener {
    return parentOpener_;
}

- (void)setParentOpener:(CTTabContents*)parentOpener {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    if (parentOpener_) {
        [nc removeObserver:self name:CTTabContentsDidCloseNotification object:parentOpener_];
    }
    [self willChangeValueForKey:@"parentOpener"];
    parentOpener_ = parentOpener;
    [self didChangeValueForKey:@"parentOpener"];
    if (parentOpener_) {
        [nc addObserver:self selector:@selector(tabContentsDidClose:) name:CTTabContentsDidCloseNotification object:parentOpener_];
    }
}

- (void)tabContentsDidClose:(NSNotification*)notification {
    CTTabContents* tabContents = [notification object];
    if (tabContents == parentOpener_) {
        parentOpener_ = nil;
    }
}


-(void)setIsVisible:(BOOL)visible {
    if (isVisible_ != visible && !isTeared_) {
        isVisible_ = visible;
        if (isVisible_) {
            [self tabDidBecomeVisible];
        } else {
            [self tabDidResignVisible];
        }
    }
}

-(BOOL)isVisible {
    return isVisible_;
}

-(void)setIsSelected:(BOOL)selected {
    if (isSelected_ != selected && !isTeared_) {
        isSelected_ = selected;
        if (isSelected_) {
            [self tabDidBecomeSelected];
        } else {
            [self tabDidResignSelected];
        }
    }
}

-(BOOL)isSelected {
    return isSelected_;
}

-(void)setIsTeared:(BOOL)teared {
    if (isTeared_ != teared) {
        isTeared_ = teared;
        if (isTeared_) {
            [self tabWillBecomeTeared];
        } else {
            [self tabWillResignTeared];
            [self tabDidBecomeSelected];
        }
    }
}

-(BOOL)isTeared {
    return isTeared_;
}

#pragma mark -
#pragma mark Actions

- (void)makeKeyAndOrderFront:(id)sender {
    if (browser_) {
        NSWindow *window = browser_.window;
        if (window) {
            [window makeKeyAndOrderFront:sender];
        }
        int index = [browser_ indexOfTabContents:self];
        assert(index > -1);
        [browser_ selectTabAtIndex:index];
    }
}


- (BOOL)becomeFirstResponder {
    if (isVisible_) {
        return [[view_ window] makeFirstResponder:view_];
    }
    return NO;
}

#pragma mark -
#pragma mark Callbacks

-(void)closingOfTabDidStart:(CTTabStripModel2*)closeInitiatedByTabStripModel {
    [[NSNotificationCenter defaultCenter] postNotificationName:CTTabContentsDidCloseNotification object:self];
}

- (void)tabDidInsertIntoBrowser:(CTBrowser*)browser atIndex:(NSInteger)index inForeground:(bool)foreground {
    self.browser = browser;
}

- (void)tabReplaced:(CTTabContents*)oldContents inBrowser:(CTBrowser*)browser atIndex:(NSInteger)index {
    self.browser = browser;
}

- (void)tabWillCloseInBrowser:(CTBrowser*)browser atIndex:(NSInteger)index {
    self.browser = nil;
}

- (void)tabDidDetachFromBrowser:(CTBrowser*)browser atIndex:(NSInteger)index {
    self.browser = nil;
}

-(void)tabWillBecomeSelected {}
-(void)tabWillResignSelected {}

-(void)tabDidBecomeSelected {
    [self becomeFirstResponder];
}

-(void)tabDidResignSelected {}
-(void)tabDidBecomeVisible {}
-(void)tabDidResignVisible {}

-(void)tabWillBecomeTeared {}

-(void)tabWillResignTeared {}

-(void)tabDidResignTeared {
    [[view_ window] makeFirstResponder:view_];
}

-(void)viewFrameDidChange:(NSRect)newFrame {
    [view_ setFrame:newFrame];
}

- (void) setIsLoading:(BOOL)isLoading
{
    if (isLoading_ != isLoading) {
        isLoading_ = isLoading;
    }
    if (browser_) {
        [browser_ updateTabStateForContent:self];
    }
}

- (void) setIsWaitingForResponse:(BOOL)isWaitingForResponse
{
    if (isWaitingForResponse_ != isWaitingForResponse) {
        isWaitingForResponse_ = isWaitingForResponse;
    }
    if (browser_) {
        [browser_ updateTabStateForContent:self];
    }
}

- (void) setIsCrashed:(BOOL)isCrashed
{
    if (isCrashed_ != isCrashed) {
        isCrashed_ = isCrashed;
    }
    if (browser_) {
        [browser_ updateTabStateForContent:self];
    }
}

- (void) setTitle:(NSString*)title
{
    if (title_ != title) {
        title_ = title;
    }
    if (browser_) {
        [browser_ updateTabStateForContent:self];
    }
}

- (void) setIcon:(NSImage*)icon
{
    if (icon_ != icon) {
        icon_ = icon;
    }
    if (browser_) {
        [browser_ updateTabStateForContent:self];
    }
}

@end