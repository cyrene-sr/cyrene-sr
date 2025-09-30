; syscall numbers
NR_read equ 0
NR_write equ 1
NR_close equ 3
NR_socket equ 41
NR_accept equ 43
NR_bind equ 49
NR_listen equ 50
NR_setsockopt equ 54
NR_exit equ 60
NR_clock_gettime equ 228

; System Constants
EXIT_SUCCESS equ 0
EXIT_FAILURE equ 1
STDOUT equ 1

; Network
AF_INET equ 2
SOCK_STREAM equ 1
SOL_SOCKET equ 1
SO_REUSEADDR equ 2
SOCKOPT_LEN equ 4

macro syscall1 nr, a1 {
  mov rdi, a1
  mov rax, nr
  syscall
}

macro syscall2 nr, a1, a2 {
  mov rdi, a1
  mov rsi, a2
  mov rax, nr
  syscall
}

macro syscall3 nr, a1, a2, a3 {
  mov rdi, a1
  mov rsi, a2
  mov rdx, a3
  mov rax, nr
  syscall
}

macro syscall5 nr, a1, a2, a3, a4, a5 {
  mov rdi, a1
  mov rsi, a2
  mov rdx, a3
  mov r10, a4
  mov r8,  a5
  mov rax, nr
  syscall
}

macro read fd, buf, count {
  syscall3 NR_read, fd, buf, count
}

macro write fd, buf, count {
  syscall3 NR_write, fd, buf, count
}

macro close fd {
  syscall1 NR_close, fd
}

macro socket family, type, protocol {
  syscall3 NR_socket, family, type, protocol
}

macro bind fd, addr, addrlen {
  syscall3 NR_bind, fd, addr, addrlen
}

macro accept fd, addr, addrlen {
  syscall3 NR_accept, fd, addr, addrlen
}

macro listen fd, backlog {
  syscall2 NR_listen, fd, backlog
}

macro setsockopt fd, level, optname, optval, optlen {
  syscall5 NR_setsockopt, fd, level, optname, optval, optlen
}

macro exit exit_code {
  syscall1 NR_exit, exit_code
}

macro clock_gettime which_clock, timespec {
  syscall2 NR_clock_gettime, which_clock, timespec
}
