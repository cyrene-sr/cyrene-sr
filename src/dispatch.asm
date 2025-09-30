format ELF64 executable

TCP_BACKLOG equ 100
TCP_BIND_PORT equ 10100

SEND_BUFFER_SIZE equ 16384
RECV_BUFFER_SIZE equ 16384

dispatch_rsp_buffer_size equ 1024
region_proto_buffer_size equ 128
gateway_rsp_buffer_size equ 2048

struc sockaddr_in family, port, addr {
  .sin_family dw family
  .sin_port dw (((port and 0xFF) shl 8) or ((port shr 8) and 0xFF))
  .sin_addr dd addr
  .sin_zero dq 0
}

macro strcmp buffer, expected, expected_len {
  push r8
  push r9
  push r10
  mov r8, buffer
  mov r9, expected
  mov r10, expected_len
  call strcmp_fn
  pop r10
  pop r9
  pop r8
}

segment readable executable
  include "syscalls.asm"
  include "print.asm"
  include "base64.asm"
  include "protobuf.asm"
  include "dispatch.pb.asm"
  entry start
  start:
    sub rsp, SEND_BUFFER_SIZE
    mov [send_buffer_ptr], rsp
    sub rsp, RECV_BUFFER_SIZE
    mov [recv_buffer_ptr], rsp

    write STDOUT, startup_splash, startup_splash_len

    socket AF_INET, SOCK_STREAM, 0
    mov [listener_fd], rax
    cmp rax, 0
    jl .socket_error

    sub rsp, SOCKOPT_LEN
    mov dword [rsp], 1 ; SO_REUSEADDR=1
    setsockopt [listener_fd], SOL_SOCKET, SO_REUSEADDR, rsp, SOCKOPT_LEN
    add rsp, SOCKOPT_LEN

    bind [listener_fd], bind_address, bind_address_len
    cmp rax, 0
    jl .bind_error

    listen [listener_fd], TCP_BACKLOG
    cmp rax, 0
    jl .listen_error
    nprint startup_msg, startup_msg_len, TCP_BIND_PORT

  .accept_loop:
    accept [listener_fd], accept_address, accept_address_len
    cmp rax, 0
    jl .accept_error

    push rax ; client socket

    ; extract ip octets into registers
    xor r8, r8
    xor r9, r9
    xor r10, r10
    xor r11, r11
    mov r15, accept_address.sin_addr
    mov r8b, [r15]
    mov r9b, [r15 + 1]
    mov r10b, [r15 + 2]
    mov r11b, [r15 + 3]

    ; dereference and rotate port
    xor r12, r12
    mov r12w, [accept_address.sin_port]
    bswap r12
    shr r12, 48

    nprint new_connection_trace_msg, new_connection_trace_msg_len, r8, r9, r10, r11, r12

    pop r15 ; client socket
    read r15, [recv_buffer_ptr], RECV_BUFFER_SIZE-1 ; -1 because we want one byte at the end for '\n'
    cmp rax, 0
    jle .finish_connection
    
    mov r14, rax
    nprint read_trace_msg, read_trace_msg_len, r14

    ; dispatch by method + path
    ; check if the method is 'GET'
    strcmp [recv_buffer_ptr], get_prefix, get_prefix_len
    cmp rax, 0
    je .serve_not_found ; serve a 404 if it's not 'GET'

    ; index_of(haystack: rdi, needle: rsi (sil), len: rdx) -> rax
    mov rdi, [recv_buffer_ptr]
    add rdi, get_prefix_len ; haystack
    mov sil, ' ' ; needle
    mov rdx, r14 ; length
    call index_of
    cmp rax, -1
    je .serve_not_found ; invalid request: no whitespace after path

    mov r14, rax
    mov r13, rdi
    add r13, r14
    mov byte [r13], 10 ; add a newline
    sub r13, r14
    inc r14
    write STDOUT, r13, r14

    strcmp r13, query_dispatch_route, query_dispatch_route_len
    cmp rax, 1
    je .serve_query_dispatch
    strcmp r13, query_gateway_route, query_gateway_route_len
    cmp rax, 1
    je .serve_query_gateway
    jmp .serve_not_found

  .finish_response:
    mov r14, rax
    sub r14, [send_buffer_ptr]
    write r15, [send_buffer_ptr], r14 ; TODO: check if full length was written. Shouldn't be a problem for now w/ relatively small buffers.
    cmp rax, 0
    jg .finish_connection
    nprint write_error_msg, write_error_msg_len, rax

  .finish_connection:
    close r15
    jmp .accept_loop

  .serve_not_found:
    ; build a 404 NOT FOUND response
    memcpy [send_buffer_ptr], http_not_found_headers, http_not_found_headers_len
    mov rax, [send_buffer_ptr]
    add rax, http_response_headers_len
    jmp .finish_response

  .serve_query_dispatch:
    ; start building a 200 OK response
    memcpy [send_buffer_ptr], http_response_headers, http_response_headers_len
    ; Allocate memory for "Dispatch" protobuf message
    sub rsp, dispatch_rsp_buffer_size
    mov r13, rsp ; buffer is now in r13

    ; Allocate memory for sub-message "Region"
    sub rsp, region_proto_buffer_size
    mov r10, rsp ; buffer is now in r10
    push r13 ; preserve address of the first buffer
    mov rsi, r13

    macro add_region name, url, env, title {
      push rsi
      encode_region_pb r10, name, url, env, title

      mov r9, rsi
      sub r9, r10 ; r9 now has encoding length of the 'Region'

      pop r13 ; pop address of the first buffer
      pb_write_bytes r13, dispatch_region_list_field_id, r10, r9
    }
    
    add_region cyrene_sr, "http://127.0.0.1:10100/query_gateway", "2", "Cyrene-SR"
    add_region cyrene_sr_2, "http://127.0.0.1:10100/query_gateway", "2", "Cyrene-SR"
    add_region cyrene_sr_3, "http://127.0.0.1:10100/query_gateway", "2", "Cyrene-SR"

    pop r13 ; pop address of the first buffer
    add rsp, region_proto_buffer_size ; deallocate Region buffer

    sub rsi, r13 ; cur_pos - buffer (current - beginning)
    mov r14, rsi ; r14 now holds body len

    ; encode payload as base64 to send_buffer
    mov rsi, [send_buffer_ptr]
    add rsi, http_response_headers_len ; destination
    mov rdi, r13 ; bytes
    mov rdx, r14 ; length
    call base64_encode ; returns post_encoding_pointer to RAX

    add rsp, dispatch_rsp_buffer_size ; deallocate Dispatch buffer
    jmp .finish_response

  .serve_query_gateway:
    ; start building a 200 OK response
    memcpy [send_buffer_ptr], http_response_headers, http_response_headers_len
    ; Allocate memory for "Gateserver" protobuf message
    sub rsp, gateway_rsp_buffer_size
    mov r13, rsp ; buffer is now in r13
    mov rsi, r13

    pb_write_varint rsi, gateserver_port_field_id, 23301 ; gateway port
    pb_write_varint rsi, gateserver_use_tcp_field_id, 1
    pb_write_varint rsi, gateserver_enable_version_update_field_id, 1
    pb_write_varint rsi, gateserver_enable_design_data_version_update_field_id, 1
    pb_write_bytes rsi, gateserver_ip_field_id, gateserver_ip, gateserver_ip_len
    pb_write_bytes rsi, gateserver_lua_url_field_id, lua_url, lua_url_len
    pb_write_bytes rsi, gateserver_asset_bundle_url_field_id, asb_url, asb_url_len
    pb_write_bytes rsi, gateserver_ex_resource_url_field_id, design_data_url, design_data_url_len

    sub rsi, r13 ; cur_pos - buffer (current - beginning)
    mov r14, rsi ; r14 now holds body len

    ; encode payload as base64 to send_buffer
    mov rsi, [send_buffer_ptr]
    add rsi, http_response_headers_len ; destination
    mov rdi, r13 ; bytes
    mov rdx, r14 ; length
    call base64_encode ; returns post_encoding_pointer to RAX

    add rsp, gateway_rsp_buffer_size ; deallocate Gateserver buffer
    jmp .finish_response

  .socket_error:
    nprint socket_error_msg, socket_error_msg_len, rax
    jmp .exit_error

  .bind_error:
    nprint bind_error_msg, bind_error_msg_len, rax
    jmp .exit_error

  .listen_error:
    nprint listen_error_msg, listen_error_msg_len, rax
    jmp .exit_error

  .accept_error:
    nprint accept_error_msg, accept_error_msg_len, rax
    jmp .accept_loop ; accept fail is usually not fatal, continue accepting connections

  .exit_error:
    close [listener_fd]
    write STDOUT, fatal_error_msg, fatal_error_msg_len
    exit EXIT_FAILURE

