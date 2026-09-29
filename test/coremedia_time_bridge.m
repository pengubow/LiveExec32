#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>

/* Run inside LiveExec32 to exercise real native argument and indirect-return
 * calls. Linux cross-compilation checks the guest ABI; it cannot execute the
 * native Foundation and media implementations. */
static void checkTime(const char *name, CMTime actual, CMTime expected) {
    const BOOL passed = actual.value == expected.value &&
        actual.timescale == expected.timescale &&
        actual.flags == expected.flags && actual.epoch == expected.epoch;
    printf("coremedia-time-bridge-%s: %s\n", name, passed ? "PASS" : "FAIL");
    if(!passed) exit(1);
}

int main(void) {
    @autoreleasepool {
        const CMTime expected = {
            -INT64_C(0x123456789ab), 90000,
            kCMTimeFlags_Valid | kCMTimeFlags_HasBeenRounded,
            INT64_C(0x23456789abc),
        };
        NSValue *value = [NSValue valueWithCMTime:expected];
        checkTime("value-roundtrip", value.CMTimeValue, expected);

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"mp4"]];
        NSError *error = nil;
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:
            [NSURL fileURLWithPath:path] fileType:AVFileTypeMPEG4 error:&error];
        if(!writer) {
            NSLog(@"coremedia-time-bridge-writer: FAIL %@", error);
            return 1;
        }
        const CMTime interval = {
            INT64_C(0x123456789ab), 90000, kCMTimeFlags_Valid, 0,
        };
        writer.movieFragmentInterval = interval;
        checkTime("writer-property-roundtrip", writer.movieFragmentInterval,
            interval);
        [writer cancelWriting];
        return 0;
    }
}
