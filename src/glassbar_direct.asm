bits 64
default rel

global DllMain

extern GetModuleHandleW
extern GetCurrentProcessId
extern FindWindowW
extern GetWindowThreadProcessId
extern IsBadReadPtr
extern RegisterWindowMessageW
extern SetWindowsHookExW
extern SendMessageTimeoutW
extern UnhookWindowsHookEx
extern CreateThread
extern DisableThreadLibraryCalls
extern CloseHandle
extern OpenEventW
extern CreateEventW
extern SetEvent
extern WaitForSingleObject
extern CallNextHookEx
extern RoInitialize
extern RoUninitialize
extern RoGetActivationFactory
extern WindowsCreateString
extern WindowsDeleteString

%define S_OK                         0
%define E_NOINTERFACE                0x80004002
%define E_UNEXPECTED                0x8000FFFF
%define ERROR_REVISION_MISMATCH_HR   0x8007051A
%define WH_CALLWNDPROC               4
%define SMTO_BLOCK_ABORT             3
%define EVENT_MODIFY_STATE           2

; Exact Windissect evidence for Windows 11 24H2 26100.9444.
%define TASKBAR_TIMESTAMP            2378140881
%define TASKBAR_IMAGE_SIZE           3162112
%define TRAYUI_VTABLE_RVA            0x1CAE88
%define TASKBARHOST_REF_VTABLE_RVA   0x1C52A0

section .rdata
    taskbar_name dw 't','a','s','k','b','a','r','.','d','l','l',0
    tray_class dw 'S','h','e','l','l','_','T','r','a','y','W','n','d',0
    apply_message dw 'G','l','a','s','s','b','a','r','.','A','s','m','.','A','p','p','l','y','.','v','1',0
    applied_event_name dw 'L','o','c','a','l','\','G','l','a','s','s','b','a','r','A','p','p','l','i','e','d',0
    restore_event_name dw 'L','o','c','a','l','\','G','l','a','s','s','b','a','r','R','e','s','t','o','r','e',0
    visual_tree_class dw 'W','i','n','d','o','w','s','.','U','I','.','X','a','m','l','.',
                      dw 'M','e','d','i','a','.','V','i','s','u','a','l','T','r','e','e','H','e','l','p','e','r',0
    solid_brush_class dw 'W','i','n','d','o','w','s','.','U','I','.','X','a','m','l','.',
                      dw 'M','e','d','i','a','.','S','o','l','i','d','C','o','l','o','r','B','r','u','s','h',0

align 8
    ; e75758c4-d25d-4b1d-971f-596f17f12baa
    iid_visual_tree dd 0xE75758C4
                    dw 0xD25D,0x4B1D
                    db 0x97,0x1F,0x59,0x6F,0x17,0xF1,0x2B,0xAA
    ; 5c526665-f60e-4912-af59-5fe0680f089d
    iid_dependency dd 0x5C526665
                   dw 0xF60E,0x4912
                   db 0xAF,0x59,0x5F,0xE0,0x68,0x0F,0x08,0x9D
    ; 786f2b75-9aa0-454d-ae06-a2466e37c832
    iid_shape dd 0x786F2B75
              dw 0x9AA0,0x454D
              db 0xAE,0x06,0xA2,0x46,0x6E,0x37,0xC8,0x32
    ; d935ce0c-86f5-4da6-8a27-b1619ef7f92b
    iid_solid_factory dd 0xD935CE0C
                      dw 0x86F5,0x4DA6
                      db 0x8A,0x27,0xB1,0x61,0x9E,0xF7,0xF9,0x2B
    ; 8806a321-1e06-422c-a1cc-01696559e021
    iid_brush dd 0x8806A321
              dw 0x1E06,0x422C
              db 0xA1,0xCC,0x01,0x69,0x65,0x59,0xE0,0x21
    iid_iunknown dd 0
                 dw 0,0
                 db 0xC0,0,0,0,0,0,0,0x46

