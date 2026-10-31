//
//  Keychain.h
//  BaseiOSApp
//
//  Created by Venti on 24/2/26.
//

#import <Foundation/Foundation.h>

// Installs the guest keychain hooks. `hostId` is the keychain access-group
// base (KeychainAccessGroupBase); `slot` is the host-assigned slot number.
// Returns NO when the slot's access group isn't usable (missing entitlement).
BOOL SecItemGuestHooksInit(NSString* hostId, int slot);
