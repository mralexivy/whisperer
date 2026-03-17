//
//  ObjCExceptionCatcher.m
//  Whisperer
//
//  Catches Obj-C NSExceptions that Swift do/catch cannot handle
//

#import "ObjCExceptionCatcher.h"

BOOL ObjCTry(void (^_Nonnull block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"com.ivy.whisperer.ObjCException"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}
