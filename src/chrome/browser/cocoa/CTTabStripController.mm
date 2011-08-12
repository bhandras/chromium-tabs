// Copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE-chromium file.

#import "CTTabStripController.h"

#import <QuartzCore/QuartzCore.h>
#import "CTTabContents.h"
#import "CTBrowser.h"
#import "CTUtil.h"
#import "NSImage+CTAdditions.h"

#import <limits>
#import <string>

#import "NewTabButton.h"
#import "CTTabStripView.h"
#import "CTTabContentsController.h"
#import "CTTabController.h"
#import "CTTabStripModelObserverBridge.h"
#import "CTTabView.h"
#import "ThrobberView.h"
#import "CTTabStripModel.h"
#import "GTMNSAnimation+Duration.h"

NSString* const kTabStripNumberOfTabsChanged = @"kTabStripNumberOfTabsChanged";

namespace {
    
    // The images names used for different states of the new tab button.
    static NSImage* kNewTabHoverImage = nil;
    static NSImage* kNewTabImage = nil;
    static NSImage* kNewTabPressedImage = nil;
    
    // Image used to display default icon (when contents.hasIcon && !contents.icon)
    static NSImage* kDefaultIconImage = nil;
    
    // A value to indicate tab layout should use the full available width of the
    // view.
    const CGFloat kUseFullAvailableWidth = -1.0;
    
    // The amount by which tabs overlap.
    const CGFloat kTabOverlap = 20.0;
    
    // The width and height for a tab's icon.
    const CGFloat kIconWidthAndHeight = 16.0;
    
    // The amount by which the new tab button is offset (from the tabs).
    const CGFloat kNewTabButtonOffset = 8.0;
    
    // The amount by which to shrink the tab strip (on the right) when the
    // incognito badge is present.
    const CGFloat kIncognitoBadgeTabStripShrink = 18;
    
    // Time (in seconds) in which tabs animate to their final position.
    const NSTimeInterval kAnimationDuration = 0.125;
    
    // Helper class for doing NSAnimationContext calls that takes a bool to disable
    // all the work.  Useful for code that wants to conditionally animate.
    class ScopedNSAnimationContextGroup {
    public:
        explicit ScopedNSAnimationContextGroup(bool animate)
        : animate_(animate) {
            if (animate_) {
                [NSAnimationContext beginGrouping];
            }
        }
        
        ~ScopedNSAnimationContextGroup() {
            if (animate_) {
                [NSAnimationContext endGrouping];
            }
        }
        
        void SetCurrentContextDuration(NSTimeInterval duration) {
            if (animate_) {
                [[NSAnimationContext currentContext] gtm_setDuration:duration
                                                           eventMask:NSLeftMouseUpMask];
            }
        }
        
        void SetCurrentContextShortestDuration() {
            if (animate_) {
                // The minimum representable time interval.  This used to stop an
                // in-progress animation as quickly as possible.
                const NSTimeInterval kMinimumTimeInterval =
                std::numeric_limits<NSTimeInterval>::min();
                // Directly set the duration to be short, avoiding the Steve slowmotion
                // ettect the gtm_setDuration: provides.
                [[NSAnimationContext currentContext] setDuration:kMinimumTimeInterval];
            }
        }
        
    private:
        bool animate_;
        DISALLOW_COPY_AND_ASSIGN(ScopedNSAnimationContextGroup);
    };
    
}  // namespace

@interface CTTabStripController (Private)
- (void)installTrackingArea;
- (void)addSubviewToPermanentList:(NSView*)aView;
- (void)regenerateSubviewList;
- (NSInteger)indexForContentsView:(NSView*)view;
- (void)updateFavIconForContents:(CTTabContents*)contents
                         atIndex:(NSInteger)modelIndex;
- (void)layoutTabsWithAnimation:(BOOL)animate
             regenerateSubviews:(BOOL)doUpdate;
- (void)animationDidStopForController:(CTTabController*)controller
                             finished:(BOOL)finished;
- (NSInteger)indexFromModelIndex:(NSInteger)index;
- (NSInteger)numberOfOpenTabs;
- (NSInteger)numberOfOpenMiniTabs;
- (NSInteger)numberOfOpenNonMiniTabs;
- (void)mouseMoved:(NSEvent*)event;
- (void)setTabTrackingAreasEnabled:(BOOL)enabled;
- (void)setNewTabButtonHoverState:(BOOL)showHover;
@end

// A simple view class that prevents the Window Server from dragging the area
// behind tabs. Sometimes core animation confuses it. Unfortunately, it can also
// falsely pick up clicks during rapid tab closure, so we have to account for
// that.
@interface TabStripControllerDragBlockingView : NSView {
    CTTabStripController* controller_;  // weak; owns us
}

- (id)initWithFrame:(NSRect)frameRect
         controller:(CTTabStripController*)controller;
@end

@implementation TabStripControllerDragBlockingView
- (BOOL)mouseDownCanMoveWindow {return NO;}
- (void)drawRect:(NSRect)rect {}

- (id)initWithFrame:(NSRect)frameRect
         controller:(CTTabStripController*)controller {
    if ((self = [super initWithFrame:frameRect]))
        controller_ = controller;
    return self;
}

// In "rapid tab closure" mode (i.e., the user is clicking close tab buttons in
// rapid succession), the animations confuse Cocoa's hit testing (which appears
// to use cached results, among other tricks), so this view can somehow end up
// getting a mouse down event. Thus we do an explicit hit test during rapid tab
// closure, and if we find that we got a mouse down we shouldn't have, we send
// it off to the appropriate view.
- (void)mouseDown:(NSEvent*)event {
    if ([controller_ inRapidClosureMode]) {
        NSView* superview = [self superview];
        NSPoint hitLocation =
        [[superview superview] convertPoint:[event locationInWindow]
                                   fromView:nil];
        NSView* hitView = [superview hitTest:hitLocation];
        if (hitView != self) {
            [hitView mouseDown:event];
            return;
        }
    }
    [super mouseDown:event];
}
@end

#pragma mark -

// A delegate, owned by the CAAnimation system, that is alerted when the
// animation to close a tab is completed. Calls back to the given tab strip
// to let it know that |controller_| is ready to be removed from the model.
// Since we only maintain weak references, the tab strip must call -invalidate:
// to prevent the use of dangling pointers.
@interface TabCloseAnimationDelegate : NSObject {
@private
    CTTabStripController* strip_;  // weak; owns us indirectly
    CTTabController* controller_;  // weak
}

// Will tell |strip| when the animation for |controller|'s view has completed.
// These should not be nil, and will not be retained.
- (id)initWithTabStrip:(CTTabStripController*)strip
         tabController:(CTTabController*)controller;

// Invalidates this object so that no further calls will be made to
// |strip_|.  This should be called when |strip_| is released, to
// prevent attempts to call into the released object.
- (void)invalidate;

// CAAnimation delegate method
- (void)animationDidStop:(CAAnimation*)animation finished:(BOOL)finished;

@end

@implementation TabCloseAnimationDelegate

- (id)initWithTabStrip:(CTTabStripController*)strip
         tabController:(CTTabController*)controller {
    if (nil != (self = [super init])) {
        assert(strip && controller);
        strip_ = strip;
        controller_ = controller;
    }
    return self;
}

- (void)invalidate {
    strip_ = nil;
    controller_ = nil;
}

- (void)animationDidStop:(CAAnimation*)animation finished:(BOOL)finished {
    [strip_ animationDidStopForController:controller_ finished:finished];
}

@end

#pragma mark -

