//
//  PosterBoardCPBitmapBridge.m
//  lara
//

#import "PosterBoardCPBitmapBridge.h"

@interface UIImage (LaraPosterBoardCPBitmap)
- (void)writeToCPBitmapFile:(NSString *)path flags:(NSUInteger)flags;
@end

BOOL lara_write_cpbitmap(UIImage *image, NSString *path, NSError **error) {
    SEL selector = @selector(writeToCPBitmapFile:flags:);
    if (![image respondsToSelector:selector]) {
        if (error) {
            *error = [NSError errorWithDomain:@"lara.posterboard"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"UIImage cannot write cpbitmap files on this OS."}];
        }
        return NO;
    }

    [image writeToCPBitmapFile:path flags:1];
    return YES;
}