section .data
align 8
    module_handle dq 0
    taskbar_root dq 0
    tray_window dq 0
    ui_thread dd 0
    dispatch_message dd 0
    dispatch_ran dd 0
    dispatch_result dd E_UNEXPECTED
    applied_event dq 0
    restore_event dq 0
    original_brush dq 0
    target_shape dq 0
    restore_mode dd 0

section .bss
align 16
    tray_objects resq 16
    tray_count resd 1

section .text

; Releases the COM pointer in RCX if non-null.
release:
    test rcx, rcx
    jz .done
    mov rax, [rcx]
    sub rsp, 40
    call qword [rax + 16]
    add rsp, 40
.done:
    ret

; Returns EAX=0 when RCX can safely provide one pointer-sized read.
readable_pointer:
    test rcx, rcx
    jz .bad
    sub rsp, 40
    mov edx, 8
    call IsBadReadPtr
    add rsp, 40
    ret
.bad:
    mov eax, 1
    ret

; Resolve the exact-build live TaskbarFrame using venir's Windissect-gated
; TrayUI -> shared TaskbarHost control block path.
locate_root:
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72

    lea rcx, [taskbar_name]
    call GetModuleHandleW
    test rax, rax
    jz .revision
    mov rbx, rax
    movsxd rcx, dword [rbx + 0x3C]
    add rcx, rbx                    ; NT headers
    cmp dword [rcx], 0x00004550
    jne .revision
    cmp dword [rcx + 8], TASKBAR_TIMESTAMP
    jne .revision
    cmp dword [rcx + 0x50], TASKBAR_IMAGE_SIZE
    jne .revision
    mov rbp, rcx

    lea rcx, [tray_class]
    xor edx, edx
    call FindWindowW
    test rax, rax
    jz .unexpected
    mov [tray_window], rax
    mov rcx, rax
    lea rdx, [rsp + 64]
    call GetWindowThreadProcessId
    test eax, eax
    jz .unexpected
    mov [ui_thread], eax
    mov edi, [rsp + 64]
    call GetCurrentProcessId
    cmp eax, edi
    jne .unexpected

    movzx r12d, word [rbp + 6]      ; section count
    movzx eax, word [rbp + 20]      ; optional-header size
    lea r13, [rbp + rax + 24]       ; first IMAGE_SECTION_HEADER
    lea r14, [rbx + TRAYUI_VTABLE_RVA]
    xor r15d, r15d
    mov dword [tray_count], 0

.section_loop:
    test r12d, r12d
    jz .scan_hosts
    mov eax, [r13 + 36]
    test eax, 0x40000000             ; readable
    jz .next_section
    test eax, 0x80000000             ; writable
    jz .next_section
    test eax, 0x20000000             ; not executable
    jnz .next_section
    mov eax, [r13 + 12]
    lea rsi, [rbx + rax]
    mov edi, [r13 + 8]
    and edi, -8
.qword_loop:
    test edi, edi
    jz .next_section
    mov r15, [rsi]
    mov rcx, r15
    call readable_pointer
    test eax, eax
    jnz .qword_next
    cmp [r15], r14
    jne .qword_next
    mov eax, [tray_count]
    cmp eax, 16
    jae .qword_next
    xor ecx, ecx
.dedup:
    cmp ecx, eax
    jae .store_tray
    lea rdx, [tray_objects]
    cmp [rdx + rcx*8], r15
    je .qword_next
    inc ecx
    jmp .dedup
.store_tray:
    lea rdx, [tray_objects]
    mov [rdx + rax*8], r15
    inc eax
    mov [tray_count], eax
.qword_next:
    add rsi, 8
    sub edi, 8
    jmp .qword_loop
.next_section:
    add r13, 40
    dec r12d
    jmp .section_loop

.scan_hosts:
    lea r14, [rbx + TASKBARHOST_REF_VTABLE_RVA]
    xor ebp, ebp                    ; tray index
    xor r15d, r15d                  ; unique host control block
