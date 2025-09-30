WIRE_VARINT equ 0
WIRE_I64 equ 1
WIRE_LEN equ 2
WIRE_I32 equ 5

; dst = ((field_id << 3) | wire_type)
macro pb_make_tag dst, wire_type, field_id {
  mov dst, ((field_id shl 3) or wire_type)
}

; expecting buffer ptr in RSI, which will be advanced
macro pb_write_tag write_buf, wire_type, field_id {
  if ~ (write_buf eq rsi)
    mov rsi, write_buf
  end if

  pb_make_tag rdi, wire_type, field_id

  call encode_varint
}

; expecting buffer ptr in RSI, which will be advanced
macro pb_write_varint_raw write_buf, value {
  if ~ (write_buf eq rsi)
    mov rsi, write_buf
  end if

  mov rdi, value
  call encode_varint
}

; writes length prefix + copies bytes
; expecting buffer ptr in RSI, which will be advanced
macro pb_write_varint write_buf, field_id, value {
  if ~ (write_buf eq rsi)
    mov rsi, write_buf
  end if

  push rdi
  pb_write_tag rsi, WIRE_VARINT, field_id
  pb_write_varint_raw rsi, value
  pop rdi
}

; writes length prefix + copies bytes
; expecting buffer ptr in RSI, which will be advanced
macro pb_write_bytes write_buf, field_id, bytes, bytes_len {
  if ~ (write_buf eq rsi)
    mov rsi, write_buf
  end if

  push rdi
  pb_write_tag rsi, WIRE_LEN, field_id
  pb_write_varint_raw rsi, bytes_len
  mov rax, rsi
  memcpy rax, bytes, bytes_len
  add rsi, bytes_len
  pop rdi
}

MSB equ 0x80

; encode_varint(dst: rsi, value: rdi), rsi is advanced
encode_varint:

  push rdi
  push rax

.encode_varint_loop:
  cmp rdi, MSB
  jl .encode_varint_exit
  mov rax, rdi
  and rax, 0xFF
  or al, MSB
  mov byte [rsi], al
  inc rsi
  shr rdi, 7
  jmp .encode_varint_loop

.encode_varint_exit:
  mov byte [rsi], dil
  inc rsi

  pop rax
  pop rdi
  ret

; decode_varint(buf: rsi) -> rax: result, rsi is advanced
decode_varint:
  push r8
  push r9
  push r10
  xor rax, rax
  xor r8, r8 ; shift counter will be here

.decode_varint_loop:
  xor r9, r9
  xor r10, r10
  mov r9b, [rsi]
  mov r10, r9
  and r9, 0x7F
  mov cl, r8b
  shl r9, cl
  or rax, r9
  inc rsi
  add r8, 7
  and r10, MSB
  cmp r10, MSB
  je .decode_varint_loop
  pop r10
  pop r9
  pop r8
  ret ; result is already in rax
  
