#import "VoomExceptionCatch.h"

BOOL VoomCatchException(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"com.voom.capture"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name ?: @"AVFoundation exception"
            }];
        }
        return NO;
    }
}