.tray_loop:
    cmp ebp, [tray_count]
    jae .host_done
    lea rax, [tray_objects]
    mov rsi, [rax + rbp*8]
    xor edi, edi
.member_loop:
    cmp edi, 0x800
    jae .next_tray
    mov r12, [rsi + rdi]
    mov rcx, r12
    call readable_pointer
    test eax, eax
    jnz .member_next
    cmp [r12], r14
    jne .member_next
    test r15, r15
    jz .remember_host
    cmp r15, r12
    jne .unexpected
    jmp .member_next
.remember_host:
    mov r15, r12
.member_next:
    add edi, 8
    jmp .member_loop
.next_tray:
    inc ebp
    jmp .tray_loop
.host_done:
    test r15, r15
    jz .nointerface
    ; _Ref_count_obj2 prefix + TaskbarHost::TaskbarFrame = 0x10 + 0x10.
    mov rax, [r15 + 0x20]
    test rax, rax
    jz .unexpected
    mov [taskbar_root], rax
    xor eax, eax
    jmp .out
.revision:
    mov eax, ERROR_REVISION_MISMATCH_HR
    jmp .out
.nointerface:
    mov eax, E_NOINTERFACE
    jmp .out
.unexpected:
    mov eax, E_UNEXPECTED
.out:
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret

; Create transparent SolidColorBrush and return its IBrush in [RCX].
make_brush:
    push rbx
    push rdi
    sub rsp, 72
    mov rbx, rcx
    mov qword [rbx], 0
    lea rcx, [solid_brush_class]
    mov edx, 37
    lea r8, [rsp + 32]
    mov qword [rsp + 32], 0
    call WindowsCreateString
    test eax, eax
    js .done
    mov rcx, [rsp + 32]
    lea rdx, [iid_solid_factory]
    lea r8, [rsp + 40]
    mov qword [rsp + 40], 0
    call RoGetActivationFactory
    mov edi, eax
    mov rcx, [rsp + 32]
    call WindowsDeleteString
    mov eax, edi
    test eax, eax
    js .done
    mov rcx, [rsp + 40]
    mov rax, [rcx]
    xor edx, edx                    ; Color { A=0,R=0,G=0,B=0 }
    lea r8, [rsp + 48]
    mov qword [rsp + 48], 0
    call qword [rax + 48]           ; CreateInstanceWithColor
    mov edi, eax
    mov rcx, [rsp + 40]
    call release
    mov eax, edi
    test eax, eax
    js .done
    mov rcx, [rsp + 48]
    mov rax, [rcx]
    lea rdx, [iid_brush]
    mov r8, rbx
    call qword [rax]                ; ISolidColorBrush::QI(IBrush)
    mov edi, eax
    mov rcx, [rsp + 48]
    call release
    mov eax, edi
.done:
    add rsp, 72
    pop rdi
    pop rbx
    ret

; Execute solely on Explorer's XAML dispatcher thread.
apply_on_ui_thread:
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    sub rsp, 96

    mov ecx, 0                      ; RO_INIT_SINGLETHREADED
    call RoInitialize
    mov r12d, eax
    test eax, eax
    jns .ro_ok
    cmp eax, 0x80010106             ; RPC_E_CHANGED_MODE is acceptable
    jne .out
.ro_ok:
    lea rcx, [visual_tree_class]
    mov edx, 38
    lea r8, [rsp + 40]
    mov qword [rsp + 40], 0
    call WindowsCreateString
    test eax, eax
    js .cleanup
    mov rcx, [rsp + 40]
    lea rdx, [iid_visual_tree]
    lea r8, [rsp + 48]
    mov qword [rsp + 48], 0
    call RoGetActivationFactory
    mov edi, eax
    mov rcx, [rsp + 40]
    call WindowsDeleteString
    mov eax, edi
    test eax, eax
    js .cleanup

    lea rcx, [rsp + 56]
    call make_brush
    test eax, eax
    js .cleanup

    mov rcx, [taskbar_root]
    mov rax, [rcx]
    lea rdx, [iid_dependency]
    lea r8, [rsp + 64]
    mov qword [rsp + 64], 0
    call qword [rax]
    test eax, eax
    js .cleanup
    mov ebp, 4                      ; verified path: 0/0/0/0/0
