bits 64
default rel
global start

extern GetModuleFileNameW
extern GetTempPathW
extern GetTempFileNameW
extern CopyFileW
extern FindWindowW
extern GetWindowThreadProcessId
extern OpenProcess
extern VirtualAllocEx
extern VirtualFreeEx
extern WriteProcessMemory
extern GetModuleHandleW
extern GetProcAddress
extern CreateRemoteThread
extern WaitForSingleObject
extern GetExitCodeThread
extern CreateEventW
extern OpenEventW
extern SetEvent
extern CloseHandle
extern ExitProcess

%define PROCESS_ACCESS      0x043A
%define MEM_COMMIT_RESERVE  0x3000
%define MEM_RELEASE         0x8000
%define PAGE_READWRITE      4
%define WAIT_OBJECT_0       0

section .rdata
    tray_class dw 'S','h','e','l','l','_','T','r','a','y','W','n','d',0
    dll_name dw 'g','l','a','s','s','b','a','r','_','d','i','r','e','c','t','.','d','l','l',0
    temp_prefix dw 'g','b','r',0
    kernel_name dw 'k','e','r','n','e','l','3','2','.','d','l','l',0
    loadlibrary_name db 'LoadLibraryW',0
align 2
    applied_event_name dw 'L','o','c','a','l','\','G','l','a','s','s','b','a','r','A','p','p','l','i','e','d',0
    restore_event_name dw 'L','o','c','a','l','\','G','l','a','s','s','b','a','r','R','e','s','t','o','r','e',0

section .bss
align 16
    source_path resw 1024
    temp_dir resw 1024
    staged_path resw 1024
    target_pid resd 1
    remote_bytes resq 1

section .text

replace_filename:
    mov r8, rcx
.scan:
    mov ax, [rcx]
    test ax, ax
    jz .copy
    cmp ax, '\'
    jne .next
    lea r8, [rcx + 2]
.next:
    add rcx, 2
    jmp .scan
.copy:
    mov rcx, r8
.copy_loop:
    mov ax, [rdx]
    mov [rcx], ax
    add rcx, 2
    add rdx, 2
    test ax, ax
    jnz .copy_loop
    ret

wide_bytes:
    mov rax, rcx
.loop:
    cmp word [rax], 0
    je .done
    add rax, 2
    jmp .loop
.done:
    sub rax, rcx
    add rax, 2
    ret

start:
    and rsp, -16
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 96

    ; If a resident Glassbar owns the original brush, this invocation toggles
    ; it off instead of injecting another copy.
    mov ecx, 2
    xor edx, edx
    lea r8, [restore_event_name]
    call OpenEventW
    test rax, rax
    jz .apply
    mov rbx, rax
    mov rcx, rax
    call SetEvent
    mov rcx, rbx
    call CloseHandle
    xor ecx, ecx
    call ExitProcess

.apply:
    xor ecx, ecx
    lea rdx, [source_path]
    mov r8d, 1024
    call GetModuleFileNameW
    test eax, eax
    jz .fail
    lea rcx, [source_path]
    lea rdx, [dll_name]
    call replace_filename

    mov ecx, 1024
    lea rdx, [temp_dir]
    call GetTempPathW
    test eax, eax
    jz .fail
    lea rcx, [temp_dir]
    lea rdx, [temp_prefix]
    xor r8d, r8d
    lea r9, [staged_path]
    call GetTempFileNameW
    test eax, eax
    jz .fail
    lea rcx, [source_path]
    lea rdx, [staged_path]
    xor r8d, r8d
    call CopyFileW
    test eax, eax
    jz .fail

    xor ecx, ecx
    mov edx, 1
    xor r8d, r8d
    lea r9, [applied_event_name]
    call CreateEventW
    test rax, rax
    jz .fail
    mov r12, rax

    lea rcx, [tray_class]
    xor edx, edx
    call FindWindowW
    test rax, rax
    jz .fail_event
    mov rcx, rax
    lea rdx, [target_pid]
    call GetWindowThreadProcessId
    test eax, eax
    jz .fail_event

    mov ecx, PROCESS_ACCESS
    xor edx, edx
    mov r8d, [target_pid]
    call OpenProcess
    test rax, rax
    jz .fail_event
    mov r13, rax

    lea rcx, [staged_path]
    call wide_bytes
    mov [remote_bytes], rax
    mov rcx, r13
    xor edx, edx
    mov r8, rax
    mov r9d, MEM_COMMIT_RESERVE
    mov qword [rsp + 32], PAGE_READWRITE
    call VirtualAllocEx
    test rax, rax
    jz .fail_process
    mov r14, rax

    mov rcx, r13
    mov rdx, r14
    lea r8, [staged_path]
    mov r9, [remote_bytes]
    mov qword [rsp + 32], 0
    call WriteProcessMemory
    test eax, eax
    jz .fail_remote

    lea rcx, [kernel_name]
    call GetModuleHandleW
    test rax, rax
    jz .fail_remote
    mov rcx, rax
    lea rdx, [loadlibrary_name]
    call GetProcAddress
    test rax, rax
    jz .fail_remote
    mov r15, rax

    mov rcx, r13
    xor edx, edx
    xor r8d, r8d
    mov r9, r15
    mov qword [rsp + 32], r14
    mov qword [rsp + 40], 0
    mov qword [rsp + 48], 0
    call CreateRemoteThread
    test rax, rax
    jz .fail_remote
    mov rbx, rax

    mov rcx, rbx
    mov edx, 15000
    call WaitForSingleObject
    cmp eax, WAIT_OBJECT_0
    jne .fail_thread
    mov rcx, rbx
    lea rdx, [rsp + 80]
    call GetExitCodeThread
    test eax, eax
    jz .fail_thread
    cmp dword [rsp + 80], 0
    je .fail_thread

    mov rcx, r12
    mov edx, 15000
    call WaitForSingleObject
    cmp eax, WAIT_OBJECT_0
    jne .fail_thread

    mov rcx, rbx
    call CloseHandle
    mov rcx, r13
    mov rdx, r14
    xor r8d, r8d
    mov r9d, MEM_RELEASE
    call VirtualFreeEx
    mov rcx, r13
    call CloseHandle
    mov rcx, r12
    call CloseHandle
    xor ecx, ecx
    call ExitProcess

.fail_thread:
    mov rcx, rbx
    call CloseHandle
.fail_remote:
    mov rcx, r13
    mov rdx, r14
    xor r8d, r8d
    mov r9d, MEM_RELEASE
    call VirtualFreeEx
.fail_process:
    mov rcx, r13
    call CloseHandle
.fail_event:
    mov rcx, r12
    call CloseHandle
.fail:
    mov ecx, 1
    call ExitProcess
