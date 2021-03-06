#import "CTBrowser.h"
#import "CTTabStripModel.h"
#import "CTTabStripController.h"
#import "CTBrowserWindowController.h"
#import "CTTabContentsViewController.h"
#import "CTBrowserCommand.h"
#import "CTTabContents.h"

@implementation CTBrowser
@synthesize windowController = windowController_;
@synthesize tabStripModel2 = tabStripModel2_;

+ (CTBrowser*)browser {
    return [[self alloc] init];
}


- (id)init {
    if ((self = [super init])) {
        tabStripModel2_ = [[CTTabStripModel alloc] initWithDelegate:self];
    }
    return self;
}

-(CTTabContentsViewController*)createTabContentsControllerWithContents:(CTTabContents*)contents {
    // subclasses could override this
    return [[CTTabContentsViewController alloc] initWithContents:contents];
}


#pragma mark -
#pragma mark Accessors

-(NSWindow*)window {
    return [windowController_ window];
}

#pragma mark -
#pragma mark Callbacks

-(void)loadingStateDidChange:(CTTabContents*)contents {
    // TODO: Make sure the loading state is updated correctly
}

-(void)windowDidBeginToClose {
    [tabStripModel2_ closeAllTabs];
}

#pragma mark -
#pragma mark Commands

-(void)newWindow {
    Class cls = self.windowController ? [self.windowController class] :
    [CTBrowserWindowController class];
    CTBrowser *browser = [isa browser];
    CTBrowserWindowController* windowController =
    [[cls alloc] initWithBrowser:browser];
    [browser addBlankTabInForeground:YES];
    [windowController showWindow:self];
}

-(void)closeWindow {
    [self.windowController close];
}

-(CTTabContents*)addTabContents:(CTTabContents*)contents atIndex:(int)index inForeground:(BOOL)foreground {
    int addTypes = foreground ? (ADD_SELECTED | ADD_INHERIT_GROUP) : ADD_NONE;
    [tabStripModel2_ addTabContents:contents atIndex:index options:addTypes];
    if ((addTypes & ADD_SELECTED) == 0) {
        contents.isVisible = NO;
    }
    return contents;
}


-(CTTabContents*)addTabContents:(CTTabContents*)contents inForeground:(BOOL)foreground {
    return [self addTabContents:contents atIndex:-1 inForeground:foreground];
}


-(CTTabContents*)addTabContents:(CTTabContents*)contents {
    return [self addTabContents:contents atIndex:-1 inForeground:YES];
}


-(CTTabContents*)createBlankTabBasedOn:(CTTabContents*)baseContents {
    // subclasses should override this to provide a custom CTTabContents type and/or initialization
    return [[CTTabContents alloc] initWithBaseTabContents:baseContents];
}

-(CTTabContents*)addBlankTabAtIndex:(int)index inForeground:(BOOL)foreground {
    CTTabContents* baseContents = [tabStripModel2_ selectedTabContents];
    CTTabContents* contents = [self createBlankTabBasedOn:baseContents];
    return [self addTabContents:contents atIndex:index inForeground:foreground];
}

-(CTTabContents*)addBlankTabInForeground:(BOOL)foreground {
    return [self addBlankTabAtIndex:-1 inForeground:foreground];
}

-(CTTabContents*)addBlankTab {
    return [self addBlankTabInForeground:YES];
}

-(void)closeTab {
    if ([self canCloseTab]) {
        [tabStripModel2_ closeTabContentsAtIndex:[tabStripModel2_ selectedIndex] options:CLOSE_USER_GESTURE | CLOSE_CREATE_HISTORICAL_TAB];
    }
}

-(void)selectNextTab {
    [tabStripModel2_ selectNextTab];
}

-(void)selectPreviousTab {
    [tabStripModel2_ selectPreviousTab];
}

-(void)moveTabNext {
    [tabStripModel2_ moveTabNext];
}

-(void)moveTabPrevious {
    [tabStripModel2_ moveTabPrevious];
}

-(void)selectTabAtIndex:(NSInteger)index {
    if (index < [tabStripModel2_ count]) {
        [tabStripModel2_ selectTabContentsAtIndex:index userGesture:YES];
    }
}

-(void)selectLastTab {
    [tabStripModel2_ selectLastTab];
}

-(void)duplicateTab {
}


-(void)executeCommand:(NSInteger)cmd withDisposition:(CTWindowOpenDisposition)disposition {
    if (![tabStripModel2_ selectedTabContents]) {
        return;
    }
    
    // The order of commands in this switch statement must match the function declaration order in BrowserCommands.h
    switch (cmd) {
        case CTBrowserCommandNewWindow:            [self newWindow]; break;
        case CTBrowserCommandCloseWindow:          [self closeWindow]; break;
        case CTBrowserCommandNewTab:               [self addBlankTab]; break;
        case CTBrowserCommandCloseTab:             [self closeTab]; break;
        case CTBrowserCommandSelectNextTab:       [self selectNextTab]; break;
        case CTBrowserCommandSelectPreviousTab:   [self selectPreviousTab]; break;
        case CTBrowserCommandSelectTab0:
        case CTBrowserCommandSelectTab1:
        case CTBrowserCommandSelectTab2:
        case CTBrowserCommandSelectTab3:
        case CTBrowserCommandSelectTab4:
        case CTBrowserCommandSelectTab5:
        case CTBrowserCommandSelectTab6:
        case CTBrowserCommandSelectTab7: {
            [self selectTabAtIndex:cmd - CTBrowserCommandSelectTab0];
            break;
        }
        case CTBrowserCommandSelectLastTab:    [self selectLastTab]; break;
        case CTBrowserCommandDuplicateTab:     [self duplicateTab]; break;
        case CTBrowserCommandExit:             [NSApp terminate:self]; break;
        case CTBrowserCommandMoveTabNext:      [self moveTabNext]; break;
        case CTBrowserCommandMoveTabPrevious:  [self moveTabPrevious]; break;
    }
}

-(void)executeCommand:(NSInteger)cmd {
    [self executeCommand:cmd withDisposition:CTWindowOpenDispositionCurrentTab];
}

+(void)executeCommand:(NSInteger)cmd {
    switch (cmd) {
        case CTBrowserCommandExit:      [NSApp terminate:self]; break;
    }
}


#pragma mark -
#pragma mark CTTabStripModelDelegate protocol implementation


-(CTBrowser*)createNewStripWithContents:(CTTabContents*)contents {
    CTBrowser* browser = [isa browser];
    [browser.tabStripModel2 appendTabContents:contents foreground:YES];
    [browser loadingStateDidChange:contents];
    
    return browser;
}

-(void)continueDraggingDetachedTab:(CTTabContents*)contents windowBounds:(const NSRect)windowBounds tabBounds:(const NSRect)tabBounds {
    [self doesNotRecognizeSelector:_cmd];
}


-(BOOL)canDuplicateContentsAt:(int)index {
    return NO;
}

-(void)duplicateContentsAt:(int)index {
    [self doesNotRecognizeSelector:_cmd];
}

-(void)closeFrameAfterDragSession {
}

-(void)createHistoricalTab:(CTTabContents*)contents {
    
}

-(BOOL)runUnloadListenerBeforeClosing:(CTTabContents*)contents {
    return NO;
}

-(BOOL)canRestoreTab {
    return NO;
}

-(void)restoreTab {
}

-(BOOL)canCloseContentsAt:(int)index {
    return YES;
}

-(BOOL)canCloseTab {
    return YES;
}

- (void) setWindowController:(CTBrowserWindowController *)windowController
{
    if (windowController_ != windowController) {
        windowController_ = windowController;
    }
}

@end