.child_loop:
    mov rcx, [rsp + 48]             ; IVisualTreeHelperStatics
    mov rax, [rcx]
    mov rdx, [rsp + 64]
    xor r8d, r8d
    lea r9, [rsp + 72]
    mov qword [rsp + 72], 0
    call qword [rax + 80]           ; GetChild(current, 0)
    test eax, eax
    js .cleanup
    mov rcx, [rsp + 64]
    call release
    mov rax, [rsp + 72]
    mov [rsp + 64], rax
    dec ebp
    jnz .child_loop

    mov rcx, [rsp + 64]
    mov rax, [rcx]
    lea rdx, [iid_shape]
    lea r8, [rsp + 80]
    mov qword [rsp + 80], 0
    call qword [rax]
    test eax, eax
    js .cleanup
    mov rcx, [rsp + 80]
    mov rax, [rcx]
    lea rdx, [original_brush]
    call qword [rax + 48]           ; preserve Microsoft's exact original Fill
    test eax, eax
    js .cleanup
    mov rcx, [rsp + 80]
    mov rax, [rcx]
    mov rdx, [rsp + 56]
    call qword [rax + 56]           ; IShape::put_Fill(IBrush)
    mov edi, eax
    test eax, eax
    js .after_verify

    ; Read back and compare canonical IUnknown identity.
    mov rcx, [rsp + 80]
    mov rax, [rcx]
    lea rdx, [rsp + 88]
    mov qword [rsp + 88], 0
    call qword [rax + 48]           ; IShape::get_Fill
    mov edi, eax
    test eax, eax
    js .after_verify
    mov rcx, [rsp + 56]
    mov rax, [rcx]
    lea rdx, [iid_iunknown]
    lea r8, [rsp + 32]
    mov qword [rsp + 32], 0
    call qword [rax]
    test eax, eax
    js .after_verify
    mov rcx, [rsp + 88]
    mov rax, [rcx]
    lea rdx, [iid_iunknown]
    lea r8, [rsp + 40]
    mov qword [rsp + 40], 0
    call qword [rax]
    mov edi, eax
    test eax, eax
    js .after_verify
    mov rax, [rsp + 32]
    cmp rax, [rsp + 40]
    je .verified
    mov edi, E_UNEXPECTED
.verified:
    mov rcx, [rsp + 40]
    call release
    mov rcx, [rsp + 32]
    call release
    mov rax, [rsp + 80]
    mov [target_shape], rax
    mov qword [rsp + 80], 0
.after_verify:
    mov rcx, [rsp + 88]
    call release
    mov rcx, [rsp + 80]
    call release
    mov eax, edi
.cleanup:
    mov edi, eax
    mov rcx, [rsp + 64]
    call release
    mov rcx, [rsp + 56]
    call release
    mov rcx, [rsp + 48]
    call release
    test r12d, r12d
    js .no_uninit
    call RoUninitialize
.no_uninit:
    mov eax, edi
.out:
    add rsp, 96
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret

restore_on_ui_thread:
    push rbx
    sub rsp, 32
    mov rcx, [target_shape]
    mov rdx, [original_brush]
    test rcx, rcx
    jz .missing
    test rdx, rdx
    jz .missing
    mov rax, [rcx]
    call qword [rax + 56]           ; restore the captured IBrush
    mov ebx, eax
    test eax, eax
    js .out
    mov rcx, [target_shape]
    call release
    mov rcx, [original_brush]
    call release
    mov qword [target_shape], 0
    mov qword [original_brush], 0
    mov eax, ebx
    jmp .out
