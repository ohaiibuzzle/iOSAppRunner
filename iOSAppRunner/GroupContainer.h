//
//  GroupContainer.h
//  BaseiOSApp
//
//  Interposes the app-group container lookup so guest apps read their group
//  data from a local directory instead of the sandboxed `~/Library/Group
//  Containers`, which the host cannot access.
//

#import <Foundation/Foundation.h>

void GroupContainerHooksInit(void);