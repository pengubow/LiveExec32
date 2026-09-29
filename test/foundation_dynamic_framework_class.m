#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <string.h>

static unsigned checks;
static unsigned failures;

static void check(const char *name, BOOL passed) {
    ++checks;
    failures += !passed;
    printf("dynamic-framework-class-%s: %s\n",
        name, passed ? "PASS" : "FAIL");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        // Deliberately link only Foundation. This reproduces an optional
        // framework loaded through NSBundle instead of a Mach-O dependency.
        check("initially-unloaded",
            objc_getClass("CTTelephonyNetworkInfo") == Nil);
        NSBundle *bundle = [NSBundle bundleWithPath:
            @"/System/Library/Frameworks/CoreTelephony.framework"];
        check("bundle", bundle != nil);
        check("load", [bundle load]);

        Class networkInfoClass = [bundle classNamed:
            @"CTTelephonyNetworkInfo"];
        check("exact-class", networkInfoClass != Nil &&
            strcmp(class_getName(networkInfoClass),
                "CTTelephonyNetworkInfo") == 0);
        check("registered", networkInfoClass != Nil &&
            NSClassFromString(@"CTTelephonyNetworkInfo") == networkInfoClass);
        check("repeated-lookup", networkInfoClass != Nil &&
            [bundle classNamed:@"CTTelephonyNetworkInfo"] == networkInfoClass);
        check("framework-sibling", objc_getClass("CTCarrier") != Nil);
        check("absent-class", [bundle classNamed:
            @"LC32ClassWhichDoesNotExist"] == Nil);

        if(networkInfoClass && networkInfoClass != [NSObject class]) {
            id info = [[networkInfoClass alloc] init];
            const SEL providerSelector =
                sel_registerName("subscriberCellularProvider");
            const BOOL hasProvider = [info respondsToSelector:
                providerSelector];
            check("provider-selector", hasProvider);
            if(hasProvider) {
                id carrier = [info performSelector:providerSelector];
                // Modern hosts can return nil. A provider, when present,
                // must still be callable through the real guest proxy.
                const SEL nameSelector = sel_registerName("carrierName");
                const BOOL hasName = !carrier ||
                    [carrier respondsToSelector:nameSelector];
                check("carrier-selector", hasName);
                if(carrier && hasName) {
                    id name = [carrier performSelector:nameSelector];
                    check("carrier-name", !name ||
                        [name isKindOfClass:[NSString class]]);
                }
            }
            [info release];
        }
    }
    printf("dynamic-framework-class-regression: %s (%u/%u)\n",
        failures ? "FAIL" : "PASS", checks - failures, checks);
    return failures != 0;
}
