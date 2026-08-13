#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the caught NSException, or nil if the block completed normally.
NSException * _Nullable CueCatchObjCException(void (NS_NOESCAPE ^ _Nonnull block)(void));

NS_ASSUME_NONNULL_END
