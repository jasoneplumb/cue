#import "CueExceptionShim.h"

NSException * _Nullable CueCatchObjCException(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