.missing:
    mov eax, E_UNEXPECTED
.out:
    add rsp, 32
    pop rbx
    ret

hook_proc:
    ; RCX=code, RDX=wParam, R8=CWPSTRUCT*
    sub rsp, 56
    mov [rsp + 32], rcx
    mov [rsp + 40], rdx
    mov [rsp + 48], r8
    test ecx, ecx
    js .chain
    mov eax, [dispatch_message]
    cmp dword [r8 + 16], eax        ; CWPSTRUCT.message on x64
    jne .chain
    xor eax, eax
    mov ecx, 1
    lock cmpxchg [dispatch_ran], ecx
    jne .chain
    cmp dword [restore_mode], 0
    jne .restore
    call apply_on_ui_thread
    jmp .save
.restore:
    call restore_on_ui_thread
.save:
    mov [dispatch_result], eax
.chain:
    xor ecx, ecx
    mov rdx, [rsp + 40]
    mov r8, [rsp + 48]
    call CallNextHookEx
    add rsp, 56
    ret

dispatch:
    push rbx
    push rdi
    sub rsp, 72
    lea rcx, [apply_message]
    call RegisterWindowMessageW
    test eax, eax
    jz .fail
    mov [dispatch_message], eax
    mov dword [dispatch_ran], 0
    mov ecx, WH_CALLWNDPROC
    lea rdx, [hook_proc]
    mov r8, [module_handle]
    mov r9d, [ui_thread]
    call SetWindowsHookExW
    test rax, rax
    jz .fail
    mov rbx, rax
    mov rcx, [tray_window]
    mov edx, [dispatch_message]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp + 32], SMTO_BLOCK_ABORT
    mov qword [rsp + 40], 5000
    lea rax, [rsp + 56]
    mov [rsp + 48], rax
    call SendMessageTimeoutW
    mov edi, eax
    mov rcx, rbx
    call UnhookWindowsHookEx
    test edi, edi
    jz .fail
    cmp dword [dispatch_ran], 0
    je .unexpected
    mov eax, [dispatch_result]
    jmp .out
.fail:
    mov eax, E_UNEXPECTED
    jmp .out
.unexpected:
    mov eax, E_UNEXPECTED
.out:
    add rsp, 72
    pop rdi
    pop rbx
    ret

worker:
    sub rsp, 40
    mov ecx, EVENT_MODIFY_STATE
    xor edx, edx
    lea r8, [applied_event_name]
    call OpenEventW
    mov [applied_event], rax
    xor ecx, ecx
    mov edx, 1
    xor r8d, r8d
    lea r9, [restore_event_name]
    call CreateEventW
    mov [restore_event], rax
    test rax, rax
    jz .done
    call locate_root
    test eax, eax
    js .done
    call dispatch
    test eax, eax
    js .done
    mov rcx, [applied_event]
    test rcx, rcx
    jz .wait_restore
    call SetEvent
.wait_restore:
    mov rcx, [restore_event]
    mov edx, -1
    call WaitForSingleObject
    mov dword [restore_mode], 1
    call dispatch
.done:
    mov rcx, [restore_event]
    test rcx, rcx
    jz .applied_close
    call CloseHandle
.applied_close:
    mov rcx, [applied_event]
    test rcx, rcx
    jz .exit
    call CloseHandle
.exit:
    xor eax, eax
    add rsp, 40
    ret

DllMain:
    ; RCX=module, EDX=reason
    cmp edx, 1
    jne .ok
    mov [module_handle], rcx
    push rcx
    sub rsp, 48
    call DisableThreadLibraryCalls
    xor ecx, ecx
    xor edx, edx
    lea r8, [worker]
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    call CreateThread
    test rax, rax
    jz .attach_done
    mov rcx, rax
    call CloseHandle
.attach_done:
    add rsp, 48
    pop rcx
.ok:
    mov eax, 1
    ret
