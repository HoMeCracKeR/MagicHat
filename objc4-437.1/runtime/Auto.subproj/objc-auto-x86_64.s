/*
 * Copyright (c) 2006-2007 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#ifdef __x86_64__

/*
    This file defines the non-GC variants of objc_assign_* on a dedicated
    page in the (__DATA,__data) section. At load time under GC, each
    routine is overwritten with a jump to its GC variant. It is necessary
    for these routines to exist on a dedicated page for vm_protect to
    work properly in the GC case. The page exists in the data segment to
    reduce the kernel's page table overhead.

    Note: To avoid wasting more space than necessary at runtime, this file
    must not contain anything other than the objc_assign_* routines.
*/

.data
.align 12   // align to page boundary

LNonGCAssigns$Begin:

// id objc_assign_ivar(id value, id dest, ptrdiff_t offset);
.globl  _objc_assign_ivar
_objc_assign_ivar:
    pushq   %rbp
    movq    %rsp,%rbp
    movq    %rdi,(%rsi,%rdx)    // *(dest + offset) = value);
    movq    %rdi,%rax           // return value;
    leave
    ret

// id objc_assign_global(id value, id *dest);
.globl  _objc_assign_global
_objc_assign_global:
    pushq   %rbp
    movq    %rsp,%rbp
    movq    %rdi,(%rsi)     // *(dest = value);
    movq    %rdi,%rax       // return value;
    leave
    ret

// As of OS X 10.5, objc_assign_strongCast_non_gc is identical to
// objc_assign_global_non_gc.

// id objc_assign_strongCast(id value, id *dest);
.globl  _objc_assign_strongCast
_objc_assign_strongCast:
    pushq   %rbp
    movq    %rsp,%rbp
    movq    %rdi,(%rsi)     // *(dest = value);
    movq    %rdi,%rax       // return value;
    leave
    ret

LNonGCAssigns$End:

// Claim the remainder of the page.
.set    L$set$assignsSize,LNonGCAssigns$End-LNonGCAssigns$Begin
.space  4096-L$set$assignsSize

#endif
