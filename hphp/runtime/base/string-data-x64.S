#include "hphp/runtime/base/string-data-macros.h"
#include "hphp/util/etch-helpers.h"

#if defined(__SSE4_2__) && !defined(NO_HWCRC) && defined(NO_M_DATA) && \
    !defined(_MSC_VER)

        .file     "hphp/runtime/base/string-data-x64.S"

/*
 * HPHP::StringData::hashHelper() is defined here only when SSE4.2 is explicitly
 * specified, and NO_M_DATA is used in StringData.
 */

ETCH_SECTION(_ZNK4HPHP10StringData10hashHelperEv)
.globl    _ZNK4HPHP10StringData10hashHelperEv
ETCH_TYPE(_ZNK4HPHP10StringData10hashHelperEv, @function)
_ZNK4HPHP10StringData10hashHelperEv:
        CFI(startproc)
        mov     SD_LEN(%rdi), %ecx
        or      $-1, %eax
        lea     SD_DATA(%rdi, %rcx), %rdx
        neg     %rcx
        jnz     ETCH_LABEL(hheader)
        jmp     ETCH_LABEL(hend)

ETCH_LABEL(hloop):
        crc32q  %rsi, %rax
ETCH_LABEL(hheader):
        movabs  $0xdfdfdfdfdfdfdfdf, %rsi
        and     (%rdx, %rcx), %rsi
        add     $8, %rcx
        jnc     ETCH_LABEL(hloop)

        shl     $3, %ecx
        shl     %cl, %rsi
        crc32q  %rsi, %rax

ETCH_LABEL(hend):
        shr     %eax
        or      %eax, SD_HASH(%rdi)
        ret
        CFI(endproc)
ETCH_SIZE(_ZNK4HPHP10StringData10hashHelperEv)

#endif
