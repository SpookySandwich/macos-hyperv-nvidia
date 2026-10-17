#import <AppKit/AppKit.h>
#import <sys/stat.h>

static NSDictionary *snapshot(NSPasteboard *board, long revision) {
    struct stat console;
    if (stat("/dev/console", &console) || console.st_uid != getuid())
        return @{ @"revision": @(board.changeCount), @"supported": @NO };
    if (revision == board.changeCount)
        return @{ @"revision": @(board.changeCount), @"supported": @YES };
    NSString *text = [board stringForType:NSPasteboardTypeString];
    NSData *png = [board dataForType:NSPasteboardTypePNG];
    if (!png && [board availableTypeFromArray:@[NSPasteboardTypeTIFF]]) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[board dataForType:NSPasteboardTypeTIFF]];
        if (rep) png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    }
    if (text.length > 8*1024*1024 || png.length > 16*1024*1024)
        return @{ @"revision": @(board.changeCount), @"supported": @NO };
    return @{ @"revision": @(board.changeCount), @"text": text ?: (id)NSNull.null,
              @"png": png ? [png base64EncodedStringWithOptions:0] : (id)NSNull.null,
              @"supported": (text != nil || png != nil) ? @YES : @NO };
}
int main(int argc, const char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) { puts("1.0"); return 0; }
    @autoreleasepool {
        NSPasteboard *board = (argc == 2 && !strcmp(argv[1], "--test-buffer")) ? [NSPasteboard pasteboardWithUniqueName] : NSPasteboard.generalPasteboard;
        char *line = NULL; size_t capacity = 0;
        while (getline(&line, &capacity, stdin) > 0) { @autoreleasepool {
            NSDictionary *reply;
            if (strlen(line) > 24*1024*1024) break;
            NSData *data = [[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![request isKindOfClass:NSDictionary.class]) break;
            if ([request[@"action"] isEqual:@"write"]) {
                struct stat console;
                if (stat("/dev/console", &console) || console.st_uid != getuid()) reply = @{ @"revision": @(board.changeCount), @"supported": @NO };
                else {
                    NSString *text = [request[@"text"] isKindOfClass:NSString.class] ? request[@"text"] : nil;
                    NSString *encoded = [request[@"png"] isKindOfClass:NSString.class] ? request[@"png"] : nil;
                    NSData *png = encoded ? [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
                    if ((text || png) && text.length <= 8*1024*1024 && png.length <= 16*1024*1024) {
                        NSPasteboardItem *item = [NSPasteboardItem new];
                        if (text) [item setString:text forType:NSPasteboardTypeString];
                        if (png) [item setData:png forType:NSPasteboardTypePNG];
                        [board clearContents]; [board writeObjects:@[item]];
                    }
                    reply = @{ @"revision": @(board.changeCount), @"supported": @YES };
                }
            } else reply = snapshot(board, [request[@"revision"] longValue]);
            NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout);
        }}
        free(line);
    }
    return 0;
}
