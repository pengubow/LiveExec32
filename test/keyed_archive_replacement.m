#import <Foundation/Foundation.h>
#import <LC32/LC32.h>

#include <stdint.h>
#include <stdio.h>

#if __has_feature(objc_arc)
#error This fixture requires manual reference counting.
#endif

static unsigned failures;
static unsigned recordDeallocCount;
static unsigned valueDeallocCount;
static unsigned decodeCount;
static uint32_t abandonedReceiver;
static uint64_t abandonedHost;

static void check(const char *name, BOOL passed) {
    printf("keyed-archive-replacement-%s: %s\n",
        name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

@interface LC32DecodedArchiveValue : NSObject {
    NSInteger _marker;
}
+ (instancetype)valueWithMarker:(NSInteger)marker;
- (instancetype)initWithMarker:(NSInteger)marker;
- (NSInteger)marker;
@end

@implementation LC32DecodedArchiveValue
+ (instancetype)valueWithMarker:(NSInteger)marker {
    return [[[self alloc] initWithMarker:marker] autorelease];
}

- (instancetype)initWithMarker:(NSInteger)marker {
    if((self = [super init])) {
        _marker = marker;
    }
    return self;
}

- (NSInteger)marker {
    return _marker;
}

- (void)dealloc {
    ++valueDeallocCount;
    [super dealloc];
}
@end

@interface LC32ReplacingArchiveRecord : NSObject <NSCoding> {
    NSInteger _marker;
}
- (instancetype)initWithMarker:(NSInteger)marker;
@end

@implementation LC32ReplacingArchiveRecord
- (instancetype)initWithMarker:(NSInteger)marker {
    if((self = [super init])) {
        _marker = marker;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_marker forKey:@"marker"];
}

- (id)initWithCoder:(NSCoder *)coder {
    const NSInteger marker = [coder decodeIntegerForKey:@"marker"];
    ++decodeCount;
    abandonedReceiver = (uint32_t)(uintptr_t)self;
    abandonedHost = [self host_self];
    /* The native unarchiver owns the allocation. Its guest callback sees
     * only the lifetime pin until it explicitly retains the replacement. */
    [self autorelease];
    id replacement = [LC32DecodedArchiveValue valueWithMarker:marker];
    return [replacement retain];
}

- (void)dealloc {
    ++recordDeallocCount;
    [super dealloc];
}
@end

static BOOL writeArchive(NSString *path, NSInteger marker) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    LC32ReplacingArchiveRecord *record =
        [[LC32ReplacingArchiveRecord alloc] initWithMarker:marker];
    NSArray *records = [[NSArray alloc] initWithObjects:record, nil];
    const BOOL written = [NSKeyedArchiver archiveRootObject:records
                                                   toFile:path];
    [records release];
    [record release];
    [pool drain];
    return written;
}

static void readArchive(NSString *path, NSInteger marker) {
    const unsigned recordsBefore = recordDeallocCount;
    const unsigned valuesBefore = valueDeallocCount;
    const unsigned decodesBefore = decodeCount;
    NSAutoreleasePool *outerPool = [NSAutoreleasePool new];
    NSAutoreleasePool *decodePool = [NSAutoreleasePool new];
    NSArray *records =
        [[NSKeyedUnarchiver unarchiveObjectWithFile:path] retain];
    check("decoder-returned-array", records.count == 1);
    LC32DecodedArchiveValue *value = records.count == 1
        ? [records objectAtIndex:0] : nil;
    const uint32_t valueAddress = (uint32_t)(uintptr_t)value;
    const uint64_t valueHost = [value host_self];
    check("replacement-has-decoded-value", value && value.marker == marker);
    [decodePool drain];

    check("abandoned-receiver-destroyed-once",
        decodeCount == decodesBefore + 1 &&
        recordDeallocCount == recordsBefore + 1 &&
        LC32LookupHostMapping(abandonedReceiver) != abandonedHost);
    check("array-keeps-replacement-after-pool-drain",
        value && value.marker == marker &&
        valueDeallocCount == valuesBefore &&
        LC32LookupHostMapping(valueAddress) == valueHost);
    [records release];
    [outerPool drain];
    check("replacement-destroyed-once",
        valueDeallocCount == valuesBefore + 1 &&
        LC32LookupHostMapping(valueAddress) != valueHost);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString];
    const NSInteger marker = 0x51a7;
    const BOOL written = writeArchive(path, marker);
    check("archive-written", written);
    if(written) {
        NSData *original = [[NSData alloc] initWithContentsOfFile:path];
        for(unsigned iteration = 0; iteration < 3; ++iteration) {
            printf("keyed-archive-replacement-read: %u\n", iteration + 1);
            readArchive(path, marker);
        }
        NSData *after = [NSData dataWithContentsOfFile:path];
        check("repeated-decodes-preserve-archive",
            original && [original isEqualToData:after]);
        [original release];
        check("fixture-file-removed",
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
    }
    [pool drain];
    printf("keyed-archive-replacement: %s\n", failures ? "FAIL" : "PASS");
    return failures != 0;
}
