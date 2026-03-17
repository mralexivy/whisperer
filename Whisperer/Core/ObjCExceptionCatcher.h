//
//  ObjCExceptionCatcher.h
//  Whisperer
//
//  Catches Obj-C NSExceptions that Swift do/catch cannot handle
//

#import <Foundation/Foundation.h>

/// Execute a block, catching any NSException thrown.
/// Returns YES on success, NO if an exception was caught.
/// If an exception is caught and error is non-NULL, *error is set with the exception details.
BOOL ObjCTry(void (^_Nonnull block)(void), NSError *_Nullable *_Nullable error);
