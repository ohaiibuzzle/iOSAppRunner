//
//  Resolution.h
//  iOSAppRunner
//
//  Created by Venti on 27/4/26.
//

#import <Foundation/Foundation.h>

/// `hostHomeDirectory` is the *real* (pre-guest-redirect) home directory,
/// where the launcher wrote `display_resolution.plist` before spawning this
/// process — must be captured before `HOME` gets redirected into the
/// guest's sandboxed home.
void DisplayHooksInit(NSString *hostHomeDirectory);
