#include "../include/LC32InvocationABI.h"

#include <stdio.h>

static unsigned checks;
static unsigned failures;

static void checkLayout(const char *type, char fieldType, unsigned fieldCount) {
    LC32InvocationFloatingLayout layout = {'x', 99, 99};
    const int accepted = LC32InvocationGetFloatingLayout(type, &layout);
    const size_t expectedBytes = fieldCount * (fieldType == 'f' ? 4u : 8u);
    const int passed = fieldCount
        ? accepted && layout.fieldType == fieldType &&
            layout.fieldCount == fieldCount && layout.byteSize == expectedBytes
        : !accepted && layout.fieldType == 'x' &&
            layout.fieldCount == 99 && layout.byteSize == 99;
    checks++;
    if(!passed) {
        failures++;
        fprintf(stderr, "invocation-floating-layout FAIL: %s\n",
            type ? type : "(null)");
    }
}

int main(void) {
    checkLayout("{CGPoint=ff}", 'f', 2);
    checkLayout("{CGSize=dd}", 'd', 2);
    checkLayout("{CGRect={CGPoint=ff}{CGSize=ff}}", 'f', 4);
    checkLayout("{CGRect={CGPoint=dd}{CGSize=dd}}", 'd', 4);
    checkLayout("r{_CGPoint=ff}", 'f', 2);
    checkLayout("{UserRecord=f}", 'f', 1);
    checkLayout("{UserRecord=fff}", 'f', 3);
    checkLayout("{UserRecord=dddd}", 'd', 4);
    checkLayout("{Named=\"x\"f\"y\"f}", 'f', 2);
    checkLayout("{Named=\"x\\\"y\"d\"z\"d}", 'd', 2);
    checkLayout("{Qualified=rfnd}", 0, 0);
    checkLayout("{Qualified=rfnf}", 'f', 2);
    const char *unsupported[] = {
        NULL, "", "f", "{CGPoint}", "{CGPoint=}", "{=ff}",
        "{CGPoint=ff", "{CGPoint=ff}}", "{CGPoint=ff}8", "{CGPoint=fd}",
        "{CGPoint=if}", "{Objects=@@}", "{Pointer=^f}", "{Array=[2f]}",
        "(Union=ff)", "{Bits=b32}", "{Wide=fffff}",
        "{Nested={Empty=}ff}", "{Named=\"unterminatedf}",
        "{Nested={Point=ff}{Size=dd}}", "{Named=\"x\"}",
    };
    for(size_t index = 0; index < sizeof(unsupported) / sizeof(*unsupported); index++)
        checkLayout(unsupported[index], 0, 0);
    printf("invocation floating layout: %u checks, %u failures\n", checks, failures);
    return failures ? 1 : 0;
}