// In general, there is a one-to-one correspondence between TabControllers,
// TabViews, TabContentsControllers, and the CTTabContents in the TabStripModel.
// In the steady-state, the indices line up so an index coming from the model
// is directly mapped to the same index in the parallel arrays holding our
// views and controllers. This is also true when new tabs are created (even
// though there is a small period of animation) because the tab is present
// in the model while the CTTabView is animating into place. As a result, nothing
// special need be done to handle "new tab" animation.
//
// This all goes out the window with the "close tab" animation. The animation
// kicks off in |-tabDetachedWithContents:atIndex:| with the notification that
// the tab has been removed from the model. The simplest solution at this
// point would be to remove the views and controllers as well, however once
// the CTTabView is removed from the view list, the tab z-order code takes care of
// removing it from the tab strip and we'll get no animation. That means if
// there is to be any visible animation, the CTTabView needs to stay around until
// its animation is complete. In order to maintain consistency among the
// internal parallel arrays, this means all structures are kept around until
// the animation completes. At this point, though, the model and our internal
// structures are out of sync: the indices no longer line up. As a result,
// there is a concept of a "model index" which represents an index valid in
// the TabStripModel. During steady-state, the "model index" is just the same
// index as our parallel arrays (as above), but during tab close animations,
// it is different, offset by the number of tabs preceding the index which
// are undergoing tab closing animation. As a result, the caller needs to be
// careful to use the available conversion routines when accessing the internal
// parallel arrays (e.g., -indexFromModelIndex:). Care also needs to be taken
// during tab layout to ignore closing tabs in the total width calculations and
// in individual tab positioning (to avoid moving them right back to where they
// were).
//
// In order to prevent actions being taken on tabs which are closing, the tab
// itself gets marked as such so it no longer will send back its select action
// or allow itself to be dragged. In addition, drags on the tab strip as a
// whole are disabled while there are tabs closing.

@implementation CTTabStripController {
    // YES if tabs are to be laid out vertically instead of horizontally.
    BOOL verticalLayout_;
    CTTabContents* currentTab_;  // weak, tab for which we're showing state
    CTTabStripView* tabStripView_;
    NSView* switchView_;  // weak
    NSView* dragBlockingView_;  // avoid bad window server drags
    NewTabButton* newTabButton_;  // weak, obtained from the nib.
    
    // Tracks the newTabButton_ for rollovers.
    NSTrackingArea* newTabTrackingArea_;
    CTTabStripModelObserverBridge* bridge_;
    CTBrowser *browser_;  // weak
    CTTabStripModel* tabStripModel_;  // weak
    CTTabStripModel2* tabStripModel2_;
    
    // YES if the new tab button is currently displaying the hover image (if the
    // mouse is currently over the button).
    BOOL newTabButtonShowingHoverImage_;
    
    // Access to the TabContentsControllers (which own the parent view
    // for the toolbar and associated tab contents) given an index. Call
    // |indexFromModelIndex:| to convert a |tabStripModel_| index to a
    // |tabContentsArray_| index. Do NOT assume that the indices of
    // |tabStripModel_| and this array are identical, this is e.g. not true while
    // tabs are animating closed (closed tabs are removed from |tabStripModel_|
    // immediately, but from |tabContentsArray_| only after their close animation
    // has completed).
    NSMutableArray* tabContentsArray_;
    // An array of TabControllers which manage the actual tab views. See note
    // above |tabContentsArray_|. |tabContentsArray_| and |tabArray_| always
    // contain objects belonging to the same tabs at the same indices.
    NSMutableArray* tabArray_;
    
    // Set of TabControllers that are currently animating closed.
    NSMutableSet* closingControllers_;
    
    // These values are only used during a drag, and override tab positioning.
    CTTabView* placeholderTab_;  // weak. Tab being dragged
    NSRect placeholderFrame_;  // Frame to use
    CGFloat placeholderStretchiness_; // Vertical force shown by streching tab.
    NSRect droppedTabFrame_;  // Initial frame of a dropped tab, for animation.
    // Frame targets for all the current views.
    // target frames are used because repeated requests to [NSView animator].
    // aren't coalesced, so we store frames to avoid redundant calls.
    NSMutableDictionary* targetFrames_;
    NSRect newTabTargetFrame_;
    // If YES, do not show the new tab button during layout.
    BOOL forceNewTabButtonHidden_;
    // YES if we've successfully completed the initial layout. When this is
    // NO, we probably don't want to do any animation because we're just coming
    // into being.
    BOOL initialLayoutComplete_;
    
    // Width available for resizing the tabs (doesn't include the new tab
    // button). Used to restrict the available width when closing many tabs at
    // once to prevent them from resizing to fit the full width. If the entire
    // width should be used, this will have a value of |kUseFullAvailableWidth|.
    float availableResizeWidth_;
    // A tracking area that's the size of the tab strip used to be notified
    // when the mouse moves in the tab strip
    NSTrackingArea* trackingArea_;
    CTTabView* hoveredTab_;  // weak. Tab that the mouse is hovering over
    
    // Array of subviews which are permanent (and which should never be removed),
    // such as the new-tab button, but *not* the tabs themselves.
    NSMutableArray* permanentSubviews_;
    
    // The default favicon, so we can use one copy for all buttons.
    NSImage* defaultFavIcon_;
    
    // The amount by which to indent the tabs on the left (to make room for the
    // red/yellow/green buttons).
    CGFloat indentForControls_;
    
    // Is the mouse currently inside the strip;
    BOOL mouseInside_;
}

@synthesize indentForControls = indentForControls_;

+ (void)initialize {
    kNewTabHoverImage = [NSImage imageInAppOrCTFrameworkNamed:@"newtab_h"];
    kNewTabImage = [NSImage imageInAppOrCTFrameworkNamed:@"newtab"];
    kNewTabPressedImage = [NSImage imageInAppOrCTFrameworkNamed:@"newtab_p"];
    kDefaultIconImage = [NSImage imageInAppOrCTFrameworkNamed:@"default-icon"];
}

- (id)initWithView:(CTTabStripView*)view
        switchView:(NSView*)switchView
           browser:(CTBrowser*)browser {
    assert(view && switchView && browser);
    if ((self = [super init])) {
        tabStripView_ = view;
        switchView_ = switchView;
        browser_ = browser;
        tabStripModel_ = [browser_ tabStripModel];
        tabStripModel2_ = [[CTTabStripModel2 alloc] initWithPointer:tabStripModel_];
        bridge_ = new CTTabStripModelObserverBridge(tabStripModel_, self);
        tabContentsArray_ = [[NSMutableArray alloc] init];
        tabArray_ = [[NSMutableArray alloc] init];
        
        // Important note: any non-tab subviews not added to |permanentSubviews_|
        // (see |-addSubviewToPermanentList:|) will be wiped out.
        permanentSubviews_ = [[NSMutableArray alloc] init];
        
        //ResourceBundle& rb = ResourceBundle::GetSharedInstance();
        defaultFavIcon_ = kDefaultIconImage;
        
        [self setIndentForControls:[[self class] defaultIndentForControls]];
        
        // TODO(viettrungluu): WTF? "For some reason, if the view is present in the
        // nib a priori, it draws correctly. If we create it in code and add it to
        // the tab view, it draws with all sorts of crazy artifacts."
        newTabButton_ = [view addTabButton];
        [self addSubviewToPermanentList:newTabButton_];
        [newTabButton_ setTarget:nil];
        [newTabButton_ setAction:@selector(commandDispatch:)];
        [newTabButton_ setTag:CTBrowserCommandNewTab];
        // Set the images from code because Cocoa fails to find them in our sub
        // bundle during tests.
        [newTabButton_ setImage:kNewTabImage];
        [newTabButton_ setAlternateImage:kNewTabPressedImage];
        newTabButtonShowingHoverImage_ = NO;
        newTabTrackingArea_ = 
        [[NSTrackingArea alloc] initWithRect:[newTabButton_ bounds]
                                     options:(NSTrackingMouseEnteredAndExited |
                                              NSTrackingActiveAlways)
                                       owner:self
                                    userInfo:nil];
        [newTabButton_ addTrackingArea:newTabTrackingArea_];
        targetFrames_ = [[NSMutableDictionary alloc] init];
        
        dragBlockingView_ = 
        [[TabStripControllerDragBlockingView alloc] initWithFrame:NSZeroRect
                                                       controller:self];
        [self addSubviewToPermanentList:dragBlockingView_];
        
        newTabTargetFrame_ = NSMakeRect(0, 0, 0, 0);
        availableResizeWidth_ = kUseFullAvailableWidth;
        
        closingControllers_ = [[NSMutableSet alloc] init];
        
        // Install the permanent subviews.
        [self regenerateSubviewList];
        
        // Watch for notifications that the tab strip view has changed size so
        // we can tell it to layout for the new size.
        [[NSNotificationCenter defaultCenter]
         addObserver:self
         selector:@selector(tabViewFrameChanged:)
         name:NSViewFrameDidChangeNotification
         object:tabStripView_];
        
        trackingArea_ = [[NSTrackingArea alloc]
                         initWithRect:NSZeroRect  // Ignored by NSTrackingInVisibleRect
                         options:NSTrackingMouseEnteredAndExited |
                         NSTrackingMouseMoved |
                         NSTrackingActiveAlways |
                         NSTrackingInVisibleRect
                         owner:self
                         userInfo:nil];
        [tabStripView_ addTrackingArea:trackingArea_];
        
        // Check to see if the mouse is currently in our bounds so we can
        // enable the tracking areas.  Otherwise we won't get hover states
        // or tab gradients if we load the window up under the mouse.
        NSPoint mouseLoc = [[view window] mouseLocationOutsideOfEventStream];
        mouseLoc = [view convertPoint:mouseLoc fromView:nil];
        if (NSPointInRect(mouseLoc, [view bounds])) {
            [self setTabTrackingAreasEnabled:YES];
            mouseInside_ = YES;
        }
        
        // Set accessibility descriptions. http://openradar.appspot.com/7496255
        [[newTabButton_ cell]
         accessibilitySetOverrideValue:@"New tab"
         forAttribute:NSAccessibilityDescriptionAttribute];
        
        // Controller may have been (re-)created by switching layout modes, which
        // means the tab model is already fully formed with tabs. Need to walk the
        // list and create the UI for each.
        const int existingTabCount = [tabStripModel2_ count];
        const CTTabContents* selection = [tabStripModel2_ selectedTabContents];
        for (int i = 0; i < existingTabCount; ++i) {
            CTTabContents* currentContents = [tabStripModel2_ tabContentsAtIndex:i];
            [self tabInsertedWithContents:currentContents
                                  atIndex:i
                             inForeground:NO];
            if (selection == currentContents) {
                // Must manually force a selection since the model won't send
                // selection messages in this scenario.
                [self tabSelectedWithContents:currentContents
                             previousContents:NULL
                                      atIndex:i
                                  userGesture:NO];
            }
        }
        // Don't lay out the tabs until after the controller has been fully
        // constructed. The |verticalLayout_| flag has not been initialized by
        // subclasses at this point, which would cause layout to potentially use
        // the wrong mode.
        if (existingTabCount) {
            [self performSelectorOnMainThread:@selector(layoutTabs)
                                   withObject:nil
                                waitUntilDone:NO];
        }
    }
    return self;
}

