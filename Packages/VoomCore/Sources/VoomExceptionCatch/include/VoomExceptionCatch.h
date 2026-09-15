#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside `@try/@catch`. Returns NO and fills `error` on NSException.
/// Swift `catch` does not intercept AVFoundation DAL exceptions.
BOOL VoomCatchException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