; strcmp(buffer: r8, expected: r9, expected_len: r10) -> result: rax
strcmp_fn:
  push rdi
  push rsi
  .strcmp_loop:
  mov rax, 1
  cmp r10, 0
  jle .strcmp_exit
  dec r10
  mov byte dil, [r8]
  mov byte sil, [r9]
  inc r8
  inc r9
  cmp dil, sil
  je .strcmp_loop
  xor rax, rax
  .strcmp_exit:
  pop rsi
  pop rdi
  ret

segment readable writeable
  listener_fd dq 0
  bind_address sockaddr_in AF_INET, TCP_BIND_PORT, 0
  bind_address_len = $ - bind_address

  accept_address sockaddr_in 0, 0, 0
  accept_address_len dq $ - bind_address

  recv_buffer_ptr dq 0
  send_buffer_ptr dq 0

  startup_msg db "INFO: dispatch server is listening at 0.0.0.0:%", 10
  startup_msg_len = $ - startup_msg

  fatal_error_msg db "fatal error occurred, exiting.", 10
  fatal_error_msg_len = $ - fatal_error_msg

  socket_error_msg db "ERROR: socket() returned: %", 10
  socket_error_msg_len = $ - socket_error_msg

  bind_error_msg db "ERROR: bind() returned: %", 10
  bind_error_msg_len = $ - bind_error_msg

  listen_error_msg db "ERROR: listen() returned: %", 10
  listen_error_msg_len = $ - listen_error_msg

  accept_error_msg db "ERROR: accept() returned: %, skipping incoming connection", 10
  accept_error_msg_len = $ - accept_error_msg
  
  new_connection_trace_msg db "INFO: new connection from %.%.%.%:%", 10
  new_connection_trace_msg_len = $ - new_connection_trace_msg

  read_trace_msg db "INFO: received % bytes from client", 10
  read_trace_msg_len = $ - read_trace_msg

  write_error_msg db "ERROR: write() returned: %", 10
  write_error_msg_len = $ - write_error_msg

  get_prefix db "GET "
  get_prefix_len = $ - get_prefix

  query_dispatch_route db "/query_dispatch"
  query_dispatch_route_len = $ - query_dispatch_route

  query_gateway_route db "/query_gateway"
  query_gateway_route_len = $ - query_gateway_route

  http_response_headers db "HTTP/1.1 200 OK", 13, 10
                        db "Content-Type: text/plain", 13, 10
                        db "Connection: close", 13, 10
                        db 13, 10
  http_response_headers_len = $ - http_response_headers

  http_not_found_headers db "HTTP/1.1 404 NOT FOUND", 13, 10
                        db "Content-Type: text/plain", 13, 10
                        db "Connection: close", 13, 10
                        db 13, 10
  http_not_found_headers_len = $ - http_not_found_headers

  ; query_gateway content
  gateserver_ip db "127.0.0.1"
  gateserver_ip_len = $ - gateserver_ip

  lua_url db "https://autopatchcn.bhsr.com/lua/BetaLive/output_12103115_ee78155e9867_3626f0948d93e2"
  lua_url_len = $ - lua_url

  asb_url db "https://autopatchcn.bhsr.com/asb/BetaLive/output_12066992_f083970b907e_999074cab6dce6"
  asb_url_len = $ - asb_url

  design_data_url db "https://autopatchcn.bhsr.com/design_data/BetaLive/output_12114942_e99cbde25134_e63a6b835f17f9"
  design_data_url_len = $ - design_data_url

  startup_splash db "   ____                          ____  ____  ", 10
                 db "  / ___|   _ _ __ ___ _ __   ___/ ___||  _ \ ", 10
                 db " | |  | | | | '__/ _ \ '_ \ / _ \___ \| |_) |", 10
                 db " | |__| |_| | | |  __/ | | |  __/___) |  _ < ", 10
                 db "  \____\__, |_|  \___|_| |_|\___|____/|_| \_\", 10
                 db "       |___/                                 ", 10
  startup_splash_len = $ - startup_splash