- (void)dealloc {
    if (trackingArea_)
        [tabStripView_ removeTrackingArea:trackingArea_];
    
    [newTabButton_ removeTrackingArea:newTabTrackingArea_];
    // Invalidate all closing animations so they don't call back to us after
    // we're gone.
    for (CTTabController* controller in closingControllers_) {
        NSView* view = [controller view];
        [[[view animationForKey:@"frameOrigin"] delegate] invalidate];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (CGFloat)defaultTabHeight {
    return 25.0;
}

+ (CGFloat)defaultIndentForControls {
    // Default indentation leaves enough room so tabs don't overlap with the
    // window controls.
    return 64.0;
}

// Finds the CTTabContentsController associated with the given index into the tab
// model and swaps out the sole child of the contentArea to display its
// contents.
- (void)swapInTabAtIndex:(NSInteger)modelIndex {
    assert(modelIndex >= 0 && modelIndex < [tabStripModel2_ count]);
    NSInteger index = [self indexFromModelIndex:modelIndex];
    CTTabContentsController* controller = [tabContentsArray_ objectAtIndex:index];
    
    // Resize the new view to fit the window. Calling |view| may lazily
    // instantiate the CTTabContentsController from the nib. Until we call
    // |-ensureContentsVisible|, the controller doesn't install the RWHVMac into
    // the view hierarchy. This is in order to avoid sending the renderer a
    // spurious default size loaded from the nib during the call to |-view|.
    NSView* newView = [controller view];
    NSRect frame = [switchView_ bounds];
    [newView setFrame:frame];
    [controller ensureContentsVisible];
    
    // Remove the old view from the view hierarchy. We know there's only one
    // child of |switchView_| because we're the one who put it there. There
    // may not be any children in the case of a tab that's been closed, in
    // which case there's no swapping going on.
    NSArray* subviews = [switchView_ subviews];
    if ([subviews count]) {
        NSView* oldView = [subviews objectAtIndex:0];
        [switchView_ replaceSubview:oldView with:newView];
    } else {
        [switchView_ addSubview:newView];
    }
    
    // Make sure the new tabs's sheets are visible (necessary when a background
    // tab opened a sheet while it was in the background and now becomes active).
    CTTabContents* newTab = [tabStripModel2_ tabContentsAtIndex:modelIndex];
    assert(newTab);
    // TODO: Possibly need to implement this for sheets to function properly
    /*if (newTab) {
     CTTabContents::ConstrainedWindowList::iterator it, end;
     end = newTab->constrained_window_end();
     NSWindowController* controller = [[newView window] windowController];
     assert([controller isKindOfClass:[CTBrowserWindowController class]]);
     
     for (it = newTab->constrained_window_begin(); it != end; ++it) {
     ConstrainedWindow* constrainedWindow = *it;
     static_cast<ConstrainedWindowMac*>(constrainedWindow)->Realize(
     static_cast<CTBrowserWindowController*>(controller));
     }
     }*/
}

// Create a new tab view and set its cell correctly so it draws the way we want
// it to. It will be sized and positioned by |-layoutTabs| so there's no need to
// set the frame here. This also creates the view as hidden, it will be
// shown during layout.
- (CTTabController*)newTab {
    CTTabController* controller = [[CTTabController alloc] init];
    [controller setTarget:self];
    [controller setAction:@selector(selectTab:)];
    [[controller view] setHidden:YES];
    
    return controller;
}

// (Private) Returns the number of open tabs in the tab strip. This is the
// number of TabControllers we know about (as there's a 1-to-1 mapping from
// these controllers to a tab) less the number of closing tabs.
- (NSInteger)numberOfOpenTabs {
    return static_cast<NSInteger>([tabStripModel2_ count]);
}

// (Private) Returns the number of open, mini-tabs.
- (NSInteger)numberOfOpenMiniTabs {
    // Ask the model for the number of mini tabs. Note that tabs which are in
    // the process of closing (i.e., whose controllers are in
    // |closingControllers_|) have already been removed from the model.
    return [tabStripModel2_ indexOfFirstNonMiniTab];
}

// (Private) Returns the number of open, non-mini tabs.
- (NSInteger)numberOfOpenNonMiniTabs {
    NSInteger number = [self numberOfOpenTabs] - [self numberOfOpenMiniTabs];
    DCHECK_GE(number, 0);
    return number;
}

// Given an index into the tab model, returns the index into the tab controller
// or tab contents controller array accounting for tabs that are currently
// closing. For example, if there are two tabs in the process of closing before
// |index|, this returns |index| + 2. If there are no closing tabs, this will
// return |index|.
- (NSInteger)indexFromModelIndex:(NSInteger)index {
    assert(index >= 0);
    if (index < 0)
        return index;
    
    NSInteger i = 0;
    for (CTTabController* controller in tabArray_) {
        if ([closingControllers_ containsObject:controller]) {
            assert([(CTTabView*)[controller view] isClosing]);
            ++index;
        }
        if (i == index)  // No need to check anything after, it has no effect.
            break;
        ++i;
    }
    return index;
}


// Returns the index of the subview |view|. Returns -1 if not present. Takes
// closing tabs into account such that this index will correctly match the tab
// model. If |view| is in the process of closing, returns -1, as closing tabs
// are no longer in the model.
- (NSInteger)modelIndexForTabView:(NSView*)view {
    NSInteger index = 0;
    for (CTTabController* current in tabArray_) {
        // If |current| is closing, skip it.
        if ([closingControllers_ containsObject:current])
            continue;
        else if ([current view] == view)
            return index;
        ++index;
    }
    return -1;
}

// Returns the index of the contents subview |view|. Returns -1 if not present.
// Takes closing tabs into account such that this index will correctly match the
// tab model. If |view| is in the process of closing, returns -1, as closing
// tabs are no longer in the model.
- (NSInteger)modelIndexForContentsView:(NSView*)view {
    NSInteger index = 0;
    NSInteger i = 0;
    for (CTTabContentsController* current in tabContentsArray_) {
        // If the CTTabController corresponding to |current| is closing, skip it.
        CTTabController* controller = [tabArray_ objectAtIndex:i];
        if ([closingControllers_ containsObject:controller]) {
            ++i;
            continue;
        } else if ([current view] == view) {
            return index;
        }
        ++index;
        ++i;
    }
    return -1;
}


// Returns the view at the given index, using the array of TabControllers to
// get the associated view. Returns nil if out of range.
- (NSView*)viewAtIndex:(NSUInteger)index {
    if (index >= [tabArray_ count])
        return NULL;
    return [[tabArray_ objectAtIndex:index] view];
}

- (NSUInteger)viewsCount {
    return [tabArray_ count];
}

// Called when the user clicks a tab. Tell the model the selection has changed,
// which feeds back into us via a notification.
- (void)selectTab:(id)sender {
    assert([sender isKindOfClass:[NSView class]]);
    int index = [self modelIndexForTabView:sender];
    if ([tabStripModel2_ containsIndex:index]) {
        [tabStripModel2_ selectTabContentsAtIndex:index userGesture:YES];
    }
}

// Called when the user closes a tab. Asks the model to close the tab. |sender|
// is the CTTabView that is potentially going away.
- (void)closeTab:(id)sender {
    assert([sender isKindOfClass:[CTTabView class]]);
    if ([hoveredTab_ isEqual:sender]) {
        hoveredTab_ = nil;
    }
    
    NSInteger index = [self modelIndexForTabView:sender];
    if (![tabStripModel2_ containsIndex:index])
        return;
    
    const NSInteger numberOfOpenTabs = [self numberOfOpenTabs];
    if (numberOfOpenTabs > 1) {
        bool isClosingLastTab = index == numberOfOpenTabs - 1;
        if (!isClosingLastTab) {
            // Limit the width available for laying out tabs so that tabs are not
            // resized until a later time (when the mouse leaves the tab strip).
            // TODO(pinkerton): re-visit when handling tab overflow.
            // http://crbug.com/188
            NSView* penultimateTab = [self viewAtIndex:numberOfOpenTabs - 2];
            availableResizeWidth_ = NSMaxX([penultimateTab frame]);
        } else {
            // If the rightmost tab is closed, change the available width so that
            // another tab's close button lands below the cursor (assuming the tabs
            // are currently below their maximum width and can grow).
            NSView* lastTab = [self viewAtIndex:numberOfOpenTabs - 1];
            availableResizeWidth_ = NSMaxX([lastTab frame]);
        }
        [tabStripModel2_ closeTabContentsAtIndex:index options: CLOSE_USER_GESTURE | CLOSE_CREATE_HISTORICAL_TAB];
    } else {
        // Use the standard window close if this is the last tab
        // this prevents the tab from being removed from the model until after
        // the window dissapears
        [[tabStripView_ window] performClose:nil];
    }
}

- (void)insertPlaceholderForTab:(CTTabView*)tab
                          frame:(NSRect)frame
                  yStretchiness:(CGFloat)yStretchiness {
    placeholderTab_ = tab;
    placeholderFrame_ = frame;
    placeholderStretchiness_ = yStretchiness;
    [self layoutTabsWithAnimation:initialLayoutComplete_ regenerateSubviews:NO];
}

- (BOOL)isTabFullyVisible:(CTTabView*)tab {
    NSRect frame = [tab frame];
    return NSMinX(frame) >= [self indentForControls] &&
    NSMaxX(frame) <= NSMaxX([tabStripView_ frame]);
}


- (void)setShowsNewTabButton:(BOOL)show {
    if (!!forceNewTabButtonHidden_ == !!show) {
        forceNewTabButtonHidden_ = !show;
        [newTabButton_ setHidden:forceNewTabButtonHidden_];
    }
}


- (BOOL)showsNewTabButton {
    return !forceNewTabButtonHidden_ && newTabButton_;
}

// Lay out all tabs in the order of their TabContentsControllers, which matches
// the ordering in the TabStripModel. This call isn't that expensive, though
// it is O(n) in the number of tabs. Tabs will animate to their new position
// if the window is visible and |animate| is YES.
// TODO(pinkerton): Note this doesn't do too well when the number of min-sized
// tabs would cause an overflow. http://crbug.com/188
- (void)layoutTabsWithAnimation:(BOOL)animate
             regenerateSubviews:(BOOL)doUpdate {
    assert([NSThread isMainThread]);
    if (![tabArray_ count])
        return;
    
    const CGFloat kMaxTabWidth = [CTTabController maxTabWidth];
    const CGFloat kMinTabWidth = [CTTabController minTabWidth];
    const CGFloat kMinSelectedTabWidth = [CTTabController minSelectedTabWidth];
    const CGFloat kMiniTabWidth = [CTTabController miniTabWidth];
    const CGFloat kAppTabWidth = [CTTabController appTabWidth];
    
    NSRect enclosingRect = NSZeroRect;
    ScopedNSAnimationContextGroup mainAnimationGroup(animate);
    mainAnimationGroup.SetCurrentContextDuration(kAnimationDuration);
    
    // Update the current subviews and their z-order if requested.
    if (doUpdate)
        [self regenerateSubviewList];
    
    // Compute the base width of tabs given how much room we're allowed. Note that
    // mini-tabs have a fixed width. We may not be able to use the entire width
    // if the user is quickly closing tabs. This may be negative, but that's okay
    // (taken care of by |MAX()| when calculating tab sizes).
    CGFloat availableSpace = 0;
    if (verticalLayout_) {
        availableSpace = NSHeight([tabStripView_ bounds]);
    } else {
        if ([self inRapidClosureMode]) {
            availableSpace = availableResizeWidth_;
        } else {
            availableSpace = NSWidth([tabStripView_ frame]);
            // Account for the new tab button and the incognito badge.
            if (forceNewTabButtonHidden_) {
                availableSpace -= 5.0; // margin
            } else {
                availableSpace -= NSWidth([newTabButton_ frame]) + kNewTabButtonOffset;
            }
            /*if (browser_->profile()->IsOffTheRecord())
             availableSpace -= kIncognitoBadgeTabStripShrink;*/
        }
        availableSpace -= [self indentForControls];
    }
    
    // This may be negative, but that's okay (taken care of by |MAX()| when
    // calculating tab sizes). "mini" tabs in horizontal mode just get a special
    // section, they don't change size.
    CGFloat availableSpaceForNonMini = availableSpace;
    if (!verticalLayout_) {
        availableSpaceForNonMini -=
        [self numberOfOpenMiniTabs] * (kMiniTabWidth - kTabOverlap);
    }
    
    // Initialize |nonMiniTabWidth| in case there aren't any non-mini-tabs; this
    // value shouldn't actually be used.
    CGFloat nonMiniTabWidth = kMaxTabWidth;
    const NSInteger numberOfOpenNonMiniTabs = [self numberOfOpenNonMiniTabs];
    if (!verticalLayout_ && numberOfOpenNonMiniTabs) {
        // Find the width of a non-mini-tab. This only applies to horizontal
        // mode. Add in the amount we "get back" from the tabs overlapping.
        availableSpaceForNonMini += (numberOfOpenNonMiniTabs - 1) * kTabOverlap;
        
        // Divide up the space between the non-mini-tabs.
        nonMiniTabWidth = availableSpaceForNonMini / numberOfOpenNonMiniTabs;
        
        // Clamp the width between the max and min.
        nonMiniTabWidth = MAX(MIN(nonMiniTabWidth, kMaxTabWidth), kMinTabWidth);
    }
    
    BOOL visible = [[tabStripView_ window] isVisible];
    
    CGFloat offset = [self indentForControls];
    NSUInteger i = 0;
    bool hasPlaceholderGap = false;
    for (CTTabController* tab in tabArray_) {
        // Ignore a tab that is going through a close animation.
        if ([closingControllers_ containsObject:tab])
            continue;
        
        BOOL isPlaceholder = [[tab view] isEqual:placeholderTab_];
        NSRect tabFrame = [[tab view] frame];
        tabFrame.size.height = [[self class] defaultTabHeight] + 1;
        if (verticalLayout_) {
            tabFrame.origin.y = availableSpace - tabFrame.size.height - offset;
            tabFrame.origin.x = 0;
        } else {
            tabFrame.origin.y = 0;
            tabFrame.origin.x = offset;
        }
        // If the tab is hidden, we consider it a new tab. We make it visible
        // and animate it in.
        BOOL newTab = [[tab view] isHidden];
        if (newTab) {
            [[tab view] setHidden:NO];
        }
        
        if (isPlaceholder) {
            // Move the current tab to the correct location instantly.
            // We need a duration or else it doesn't cancel an inflight animation.
            ScopedNSAnimationContextGroup localAnimationGroup(animate);
            localAnimationGroup.SetCurrentContextShortestDuration();
            if (verticalLayout_)
                tabFrame.origin.y = availableSpace - tabFrame.size.height - offset;
            else
                tabFrame.origin.x = placeholderFrame_.origin.x;
            // TODO(alcor): reenable this
            //tabFrame.size.height += 10.0 * placeholderStretchiness_;
            id target = animate ? [[tab view] animator] : [tab view];
            [target setFrame:tabFrame];
            
            // Store the frame by identifier to aviod redundant calls to animator.
            NSValue* identifier = [NSValue valueWithPointer:(__bridge const void*)[tab view]];
            [targetFrames_ setObject:[NSValue valueWithRect:tabFrame]
                              forKey:identifier];
            continue;
        }
        
        if (placeholderTab_ && !hasPlaceholderGap) {
            const CGFloat placeholderMin =
            verticalLayout_ ? NSMinY(placeholderFrame_) :
            NSMinX(placeholderFrame_);
            if (verticalLayout_) {
                if (NSMidY(tabFrame) > placeholderMin) {
                    hasPlaceholderGap = true;
                    offset += NSHeight(placeholderFrame_);
                    tabFrame.origin.y = availableSpace - tabFrame.size.height - offset;
                }
            } else {
                // If the left edge is to the left of the placeholder's left, but the
                // mid is to the right of it slide over to make space for it.
                if (NSMidX(tabFrame) > placeholderMin) {
                    hasPlaceholderGap = true;
                    offset += NSWidth(placeholderFrame_);
                    offset -= kTabOverlap;
                    tabFrame.origin.x = offset;
                }
            }
        }
        
        // Set the width. Selected tabs are slightly wider when things get really
        // small and thus we enforce a different minimum width.
        tabFrame.size.width = [tab mini] ?
        ([tab app] ? kAppTabWidth : kMiniTabWidth) : nonMiniTabWidth;
        if ([tab selected])
            tabFrame.size.width = MAX(tabFrame.size.width, kMinSelectedTabWidth);
        
        // Animate a new tab in by putting it below the horizon unless told to put
        // it in a specific location (i.e., from a drop).
        // TODO(pinkerton): figure out vertical tab animations.
        if (newTab && visible && animate) {
            if (NSEqualRects(droppedTabFrame_, NSZeroRect)) {
                [[tab view] setFrame:NSOffsetRect(tabFrame, 0, -NSHeight(tabFrame))];
            } else {
                [[tab view] setFrame:droppedTabFrame_];
                droppedTabFrame_ = NSZeroRect;
            }
        }
        
        // Check the frame by identifier to avoid redundant calls to animator.
        id frameTarget = visible && animate ? [[tab view] animator] : [tab view];
        NSValue* identifier = [NSValue valueWithPointer:(__bridge const void*)[tab view]];
        NSValue* oldTargetValue = [targetFrames_ objectForKey:identifier];
        if (!oldTargetValue ||
            !NSEqualRects([oldTargetValue rectValue], tabFrame)) {
            [frameTarget setFrame:tabFrame];
            [targetFrames_ setObject:[NSValue valueWithRect:tabFrame]
                              forKey:identifier];
        }
        
        enclosingRect = NSUnionRect(tabFrame, enclosingRect);
        
        if (verticalLayout_) {
            offset += NSHeight(tabFrame);
        } else {
            offset += NSWidth(tabFrame);
            offset -= kTabOverlap;
        }
        i++;
    }
    
    // Hide the new tab button if we're explicitly told to. It may already
    // be hidden, doing it again doesn't hurt. Otherwise position it
    // appropriately, showing it if necessary.
    if (forceNewTabButtonHidden_) {
        [newTabButton_ setHidden:YES];
    } else {
        NSRect newTabNewFrame = [newTabButton_ frame];
        // We've already ensured there's enough space for the new tab button
        // so we don't have to check it against the available space. We do need
        // to make sure we put it after any placeholder.
        newTabNewFrame.origin = NSMakePoint(offset, 0);
        newTabNewFrame.origin.x = MAX(newTabNewFrame.origin.x,
                                      NSMaxX(placeholderFrame_)) +
        kNewTabButtonOffset;
        if ([tabContentsArray_ count])
            [newTabButton_ setHidden:NO];
        
        if (!NSEqualRects(newTabTargetFrame_, newTabNewFrame)) {
            // Set the new tab button image correctly based on where the cursor is.
            NSWindow* window = [tabStripView_ window];
            NSPoint currentMouse = [window mouseLocationOutsideOfEventStream];
            currentMouse = [tabStripView_ convertPoint:currentMouse fromView:nil];
            
            BOOL shouldShowHover = [newTabButton_ pointIsOverButton:currentMouse];
            [self setNewTabButtonHoverState:shouldShowHover];
            
            // Move the new tab button into place. We want to animate the new tab
            // button if it's moving to the left (closing a tab), but not when it's
            // moving to the right (inserting a new tab). If moving right, we need
            // to use a very small duration to make sure we cancel any in-flight
            // animation to the left.
            if (visible && animate) {
                ScopedNSAnimationContextGroup localAnimationGroup(true);
                BOOL movingLeft = NSMinX(newTabNewFrame) < NSMinX(newTabTargetFrame_);
                if (!movingLeft) {
                    localAnimationGroup.SetCurrentContextShortestDuration();
                }
                [[newTabButton_ animator] setFrame:newTabNewFrame];
                newTabTargetFrame_ = newTabNewFrame;
            } else {
                [newTabButton_ setFrame:newTabNewFrame];
                newTabTargetFrame_ = newTabNewFrame;
            }
        }
    }
    
    [dragBlockingView_ setFrame:enclosingRect];
    
    // Mark that we've successfully completed layout of at least one tab.
    initialLayoutComplete_ = YES;
}

// When we're told to layout from the public API we usually want to animate,
// except when it's the first time.
- (void)layoutTabs {
    [self layoutTabsWithAnimation:initialLayoutComplete_ regenerateSubviews:YES];
}

// Handles setting the title of the tab based on the given |contents|. Uses
// a canned string if |contents| is NULL.
- (void)setTabTitle:(NSViewController*)tab withContents:(CTTabContents*)contents {
    NSString* titleString = nil;
    if (contents)
        titleString = contents.title;
    if (!titleString || ![titleString length])
        titleString = L10n(@"New Tab");
    [tab setTitle:titleString];
}

// Called when a notification is received from the model to insert a new tab
// at |modelIndex|.
- (void)tabInsertedWithContents:(CTTabContents*)contents
                        atIndex:(NSInteger)modelIndex
                   inForeground:(bool)inForeground {
    assert(contents);
    assert(modelIndex == CTTabStripModel::kNoTab || [tabStripModel2_ containsIndex:modelIndex]);
    
    // Take closing tabs into account.
    NSInteger index = [self indexFromModelIndex:modelIndex];
    
    // Make a new tab. Load the contents of this tab from the nib and associate
    // the new controller with |contents| so it can be looked up later.
    CTTabContentsController* contentsController =
    [browser_ createTabContentsControllerWithContents:contents];
    [tabContentsArray_ insertObject:contentsController atIndex:index];
    
    // Make a new tab and add it to the strip. Keep track of its controller.
    CTTabController* newController = [self newTab];
    [newController setMini:[tabStripModel2_ isMiniTabAtIndex:modelIndex]];
    [newController setPinned:[tabStripModel2_ isTabPinnedAtIndex:modelIndex]];
    [newController setApp:[tabStripModel2_ isAppTabAtIndex:modelIndex]];
    [tabArray_ insertObject:newController atIndex:index];
    NSView* newView = [newController view];
    
    // Set the originating frame to just below the strip so that it animates
    // upwards as it's being initially layed out. Oddly, this works while doing
    // something similar in |-layoutTabs| confuses the window server.
    [newView setFrame:NSOffsetRect([newView frame],
                                   0, -[[self class] defaultTabHeight])];
    
    [self setTabTitle:newController withContents:contents];
    
    // If a tab is being inserted, we can again use the entire tab strip width
    // for layout.
    availableResizeWidth_ = kUseFullAvailableWidth;
    
    // We don't need to call |-layoutTabs| if the tab will be in the foreground
    // because it will get called when the new tab is selected by the tab model.
    // Whenever |-layoutTabs| is called, it'll also add the new subview.
    if (!inForeground) {
        [self layoutTabs];
    }
    
    // During normal loading, we won't yet have a favicon and we'll get
    // subsequent state change notifications to show the throbber, but when we're
    // dragging a tab out into a new window, we have to put the tab's favicon
    // into the right state up front as we won't be told to do it from anywhere
    // else.
    [self updateFavIconForContents:contents atIndex:modelIndex];
    
    // Send a broadcast that the number of tabs have changed.
    [[NSNotificationCenter defaultCenter]
     postNotificationName:kTabStripNumberOfTabsChanged
     object:self];
}

// Called when a notification is received from the model to select a particular
// tab. Swaps in the toolbar and content area associated with |newContents|.
- (void)tabSelectedWithContents:(CTTabContents*)newContents
               previousContents:(CTTabContents*)oldContents
                        atIndex:(NSInteger)modelIndex
                    userGesture:(bool)wasUserGesture {
    // Take closing tabs into account.
    NSInteger index = [self indexFromModelIndex:modelIndex];
    
    if (oldContents) {
        int oldModelIndex = [tabStripModel2_ indexOfTabContents:oldContents];
        if (oldModelIndex != -1) {  // When closing a tab, the old tab may be gone.
            NSInteger oldIndex = [self indexFromModelIndex:oldModelIndex];
            CTTabContentsController* oldController =
            [tabContentsArray_ objectAtIndex:oldIndex];
            [oldController willResignSelectedTab];
        }
    }
    
    // De-select all other tabs and select the new tab.
    int i = 0;
    for (CTTabController* current in tabArray_) {
        [current setSelected:(i == index) ? YES : NO];
        ++i;
    }
    
    // Tell the new tab contents it is about to become the selected tab. Here it
    // can do things like make sure the toolbar is up to date.
    CTTabContentsController *newController =
    [tabContentsArray_ objectAtIndex:index];
    [newController willBecomeSelectedTab];
    
    // Relayout for new tabs and to let the selected tab grow to be larger in
    // size than surrounding tabs if the user has many. This also raises the
    // selected tab to the top.
    [self layoutTabs];
    
    // Swap in the contents for the new tab.
    [self swapInTabAtIndex:modelIndex];
    
    if (newContents) {
        // TODO: if [<parent window> isMiniaturized] or if app is hidden the tab is
        // not visible
        newContents.isVisible = oldContents.isVisible;
        newContents.isSelected = YES;
    }
    if (oldContents) {
        oldContents.isVisible = NO;
        oldContents.isSelected = NO;
    }
}

// Remove all knowledge about this tab and its associated controller, and remove
// the view from the strip.
- (void)removeTab:(CTTabController*)controller {
    NSUInteger index = [tabArray_ indexOfObject:controller];
    
    // Release the tab contents controller so those views get destroyed. This
    // will remove all the tab content Cocoa views from the hierarchy. A
    // subsequent "select tab" notification will follow from the model. To
    // tell us what to swap in in its absence.
    [tabContentsArray_ removeObjectAtIndex:index];
    
    // Remove the view from the tab strip.
    NSView* tab = [controller view];
    [tab removeFromSuperview];
    
    // Remove ourself as an observer.
    [[NSNotificationCenter defaultCenter]
     removeObserver:self
     name:NSViewDidUpdateTrackingAreasNotification
     object:tab];
    
    // Clear the tab controller's target.
    // TODO(viettrungluu): [crbug.com/23829] Find a better way to handle the tab
    // controller's target.
    [controller setTarget:nil];
    
    if ([hoveredTab_ isEqual:tab])
        hoveredTab_ = nil;
    
    NSValue* identifier = [NSValue valueWithPointer:(__bridge const void*)tab];
    [targetFrames_ removeObjectForKey:identifier];
    
    // Once we're totally done with the tab, delete its controller
    [tabArray_ removeObjectAtIndex:index];
}

// Called by the CAAnimation delegate when the tab completes the closing
// animation.
- (void)animationDidStopForController:(CTTabController*)controller
                             finished:(BOOL)finished {
    [closingControllers_ removeObject:controller];
    [self removeTab:controller];
}

// Save off which CTTabController is closing and tell its view's animator
// where to move the tab to. Registers a delegate to call back when the
// animation is complete in order to remove the tab from the model.
- (void)startClosingTabWithAnimation:(CTTabController*)closingTab {
    assert([NSThread isMainThread]);
    // Save off the controller into the set of animating tabs. This alerts
    // the layout method to not do anything with it and allows us to correctly
    // calculate offsets when working with indices into the model.
    [closingControllers_ addObject:closingTab];
    
    // Mark the tab as closing. This prevents it from generating any drags or
    // selections while it's animating closed.
    [(CTTabView*)[closingTab view] setClosing:YES];
    
    // Register delegate (owned by the animation system).
    NSView* tabView = [closingTab view];
    CAAnimation* animation = [[tabView animationForKey:@"frameOrigin"] copy];
    TabCloseAnimationDelegate* delegate = 
    [[TabCloseAnimationDelegate alloc] initWithTabStrip:self
                                          tabController:closingTab];
    [animation setDelegate:delegate];  // Retains delegate.
    NSMutableDictionary* animationDictionary =
    [NSMutableDictionary dictionaryWithDictionary:[tabView animations]];
    [animationDictionary setObject:animation forKey:@"frameOrigin"];
    [tabView setAnimations:animationDictionary];
    
    // Periscope down! Animate the tab.
    NSRect newFrame = [tabView frame];
    newFrame = NSOffsetRect(newFrame, 0, -newFrame.size.height);
    ScopedNSAnimationContextGroup animationGroup(true);
    animationGroup.SetCurrentContextDuration(kAnimationDuration);
    [[tabView animator] setFrame:newFrame];
}

// Called when a notification is received from the model that the given tab
// has gone away. Start an animation then force a layout to put everything
// in motion.
- (void)tabDetachedWithContents:(CTTabContents*)contents
                        atIndex:(NSInteger)modelIndex {
    // Take closing tabs into account.
    NSInteger index = [self indexFromModelIndex:modelIndex];
    
    CTTabController* tab = [tabArray_ objectAtIndex:index];
    if ([tabStripModel2_ count] > 0) {
        [self startClosingTabWithAnimation:tab];
        [self layoutTabs];
    } else {
        [self removeTab:tab];
    }
    
    // Does nothing, purely for consistency with the windows/linux code.
    //[self updateDevToolsForContents:NULL];
    
    // Send a broadcast that the number of tabs have changed.
    [[NSNotificationCenter defaultCenter]
     postNotificationName:kTabStripNumberOfTabsChanged
     object:self];
}

// A helper routine for creating an NSImageView to hold the fav icon or app icon
// for |contents|.
- (NSImageView*)iconImageViewForContents:(CTTabContents*)contents {
    NSImage* image = contents.icon;
    // Either we don't have a valid favicon or there was some issue converting it
    // from an SkBitmap. Either way, just show the default.
    if (!image)
        image = defaultFavIcon_;
    NSRect frame = NSMakeRect(0, 0, kIconWidthAndHeight, kIconWidthAndHeight);
    NSImageView* view = [[NSImageView alloc] initWithFrame:frame];
    //DLOG_EXPR(image);
    [view setImage:image];
    return view;
}

// Updates the current loading state, replacing the icon view with a favicon,
// a throbber, the default icon, or nothing at all.
- (void)updateFavIconForContents:(CTTabContents*)contents
                         atIndex:(NSInteger)modelIndex {
    if (!contents)
        return;
    
    static NSImage* throbberWaitingImage = nil;
    static NSImage* throbberLoadingImage = nil;
    static NSImage* sadFaviconImage = nil;
    if (throbberWaitingImage == nil) {
        throbberWaitingImage =
        [NSImage imageInAppOrCTFrameworkNamed:@"throbber_waiting"];
        assert(throbberWaitingImage);
        throbberLoadingImage =
        [NSImage imageInAppOrCTFrameworkNamed:@"throbber"];
        assert(throbberLoadingImage);
        sadFaviconImage =
        [NSImage imageInAppOrCTFrameworkNamed:@"sadfavicon"];
        assert(sadFaviconImage);
    }
    
    // Take closing tabs into account.
    NSInteger index = [self indexFromModelIndex:modelIndex];
    
    CTTabController* tabController = [tabArray_ objectAtIndex:index];
    
    // Since the tab is loading, it cannot be phantom any more.
    if ([tabController phantom]) {
        [tabController setPhantom:NO];
        [[tabController view] setNeedsDisplay:YES];
    }
    
    bool oldHasIcon = [tabController iconView] != nil;
    bool newHasIcon = contents.hasIcon || [tabStripModel2_ isMiniTabAtIndex:modelIndex];  // Always show icon if mini.
    
    CTTabLoadingState oldState = [tabController loadingState];
    CTTabLoadingState newState = CTTabLoadingStateDone;
    NSImage* throbberImage = nil;
    if (contents.isCrashed) {
        newState = CTTabLoadingStateCrashed;
        newHasIcon = true;
    } else if (contents.isWaitingForResponse) {
        newState = CTTabLoadingStateWaiting;
        throbberImage = throbberWaitingImage;
    } else if (contents.isLoading) {
        newState = CTTabLoadingStateLoading;
        throbberImage = throbberLoadingImage;
    }
    
    if (oldState != newState)
        [tabController setLoadingState:newState];
    
    // While loading, this function is called repeatedly with the same state.
    // To avoid expensive unnecessary view manipulation, only make changes when
    // the state is actually changing.  When loading is complete
    // (CTTabLoadingStateDone), every call to this function is significant.
    if (newState == CTTabLoadingStateDone || oldState != newState ||
        oldHasIcon != newHasIcon) {
        NSView* iconView = nil;
        if (newHasIcon) {
            if (newState == CTTabLoadingStateDone) {
                iconView = [self iconImageViewForContents:contents];
            } else if (newState == CTTabLoadingStateCrashed) {
                NSImage* oldImage = [[self iconImageViewForContents:contents] image];
                NSRect frame =
                NSMakeRect(0, 0, kIconWidthAndHeight, kIconWidthAndHeight);
                iconView = [ThrobberView toastThrobberViewWithFrame:frame
                                                        beforeImage:oldImage
                                                         afterImage:sadFaviconImage];
            } else {
                NSRect frame =
                NSMakeRect(0, 0, kIconWidthAndHeight, kIconWidthAndHeight);
                iconView = [ThrobberView filmstripThrobberViewWithFrame:frame
                                                                  image:throbberImage];
            }
        }
        
        [tabController setIconView:iconView];
    }
}

// Called when a notification is received from the model that the given tab
// has been updated. |loading| will be YES when we only want to update the
// throbber state, not anything else about the (partially) loading tab.
- (void)tabChangedWithContents:(CTTabContents*)contents
                       atIndex:(NSInteger)modelIndex
                    changeType:(CTTabChangeType)change {
    // Take closing tabs into account.
    NSInteger index = [self indexFromModelIndex:modelIndex];
    
    if (change == CTTabChangeTypeTitleNotLoading) {
        // TODO(sky): make this work.
        // We'll receive another notification of the change asynchronously.
        return;
    }
    
    CTTabController* tabController = [tabArray_ objectAtIndex:index];
    
    if (change != CTTabChangeTypeLoadingOnly)
        [self setTabTitle:tabController withContents:contents];
    
    // See if the change was to/from phantom.
    bool isPhantom = [tabStripModel2_ isPhantomTabAtIndex:modelIndex];
    if (isPhantom != [tabController phantom])
        [tabController setPhantom:isPhantom];
    
    [self updateFavIconForContents:contents atIndex:modelIndex];
    
    CTTabContentsController* updatedController =
    [tabContentsArray_ objectAtIndex:index];
    [updatedController tabDidChange:contents];
}

// Called when a tab is moved (usually by drag&drop). Keep our parallel arrays
// in sync with the tab strip model. It can also be pinned/unpinned
// simultaneously, so we need to take care of that.
- (void)tabMovedWithContents:(CTTabContents*)contents
                   fromIndex:(NSInteger)modelFrom
                     toIndex:(NSInteger)modelTo {
    // Take closing tabs into account.
    NSInteger from = [self indexFromModelIndex:modelFrom];
    NSInteger to = [self indexFromModelIndex:modelTo];
    
    CTTabContentsController* movedTabContentsController = 
    [tabContentsArray_ objectAtIndex:from];
    [tabContentsArray_ removeObjectAtIndex:from];
    [tabContentsArray_ insertObject:movedTabContentsController
                            atIndex:to];
    CTTabController* movedTabController = 
    [tabArray_ objectAtIndex:from];
    assert([movedTabController isKindOfClass:[CTTabController class]]);
    [tabArray_ removeObjectAtIndex:from];
    [tabArray_ insertObject:movedTabController atIndex:to];
    
    // The tab moved, which means that the mini-tab state may have changed.
    if ([tabStripModel2_ isMiniTabAtIndex:modelTo] != [movedTabController mini])
        [self tabMiniStateChangedWithContents:contents atIndex:modelTo];
}

// Called when a tab is pinned or unpinned without moving.
- (void)tabMiniStateChangedWithContents:(CTTabContents*)contents
                                atIndex:(NSInteger)modelIndex {
    // Take closing tabs into account.
    NSInteger index = [self indexFromModelIndex:modelIndex];
    
    CTTabController* tabController = [tabArray_ objectAtIndex:index];
    assert([tabController isKindOfClass:[CTTabController class]]);
    [tabController setMini:[tabStripModel2_ isMiniTabAtIndex:modelIndex]];
    [tabController setPinned:[tabStripModel2_ isTabPinnedAtIndex:modelIndex]];
    [tabController setApp:[tabStripModel2_ isAppTabAtIndex:modelIndex]];
    [self updateFavIconForContents:contents atIndex:modelIndex];
    // If the tab is being restored and it's pinned, the mini state is set after
    // the tab has already been rendered, so re-layout the tabstrip. In all other
    // cases, the state is set before the tab is rendered so this isn't needed.
    [self layoutTabs];
}

- (void)setFrameOfSelectedTab:(NSRect)frame {
    NSView* view = [self selectedTabView];
    NSValue* identifier = [NSValue valueWithPointer:(__bridge const void*)view];
    [targetFrames_ setObject:[NSValue valueWithRect:frame]
                      forKey:identifier];
    [view setFrame:frame];
}

- (NSView*)selectedTabView {
    int selectedIndex = [tabStripModel2_ selectedIndex];
    // Take closing tabs into account. They can't ever be selected.
    selectedIndex = [self indexFromModelIndex:selectedIndex];
    return [self viewAtIndex:selectedIndex];
}

// Find the model index based on the x coordinate of the placeholder. If there
// is no placeholder, this returns the end of the tab strip. Closing tabs are
// not considered in computing the index.
- (int)indexOfPlaceholder {
    double placeholderX = placeholderFrame_.origin.x;
    int index = 0;
    int location = 0;
    // Use |tabArray_| here instead of the tab strip count in order to get the
    // correct index when there are closing tabs to the left of the placeholder.
    const int count = [tabArray_ count];
    while (index < count) {
        // Ignore closing tabs for simplicity. The only drawback of this is that
        // if the placeholder is placed right before one or several contiguous
        // currently closing tabs, the associated CTTabController will start at the
        // end of the closing tabs.
        if ([closingControllers_ containsObject:[tabArray_ objectAtIndex:index]]) {
            index++;
            continue;
        }
        NSView* curr = [self viewAtIndex:index];
        // The placeholder tab works by changing the frame of the tab being dragged
        // to be the bounds of the placeholder, so we need to skip it while we're
        // iterating, otherwise we'll end up off by one.  Note This only effects
        // dragging to the right, not to the left.
        if (curr == placeholderTab_) {
            index++;
            continue;
        }
        if (placeholderX <= NSMinX([curr frame]))
            break;
        index++;
        location++;
    }
    return location;
}

// Move the given tab at index |from| in this window to the location of the
// current placeholder.
- (void)moveTabFromIndex:(NSInteger)from {
    int toIndex = [self indexOfPlaceholder];
    [tabStripModel2_ moveTabContentsFromIndex:from toIndex:toIndex selectAfterMove:YES];
}

// Drop a given CTTabContents at the location of the current placeholder. If there
// is no placeholder, it will go at the end. Used when dragging from another
// window when we don't have access to the CTTabContents as part of our strip.
// |frame| is in the coordinate system of the tab strip view and represents
// where the user dropped the new tab so it can be animated into its correct
// location when the tab is added to the model. If the tab was pinned in its
// previous window, setting |pinned| to YES will propagate that state to the
// new window. Mini-tabs are either app or pinned tabs; the app state is stored
// by the |contents|, but the |pinned| state is the caller's responsibility.
- (void)dropTabContents:(CTTabContents*)contents
              withFrame:(NSRect)frame
            asPinnedTab:(BOOL)pinned {
    int modelIndex = [self indexOfPlaceholder];
    
    // Mark that the new tab being created should start at |frame|. It will be
    // reset as soon as the tab has been positioned.
    droppedTabFrame_ = frame;
    
    // Insert it into this tab strip. We want it in the foreground and to not
    // inherit the current tab's group.
    [tabStripModel2_ insertTabContents:contents atIndex:modelIndex options:ADD_SELECTED | (pinned ? ADD_PINNED : 0)];
}

// Called when the tab strip view changes size. As we only registered for
// changes on our view, we know it's only for our view. Layout w/out
// animations since they are blocked by the resize nested runloop. We need
// the views to adjust immediately. Neither the tabs nor their z-order are
// changed, so we don't need to update the subviews.
- (void)tabViewFrameChanged:(NSNotification*)info {
    [self layoutTabsWithAnimation:NO regenerateSubviews:NO];
}

// Called when the tracking areas for any given tab are updated. This allows
// the individual tabs to update their hover states correctly.
// Only generates the event if the cursor is in the tab strip.
- (void)tabUpdateTracking:(NSNotification*)notification {
    assert([[notification object] isKindOfClass:[CTTabView class]]);
    assert(mouseInside_);
    NSWindow* window = [tabStripView_ window];
    NSPoint location = [window mouseLocationOutsideOfEventStream];
    if (NSPointInRect(location, [tabStripView_ frame])) {
        NSEvent* mouseEvent = [NSEvent mouseEventWithType:NSMouseMoved
                                                 location:location
                                            modifierFlags:0
                                                timestamp:0
                                             windowNumber:[window windowNumber]
                                                  context:nil
                                              eventNumber:0
                                               clickCount:0
                                                 pressure:0];
        [self mouseMoved:mouseEvent];
    }
}

- (BOOL)inRapidClosureMode {
    return availableResizeWidth_ != kUseFullAvailableWidth;
}

// Disable tab dragging when there are any pending animations.
- (BOOL)tabDraggingAllowed {
    return [closingControllers_ count] == 0;
}

- (void)mouseMoved:(NSEvent*)event {
    // Use hit test to figure out what view we are hovering over.
    NSView* targetView = [tabStripView_ hitTest:[event locationInWindow]];
    
    // Set the new tab button hover state iff the mouse is over the button.
    BOOL shouldShowHoverImage = [targetView isKindOfClass:[NewTabButton class]];
    [self setNewTabButtonHoverState:shouldShowHoverImage];
    
    CTTabView* tabView = (CTTabView*)targetView;
    if (![tabView isKindOfClass:[CTTabView class]]) {
        if ([[tabView superview] isKindOfClass:[CTTabView class]]) {
            tabView = (CTTabView*)[targetView superview];
        } else {
            tabView = nil;
        }
    }
    
    if (hoveredTab_ != tabView) {
        [hoveredTab_ mouseExited:nil];  // We don't pass event because moved events
        [tabView mouseEntered:nil];  // don't have valid tracking areas
        hoveredTab_ = tabView;
    } else {
        [hoveredTab_ mouseMoved:event];
    }
}

- (void)mouseEntered:(NSEvent*)event {
    NSTrackingArea* area = [event trackingArea];
    if ([area isEqual:trackingArea_]) {
        mouseInside_ = YES;
        [self setTabTrackingAreasEnabled:YES];
        [self mouseMoved:event];
    }
}

// Called when the tracking area is in effect which means we're tracking to
// see if the user leaves the tab strip with their mouse. When they do,
// reset layout to use all available width.
- (void)mouseExited:(NSEvent*)event {
    NSTrackingArea* area = [event trackingArea];
    if ([area isEqual:trackingArea_]) {
        mouseInside_ = NO;
        [self setTabTrackingAreasEnabled:NO];
        availableResizeWidth_ = kUseFullAvailableWidth;
        [hoveredTab_ mouseExited:event];
        hoveredTab_ = nil;
        [self layoutTabs];
    } else if ([area isEqual:newTabTrackingArea_]) {
        // If the mouse is moved quickly enough, it is possible for the mouse to
        // leave the tabstrip without sending any mouseMoved: messages at all.
        // Since this would result in the new tab button incorrectly staying in the
        // hover state, disable the hover image on every mouse exit.
        [self setNewTabButtonHoverState:NO];
    }
}

// Enable/Disable the tracking areas for the tabs. They are only enabled
// when the mouse is in the tabstrip.
- (void)setTabTrackingAreasEnabled:(BOOL)enabled {
    NSNotificationCenter* defaultCenter = [NSNotificationCenter defaultCenter];
    for (CTTabController* controller in tabArray_) {
        CTTabView* tabView = [controller tabView];
        if (enabled) {
            // Set self up to observe tabs so hover states will be correct.
            [defaultCenter addObserver:self
                              selector:@selector(tabUpdateTracking:)
                                  name:NSViewDidUpdateTrackingAreasNotification
                                object:tabView];
        } else {
            [defaultCenter removeObserver:self
                                     name:NSViewDidUpdateTrackingAreasNotification
                                   object:tabView];
        }
        [tabView setTrackingEnabled:enabled];
    }
}

// Sets the new tab button's image based on the current hover state.  Does
// nothing if the hover state is already correct.
- (void)setNewTabButtonHoverState:(BOOL)shouldShowHover {
    if (shouldShowHover && !newTabButtonShowingHoverImage_) {
        newTabButtonShowingHoverImage_ = YES;
        [newTabButton_ setImage:kNewTabHoverImage];
    } else if (!shouldShowHover && newTabButtonShowingHoverImage_) {
        newTabButtonShowingHoverImage_ = NO;
        [newTabButton_ setImage:kNewTabImage];
    }
}

// Adds the given subview to (the end of) the list of permanent subviews
// (specified from bottom up). These subviews will always be below the
// transitory subviews (tabs). |-regenerateSubviewList| must be called to
// effectuate the addition.
- (void)addSubviewToPermanentList:(NSView*)aView {
    if (aView)
        [permanentSubviews_ addObject:aView];
}

// Update the subviews, keeping the permanent ones (or, more correctly, putting
// in the ones listed in permanentSubviews_), and putting in the current tabs in
// the correct z-order. Any current subviews which is neither in the permanent
// list nor a (current) tab will be removed. So if you add such a subview, you
// should call |-addSubviewToPermanentList:| (or better yet, call that and then
// |-regenerateSubviewList| to actually add it).
- (void)regenerateSubviewList {
    // Remove self as an observer from all the old tabs before a new set of
    // potentially different tabs is put in place.
    [self setTabTrackingAreasEnabled:NO];
    
    // Subviews to put in (in bottom-to-top order), beginning with the permanent
    // ones.
    NSMutableArray* subviews = [NSMutableArray arrayWithArray:permanentSubviews_];
    
    NSView* selectedTabView = nil;
    // Go through tabs in reverse order, since |subviews| is bottom-to-top.
    for (CTTabController* tab in [tabArray_ reverseObjectEnumerator]) {
        NSView* tabView = [tab view];
        if ([tab selected]) {
            assert(!selectedTabView);
            selectedTabView = tabView;
        } else {
            [subviews addObject:tabView];
        }
    }
    if (selectedTabView) {
        [subviews addObject:selectedTabView];
    }
    [tabStripView_ setSubviews:subviews];
    [self setTabTrackingAreasEnabled:mouseInside_];
}

- (CTTabContentsController*)activeTabContentsController {
    int modelIndex = [tabStripModel2_ selectedIndex];
    if (modelIndex < 0)
        return nil;
    NSInteger index = [self indexFromModelIndex:modelIndex];
    if (index < 0 ||
        index >= (NSInteger)[tabContentsArray_ count])
        return nil;
    return [tabContentsArray_ objectAtIndex:index];
}

@end
