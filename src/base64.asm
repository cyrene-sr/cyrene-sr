base64_chars db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

; base64_encode(dst: rsi, bytes: rdi, count: rdx) -> post_encoding_pointer: rax
base64_encode:
  push rsi
  push rdi
  push rdx
  push r8
  push r9
  push r10
  push r11
  push r12
  push r13

  mov r11, rdi
  add r11, rdx

.base64_encode_loop:
  xor r8, r8
  xor r9, r9
  xor r10, r10

  cmp rdi, r11
  cmovl r8, [rdi] ; octet 1
  and r8, 0xFF
  inc rdi
  cmp rdi, r11
  cmovl r9, [rdi] ; octet 2
  and r9, 0xFF
  inc rdi
  cmp rdi, r11
  cmovl r10, [rdi] ; octet 3
  and r10, 0xFF
  inc rdi

  shl r8, 16
  shl r9, 8
  add r10, r8
  add r10, r9

  ; append char 1
  mov r12, r10
  shr r12, 18
  and r12, 0x3F
  mov r13, base64_chars
  add r13, r12
  mov r13, [r13]
  mov byte [rsi], r13b
  inc rsi

  ; append char 2
  mov r12, r10
  shr r12, 12
  and r12, 0x3F
  mov r13, base64_chars
  add r13, r12
  mov r13, [r13]
  mov byte [rsi], r13b
  inc rsi

  ; append char 3
  mov r12, r10
  shr r12, 6
  and r12, 0x3F
  mov r13, base64_chars
  add r13, r12
  mov r13, [r13]
  mov byte [rsi], r13b
  inc rsi

  ; append char 4
  mov r12, r10
  and r12, 0x3F
  mov r13, base64_chars
  add r13, r12
  mov r13, [r13]
  mov byte [rsi], r13b
  inc rsi

  cmp rdi, r11
  jl .base64_encode_loop
  
  push rsi
  .base64_padding_loop:
  cmp rdi, r11
  jle .base64_encode_exit
  dec rdi
  dec rsi
  mov byte [rsi], '='
  jmp .base64_padding_loop

  .base64_encode_exit:
  pop rax
  pop r13
  pop r12
  pop r11
  pop r10
  pop r9
  pop r8
  pop rdx
  pop rdi
  pop rsi
  ret

