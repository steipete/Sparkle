#import <Cocoa/Cocoa.h>
#import <stdio.h>
#import "SUTouchBarButtonGroup.h"

int main(void) {
    @autoreleasepool {
        NSButton *install = [NSButton buttonWithTitle:@"Install" target:nil action:NULL];
        NSButton *skip = [NSButton buttonWithTitle:@"Skip This Version" target:nil action:NULL];
        skip.hidden = YES;

        SUTouchBarButtonGroup *group = [[SUTouchBarButtonGroup alloc] initByReferencingButtons:@[install, skip]];
        NSArray<NSButton *> *copies = group.buttons;
        if (copies.count != 1) {
            fprintf(stderr, "expected 1 touch bar button, got %lu\n", (unsigned long)copies.count);
            return 1;
        }
        if (![copies[0].title isEqualToString:@"Install"]) {
            fprintf(stderr, "unexpected title %s\n", copies[0].title.UTF8String);
            return 2;
        }
        return 0;
    }
}
