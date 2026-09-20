//
//  WindowHooks.h
//  iOSAppRunner
//
//  Interposes UIWindow so legacy, non-scene iOS guests get their window
//  attached to the host's real UIWindowScene. Without this, a guest window
//  created via `[[UIWindow alloc] initWith...]` + `makeKeyAndVisible` has no
//  scene and renders as a blank window on Catalyst.
//

#import <UIKit/UIKit.h>

void GuestWindowHooksInit(void);
void SetGuestWindowScene(void *scene);
void SetGuestPlaceholderWindow(void *window);
UIWindow *GuestAdoptSceneLessWindows(void);