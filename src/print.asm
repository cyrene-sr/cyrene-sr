NPRINT_FMT_CHAR = '%'

macro nprint txt, txt_len, [fmtarg] {
common
  fmt_cnt = 0
  push rax
  push rcx
  push rdx
  push r8
  push r9
  push r10
  push r15
  push r14
  push r13
  push r12
  push r11
  push rbp
  push rdi
  push rsi

  ; push them twice - first for length calcs, second for prints
  repeat 2
    reverse
      fmt_cnt = fmt_cnt + 1
      push fmtarg
    common
  end repeat

common
  fmt_cnt = fmt_cnt / 2

  mov r13, txt
  mov sil, NPRINT_FMT_CHAR
  mov rdx, txt_len
  
  ; use r12 to hold buffer length
  ; use r11 as register to pop fmt arg in
  ; use r15 to store index of '%'

  mov rdi, txt
  xor r12, r12
  repeat fmt_cnt
    mov sil, NPRINT_FMT_CHAR
    call index_of
    add r12, rax ; buffer_length += index_of('%')
    add rdi, rax ; txt = txt[index_of_%..]
    inc rdi ; extra +1 to skip '%' itself
    sub rdx, rax
    dec rdx
    pop r11 ; pop 'variadic' fmt argument from the stack
    mov rcx, r11 ; rcx is the argument of int_len
    call int_len
    add r12, rax ; buffer_length += int_len(args[i])
  end repeat

  add r12, rdx

  mov rbp, rsp
  sub rsp, r12
  mov r8, rsp

  mov rdi, txt
  mov rdx, txt_len
  mov r13, r8 ; preserve print buffer beginning

  repeat fmt_cnt
    mov sil, NPRINT_FMT_CHAR
    call index_of
    mov r15, rax ; index of %
    memcpy r8, rdi, r15
    ; exit 69
    add rdi, r15
    inc rdi ; skip '%'
    add r8, r15
    
    mov r14, rsp
    mov rsp, rbp
    pop r11 ; pop variadic
    mov rbp, rsp
    mov rsp, r14

    mov rcx, r11 ; rcx is the argument of int_len
    call int_len ;  we now will have length in rax

    ; print_int_to_buf(number: rax, len: rcx, destination: r8)
    mov rcx, rax
    mov rax, r11
    ; dst is r8 - everything is fine, no mov needed.
    call print_int_to_buf
    add r8, rcx
  end repeat

  mov r9, rdi
  mov r10, txt
  sub r9, r10
  mov r10, txt_len
  sub r10, r9
  memcpy r8, rdi, r10

  write STDOUT, r13, r12
  mov rsp, rbp

  pop rsi
  pop rdi
  pop rbp
  pop r11
  pop r12
  pop r13
  pop r14
  pop r15
  pop r10
  pop r9
  pop r8
  pop rdx
  pop rcx
  pop rax
}

; index_of(haystack: rdi, needle: rsi (sil), len: rdx) -> rax
index_of:
  push rdi
  push rsi
  push rdx
  push r8
  push r9

  xor r9, r9
  .index_of_loop:
    cmp rdx, 0
    mov rax, -1
    je .index_of_exit
    dec rdx
    mov rax, r9
    mov r8b, [rdi]
    cmp r8b, sil
    je .index_of_exit
    inc r9
    inc rdi
    jmp .index_of_loop
  
  .index_of_exit:
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    ret

macro memcpy dst, src, len {
  push rsi
  if ~ (src eq rsi)
    mov rsi, src
  end if
  push rdi
  if ~ (dst eq rdi)
    mov rdi, dst
  end if
  push rcx
  if ~ (len eq rcx)
    mov rcx, len
  end if

  cld
  rep movsb

  pop rcx
  pop rdi
  pop rsi
}

; print_int_to_buf(number: rax, len: rcx, destination: r8)
print_int_to_buf:
  ; save state of the registers that we will be using
  push rcx
  push rdx
  push r8
  push rax
  add r8, rcx
  test rax, rax
  jns .print_int_to_buf_loop
  neg rax
  .print_int_to_buf_loop:
    cdq ; prepare registers for `div`
    mov rcx, 10 ; divide by 10
    div rcx
    add rdx, '0' ; add 0x30 so it's an ASCII number
    dec r8
    mov byte [r8], dl ; put char on the stack
    cmp rax, 0 ; if div result is 0, number is finished
    jnz .print_int_to_buf_loop
  ; restore state of used registers
  pop rax
  test rax, rax
  jns .print_int_exit
  dec r8
  mov byte [r8], '-'
  .print_int_exit:
  pop r8
  pop rdx
  pop rcx
  ret

; int_len(number: rcx) -> count: rax
int_len:
  mov rax, rcx
  push rcx
  push rdx
  push r8
  mov r8, 0
  test rax, rax
  jns .int_len_loop
  neg rax
  inc r8
  .int_len_loop:
    cdq ; prepare registers for `div`
    mov rcx, 10 ; divide by 10
    div rcx
    inc r8
    cmp rax, 0 ; if div result is 0, number is finished
    jnz .int_len_loop
  mov rax, r8 ; return value
  ; restore state of used registers
  pop r8
  pop rdx
  pop rcx
  ret
