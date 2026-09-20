//
//  hooks.h
//  BaseiOSApp
//
//  Created by Venti on 22/2/26.
//

#import "../litehook/src/litehook.h"

void* getGuestAppHeader(void);
void hook_init(void);
void overwriteExecPath(const char *newExecPath);
void GuestCryptidPatchInit(void);
