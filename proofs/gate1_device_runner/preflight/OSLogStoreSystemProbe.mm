#import <Foundation/Foundation.h>
#import <OSLog/OSLog.h>

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        OSLogStore *store =
            [OSLogStore storeWithScope:OSLogStoreSystem error:&error];
        return store != nil ? 0 : (error != nil ? 2 : 1);
    }
}
