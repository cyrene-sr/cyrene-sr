format ELF64 executable

TCP_BACKLOG equ 100
TCP_BIND_PORT equ 23301

RECV_BUFFER_SIZE equ 16384
SEND_BUFFER_SIZE equ 16384

PACKET_OVERHEAD_SIZE equ 16
PACKET_CMD_ID_OFFSET equ 4
PACKET_HEAD_SIZE_OFFSET equ 6
PACKET_BODY_SIZE_OFFSET equ 8
HEAD_MAGIC equ 0x14C7749D
TAIL_MAGIC equ 0xC852A1D7

; maybe move this to syscalls.asm?
struc sockaddr_in family, port, addr {
  .sin_family dw family
  .sin_port dw (((port and 0xFF) shl 8) or ((port shr 8) and 0xFF))
  .sin_addr dd addr
  .sin_zero dq 0
}

macro do_setsockopt fd, opt, optval {
  sub rsp, SOCKOPT_LEN
  mov dword [rsp], optval
  setsockopt fd, SOL_SOCKET, opt, rsp, SOCKOPT_LEN
  add rsp, SOCKOPT_LEN
}

segment readable executable
entry start
  include "syscalls.asm"
  include "print.asm"
  include "protobuf.asm"
  include "gameserver.pb.asm"
  include "dummy_handlers.asm"
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

  do_setsockopt [listener_fd], SO_REUSEADDR, 1
  
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
  ; TODO: maybe move this to macro
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

  push 0 ; current recv buffer position

.recv_loop:
  pop r14 ; previous recv buffer position
  pop r15 ; client FD

  cmp r14, PACKET_OVERHEAD_SIZE
  jge .skip_socket_read

.socket_read:
  mov r9, [recv_buffer_ptr]
  add r9, r14 ; recv_buffer[read_pos..]
  mov r10, RECV_BUFFER_SIZE
  sub r10, r14 ; recv_buffer_size - read_pos
  read r15, r9, r10
  push r15 ; save client FD
  push r14
  cmp rax, 0
  jle .close_connection

  pop r14
  add rax, r14 ; recvnum + read_pos
  push rax
  jmp .packet_decode_begin

.skip_socket_read:
  push r15
  push r14

.packet_decode_begin:
  mov rdi, [recv_buffer_ptr]
  xor rax, rax
  mov eax, [rdi]
  cmp eax, HEAD_MAGIC
  jne .head_magic_mismatch

  xor rsi, rsi
  add rdi, PACKET_HEAD_SIZE_OFFSET
  xor eax, eax
  mov ax, [rdi] ; eax now has head_size (big endian tho)
  bswap eax
  shr eax, 16

  add rdi, PACKET_BODY_SIZE_OFFSET-PACKET_HEAD_SIZE_OFFSET
  mov esi, [rdi] ; esi now has body size (big endian again)
  bswap esi

  add eax, esi
  add eax, PACKET_OVERHEAD_SIZE

  pop r10 ; packet length
  push r10 ; keep it on stack. May also use `mov r10, [rsp]` instead of prev instruction then..?
  cmp r10, rax ; check if we received enough bytes
  jl .packet_not_complete

  push rax ; push consumed length to the stack so then later we pop it and adjust recv buffer.
  xor rax, rax
  mov rdi, [recv_buffer_ptr]
  add rdi, PACKET_CMD_ID_OFFSET
  mov ax, [rdi]
  bswap eax
  shr eax, 16
  nprint recv_cmd_id_trace_msg, recv_cmd_id_trace_msg_len, rax

  ; 'handle' the packet..
  cmp rax, CmdPlayerGetTokenCsReq
  je .handle_player_get_token
  cmp rax, CmdPlayerLoginCsReq
  je .handle_player_login
  cmp rax, CmdPlayerHeartBeatCsReq
  je .handle_player_heart_beat
  cmp rax, CmdGetMissionStatusCsReq
  je .handle_get_mission_status
  cmp rax, CmdGetAvatarDataCsReq
  je .handle_get_avatar_data
  cmp rax, CmdGetBagCsReq
  je .handle_get_bag_data
  cmp rax, CmdSetPlayerOutfitCsReq
  je .handle_set_player_outfit
  cmp rax, CmdGetCurLineupDataCsReq
  je .handle_get_cur_lineup_data
  cmp rax, CmdGetCurSceneInfoCsReq
  je .handle_get_cur_scene_info
  cmp rax, CmdStartCocoonStageCsReq
  je .handle_start_cocoon_stage
  cmp rax, CmdPVEBattleResultCsReq
  je .handle_pve_battle_result
  paste_dummy_cmps
  jmp .post_handle
  
; A handler should fill the following registers:
; R8 - packet body length
; R9 - Cmd ID (not byte-swapped, just native endian)
.send_rsp:
  mov r13, [send_buffer_ptr] ; ..or `sub r13, PACKET_BODY_SIZE_OFFSET+4` ?
  mov dword [r13], HEAD_MAGIC
  add r13, 4
  bswap r9d
  shr r9d, 16
  mov word [r13], r9w
  add r13, 2
  mov word [r13], 0 ; head size
  add r13, 2
  bswap r8d ; swap bytes because endianness
  mov dword [r13], r8d
  bswap r8d ; swap it back!
  add r13, 4
  add r13, r8
  mov dword [r13], TAIL_MAGIC

  add r8, PACKET_OVERHEAD_SIZE

  mov r15, [rsp+16]
  write r15, [send_buffer_ptr], r8
  
.post_handle:
  pop r10 ; consumed length
  pop r11 ; recv buffer poisition

  mov r12, [recv_buffer_ptr]
  add r12, r10 ; r12 = recv_buffer[consumed_length..]

  sub r11, r10 ; recv_buffer_pos - consumed_length

  memcpy [recv_buffer_ptr], r12, r11 ; copy leftover bytes after packet
  push r11 ; push updated recv buffer position to the stack so then recv_loop will pop it

  ; TODO: maybe also check somewhere if we have enough bytes to read next packet right away, or at least try to do so. Maybe just jump to packet_decode_begin, but I'm not sure.
  jmp .recv_loop

.handle_player_get_token:
  ; 'encode' PlayerGetTokenScRsp
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  pb_write_varint rsi, PlayerGetTokenScRsp.uid, 1337
  sub rsi, r13 ; rsi now has body len
  mov r8, rsi ; r8 = body_len
  mov r9, CmdPlayerGetTokenScRsp
  jmp .send_rsp
.handle_player_login:
  ; encode PlayerLoginScRsp
  ; allocate a buffer for PlayerBasicInfo
  sub rsp, 256
  mov r13, rsp
  mov rsi, r13
  pb_write_varint rsi, PlayerBasicInfo.level, 5
  pb_write_varint rsi, PlayerBasicInfo.stamina, 300
  pb_write_bytes rsi, PlayerBasicInfo.nickname, player_nickname_str, player_nickname_str_len
  mov r10, rsi ; r10 = cur_buf_pos
  sub r10, r13 ; r10 = cur_buf_pos - buf_begin (length)
  mov r12, r13
  
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  pb_write_varint rsi, PlayerLoginScRsp.stamina, 300
  pb_write_bytes rsi, PlayerLoginScRsp.basic_info, r12, r10 ; write PlayerBasicInfo buffer
  add rsp, 256 ; deallocate PlayerBasicInfo buffer

  sub rsi, r13 ; rsi now has body len
  mov r8, rsi ; r8 = body_len
  mov r9, CmdPlayerLoginScRsp
  jmp .send_rsp
.handle_player_heart_beat:
  ; prepare recv buffer for decoding, maybe extract this in macro later. It's repeated for GetMissionStatus
  mov rdi, [recv_buffer_ptr]
  xor rsi, rsi
  add rdi, PACKET_HEAD_SIZE_OFFSET
  xor rax, rax
  mov ax, [rdi] ; eax now has head_size (big endian tho)
  bswap eax
  shr eax, 16 ; rax has head_size

  add rdi, PACKET_BODY_SIZE_OFFSET-PACKET_HEAD_SIZE_OFFSET
  mov esi, [rdi] ; esi now has body size (big endian again)
  bswap esi

  add rdi, 4 ; skip body_len that we've just read
  add rdi, rax ; skip PacketHead data, RDI has req buffer now
  
  mov r12, rsi ; r12 has req body length
  add r12, rdi ; r12 has req body end pointer
  
  xor rax, rax ; client_time_ms default val
  cmp rdi, r12
  je .post_read
  mov rsi, rdi
  call decode_varint
  cmp rax, ((PlayerHeartBeatCsReq.client_time_ms shl 3) or WIRE_VARINT)
  jne .post_read
  call decode_varint
.post_read:
  mov r14, rax ; client_time_ms
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  pb_write_varint rsi, PlayerHeartBeatScRsp.client_time_ms, r14

  call get_timestamp_ms
  mov r14, rax
  pb_write_varint rsi, PlayerHeartBeatScRsp.server_time_ms, r14
  pb_write_bytes rsi, PlayerHeartBeatScRsp.download_data, heartbeat_payload, heartbeat_payload_len

  sub rsi, r13 ; rsi now has body len
  mov r8, rsi ; r8 = body_len
  mov r9, CmdPlayerHeartBeatScRsp
  jmp .send_rsp
.handle_get_avatar_data:
  ; GetAvatarDataScRsp
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  push r13 ; preserve send buffer beginning
  
  pb_write_varint rsi, GetAvatarDataScRsp.is_get_all, 1
  mov r15, rsi ; save current rsp buffer pos

  macro pb_encode_avatar_data id, level, promotion, rank {
    sub rsp, 128 ; allocate 128 bytes for 'Avatar'
    mov rsi, rsp
    pb_write_varint rsi, Avatar.base_avatar_id, id
    pb_write_varint rsi, Avatar.level, level
    pb_write_varint rsi, Avatar.promotion, promotion
    pb_write_varint rsi, Avatar.rank, rank
    mov r14, rsi
    sub r14, rsp ; rsp has beginning of the buffer. R14 = cur - begin = length
    mov r12, rsp
    mov rsi, r15 ; rsi now has rsp buffer pos
    pb_write_bytes rsi, GetAvatarDataScRsp.avatar_list, r12, r14
    mov r15, rsi ; current rsp buffer pos
    add rsp, 128 ; deallocate 128 bytes of 'Avatar' buffer
  }

  macro pb_encode_avatar_data_list [avatar_id] {
  forward
    pb_encode_avatar_data avatar_id, 80, 6, 6
  }

  pb_encode_avatar_data_list 1415, 1401, 1003, 1005, 8001

  pop r14 ; rsp buffer beginning
  sub r15, r14 ; cur - begin
  mov r8, r15 ; r8 = body_len
  mov r9, CmdGetAvatarDataScRsp
  jmp .send_rsp

.handle_get_bag_data:
  ; GetBagScRsp
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 
  mov rsi, r13
  push r13
  
  mov r15, rsi

  sub rsp, 64 
  mov rsi, rsp
  pb_write_varint rsi, Material.tid, 227001
  pb_write_varint rsi, Material.num, 1
  mov r14, rsi
  sub r14, rsp 
  mov r12, rsp
  mov rsi, r15 
  pb_write_bytes rsi, GetBagScRsp.material_list, r12, r14
  mov r15, rsi 
  add rsp, 64 

  sub rsp, 64
  mov rsi, rsp
  pb_write_varint rsi, Material.tid, 227002
  pb_write_varint rsi, Material.num, 1
  mov r14, rsi
  sub r14, rsp
  mov r12, rsp
  mov rsi, r15
  pb_write_bytes rsi, GetBagScRsp.material_list, r12, r14
  mov r15, rsi
  add rsp, 64

  pop r14 
  sub r15, r14
  mov r8, r15 
  mov r9, CmdGetBagScRsp
  jmp .send_rsp

.handle_set_player_outfit:
  ; SetPlayerOutfitScRsp
  mov rdi, [recv_buffer_ptr]
  add rdi, PACKET_HEAD_SIZE_OFFSET
  xor rax, rax
  mov ax, [rdi]
  bswap eax
  shr eax, 16            

  add rdi, PACKET_BODY_SIZE_OFFSET - PACKET_HEAD_SIZE_OFFSET
  mov esi, [rdi]
  bswap esi               

  add rdi, 4
  add rdi, rax             
  mov r12, rsi
  add r12, rdi             

  mov rsi, rdi
  call decode_varint
  mov rdi, rsi
  cmp rax, ((SetPlayerOutfitCsReq.ENFKEIBDLLF shl 3) or WIRE_LEN)
  jne .send_outfit

  call decode_varint
  mov rcx, rax            
  mov rbx, rsi             
  add rsi, rcx
  mov rdi, rsi
.send_outfit:
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4
  mov rsi, r13

  pb_write_bytes rsi, PlayerSyncScNotify.ENFKEIBDLLF, rbx, rcx
  mov r15, rsi
  sub r15, r13
  mov r8, r15
  mov r9, CmdPlayerSyncScNotify
  jmp .send_rsp
  
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4
  mov rsi, r13

  pb_write_varint rsi, SetPlayerOutfitScRsp.retcode, 0
  mov r15, rsi
  sub r15, r13
  mov r8, r15
  mov r9, CmdSetPlayerOutfitScRsp
  jmp .send_rsp

.handle_get_cur_lineup_data:
  ; GetCurLineupDataScRsp

  sub rsp, 128 ; allocate 128 bytes for 'LineupInfo'
  mov rsi, rsp
  pb_write_varint rsi, LineupInfo.mp, 5
  pb_write_varint rsi, LineupInfo.max_mp, 5
  pb_write_bytes rsi, LineupInfo.name, lineup_name_str, lineup_name_str_len
  mov r8, rsi ; LineupInfo buffer cur pos

  sub rsp, 128 ; allocate 128 bytes for 'LineupAvatar'
  mov rsi, rsp
  pb_write_varint rsi, LineupAvatar.id, 1415
  pb_write_varint rsi, LineupAvatar.hp, 10000
  pb_write_varint rsi, LineupAvatar.avatar_type, AVATAR_FORMAL_TYPE
  push rsi
  
  sub rsp, 32 ; allocate 32 bytes for 'SpBarInfo'
  mov rsi, rsp
  pb_write_varint rsi, SpBarInfo.sp_cur, 10000
  pb_write_varint rsi, SpBarInfo.sp_need, 10000
  mov r14, rsi
  sub r14, rsp
  mov r12, rsp
  mov rsi, [rsp+32]
  pb_write_bytes rsi, LineupAvatar.sp_bar, r12, r14
  add rsp, 32 ; deallocate SpBarInfo buffer
  add rsp, 8 ; discard pushed rsi

  mov r14, rsi
  sub r14, rsp ; rsp has beginning of the buffer. R14 = cur - begin = length
  mov r12, rsp
  mov rsi, r8 ; rsi now has LineupInfo buffer pos
  pb_write_bytes rsi, LineupInfo.avatar_list, r12, r14
  mov r8, rsi ; current LineupInfo buffer pos
  add rsp, 128 ; deallocate 128 bytes of 'LineupAvatar' buffer

  mov r14, rsi
  sub r14, rsp
  mov r12, rsp

  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13

  pb_write_bytes rsi, GetCurLineupDataScRsp.lineup, r12, r14
  mov r15, rsi
  add rsp, 128 ; deallocate 128 bytes of 'LineupInfo' buffer

  sub r15, r13 ; cur - begin
  mov r8, r15 ; r8 = body_len
  mov r9, CmdGetCurLineupDataScRsp
  jmp .send_rsp

.handle_get_cur_scene_info:
  ; GetCurSceneInfoScRsp

  sub rsp, 32 ; allocate 32 bytes for 'Vector'
  mov rsi, rsp
  pb_write_varint rsi, Vector.x, 1139
  pb_write_varint rsi, Vector.y, 38728
  pb_write_varint rsi, Vector.z, 8960
  mov r8, rsi
  sub r8, rsp ; Vector buffer length

  sub rsp, 32 ; allocate 32 bytes for 'MotionInfo'
  mov rsi, rsp
  mov r9, rsp
  add r9, 32 ; Vector buffer
  pb_write_bytes rsi, MotionInfo.pos, r9, r8
  pb_write_bytes rsi, MotionInfo.rot, r9, 0 ; rotation vector is empty
  mov r10, rsi
  sub r10, rsp ; MotionInfo buffer length

  sub rsp, 32 ; allocate 32 bytes for 'ScenePropInfo'
  mov rsi, rsp
  pb_write_varint rsi, ScenePropInfo.prop_id, 808
  pb_write_varint rsi, ScenePropInfo.prop_state, 1
  mov r8, rsi
  sub r8, rsp ; ScenePropInfo buffer length

  sub rsp, 128 ; allocate 128 bytes for 'SceneEntityInfo'
  mov rsi, rsp
  mov r9, rsp
  add r9, (128+32) ; MotionInfo
  pb_write_bytes rsi, SceneEntityInfo.motion, r9, r10
  mov r9, rsp
  add r9, 128 ; ScenePropInfo
  pb_write_bytes rsi, SceneEntityInfo.prop, r9, r8
  pb_write_varint rsi, SceneEntityInfo.group_id, 19
  pb_write_varint rsi, SceneEntityInfo.inst_id, 300001
  pb_write_varint rsi, SceneEntityInfo.entity_id, 1337
  mov r8, rsi
  sub r8, rsp ; SceneEntityInfo buffer length

  sub rsp, 128 ; allocate 128 bytes for 'SceneEntityGroup'
  mov rsi, rsp
  mov r9, rsp
  add r9, 128 ; SceneEntityInfo
  pb_write_bytes rsi, SceneEntityGroup.entity_list, r9, r8
  pb_write_varint rsi, SceneEntityGroup.group_id, 19
  pb_write_varint rsi, SceneEntityGroup.state, 1
  mov r8, rsi
  sub r8, rsp ; SceneEntityGroup buffer length

  sub rsp, 256 ; allocate 256 bytes for 'SceneInfo'
  mov rsi, rsp
  pb_write_varint rsi, SceneInfo.plane_id, 20101
  pb_write_varint rsi, SceneInfo.floor_id, 20101001
  pb_write_varint rsi, SceneInfo.entry_id, 2010101
  pb_write_varint rsi, SceneInfo.game_mode_type, 1
  pb_write_varint rsi, SceneInfo.world_id, 201
  mov r9, rsp
  add r9, 256 ; SceneEntityGroup
  pb_write_bytes rsi, SceneInfo.entity_group_list, r9, r8

  mov r14, rsi
  sub r14, rsp
  mov r12, rsp

  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  pb_write_bytes rsi, GetCurSceneInfoScRsp.scene, r12, r14
  mov r15, rsi
  add rsp, (256+128+128+32+32+32) ; deallocate all this stack mess. SceneInfo+SceneEntityGroup+SceneEntityInfo+ScenePropInfo+MotionInfo+Vector
  ; add rsp, 128 ; deallocate 128 bytes of 'SceneInfo' buffer

  sub r15, r13 ; cur - begin
  mov r8, r15 ; r8 = body_len
  mov r9, CmdGetCurSceneInfoScRsp
  jmp .send_rsp
.handle_start_cocoon_stage:
  sub rsp, 32 ; SceneMonsterInfo
  mov rsi, rsp
  pb_write_varint rsi, SceneMonsterInfo.monster_id, 3024020
  mov r8, rsi
  sub r8, rsp ; SceneMonsterInfo buffer length

  sub rsp, 32 ; SceneMonsterWave
  mov rsi, rsp
  mov r9, rsp
  add r9, 32 ; SceneMonsterInfo
  pb_write_bytes rsi, SceneMonsterWave.monster_list, r9, r8
  mov r10, rsi
  sub r10, rsp ; SceneMonsterWave buffer length

  sub rsp, 128 ; SceneBattleInfo
  mov rsi, rsp
  mov r9, rsp
  add r9, 128 ; SceneMonsterWave
  pb_write_bytes rsi, SceneBattleInfo.monster_wave_list, r9, r10
  mov r11, rsi ; SceneBattleInfo position

  macro encode_battle_avatar id, level, rank, promotion, hp, sp_cur, sp_need, avatar_type {
    sub rsp, 32 ; SpBarInfo
    mov rsi, rsp
    pb_write_varint rsi, SpBarInfo.sp_cur, sp_cur
    pb_write_varint rsi, SpBarInfo.sp_need, sp_need
    mov r8, rsi
    sub r8, rsp ; SpBarInfo buffer length
    sub rsp, 64 ; BattleAvatar
    mov rsi, rsp
    pb_write_varint rsi, BattleAvatar.id, id
    pb_write_varint rsi, BattleAvatar.level, level
    pb_write_varint rsi, BattleAvatar.rank, rank
    pb_write_varint rsi, BattleAvatar.promotion, promotion
    pb_write_varint rsi, BattleAvatar.hp, hp
    pb_write_varint rsi, BattleAvatar.avatar_type, avatar_type
    mov r9, rsp
    add r9, 64 ; SpBarInfo
    pb_write_bytes rsi, BattleAvatar.sp_bar, r9, r8
    mov r9, rsp
    mov r8, rsi
    sub r8, rsp ; BattleAvatar buffer length
    mov rsi, r11 ; SceneBattleInfo buffer
    pb_write_bytes rsi, SceneBattleInfo.battle_avatar_list, r9, r8
    mov r11, rsi
    add rsp, 32+64 ; deallocate Avatar and SpBarInfo buffers
  }

  encode_battle_avatar 1415, 80, 6, 6, 10000, 10000, 10000, AVATAR_FORMAL_TYPE
  encode_battle_avatar 1401, 80, 6, 6, 10000, 10000, 10000, AVATAR_FORMAL_TYPE
  encode_battle_avatar 1005, 80, 6, 6, 10000, 10000, 10000, AVATAR_FORMAL_TYPE
  encode_battle_avatar 1003, 80, 6, 6, 10000, 10000, 10000, AVATAR_FORMAL_TYPE

  pb_write_varint rsi, SceneBattleInfo.battle_id, 1
  pb_write_varint rsi, SceneBattleInfo.stage_id, 201012311
  call get_timestamp_ms
  and rax, 0x1000000
  mov r9, rax
  pb_write_varint rsi, SceneBattleInfo.logic_random_seed, r9
  mov r14, rsi
  sub r14, rsp
  mov r12, rsp

  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  pb_write_bytes rsi, StartCocoonStageScRsp.battle_info, r12, r14
  pb_write_varint rsi, StartCocoonStageScRsp.wave, 1
  pb_write_varint rsi, StartCocoonStageScRsp.prop_entity_id, 1337
  mov r15, rsi

  add rsp, (128+32+32) ; deallocate all on-stack buffers

  sub r15, r13 ; cur - begin
  mov r8, r15 ; r8 = body_len
  mov r9, CmdStartCocoonStageScRsp
  jmp .send_rsp

.handle_pve_battle_result:
  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  pb_write_varint rsi, PveBattleResultScRsp.battle_id, 1
  pb_write_varint rsi, PveBattleResultScRsp.end_status, BATTLE_END_WIN
  mov r15, rsi
  sub r15, r13 ; cur - begin
  mov r8, r15 ; r8 = body_len
  mov r9, CmdPVEBattleResultScRsp
  jmp .send_rsp

; GetMissionStatus processing
.handle_get_mission_status:
  mov rdi, [recv_buffer_ptr]
  xor rsi, rsi
  add rdi, PACKET_HEAD_SIZE_OFFSET
  xor rax, rax
  mov ax, [rdi] ; eax now has head_size (big endian tho)
  bswap eax
  shr eax, 16 ; rax has head_size

  add rdi, PACKET_BODY_SIZE_OFFSET-PACKET_HEAD_SIZE_OFFSET
  mov esi, [rdi] ; esi now has body size (big endian again)
  bswap esi

  add rdi, 4 ; skip body_len that we've just read
  add rdi, rax ; skip PacketHead data, RDI has req buffer now
  
  mov r12, rsi ; r12 has req body length
  add r12, rdi ; r12 has req body end pointer

  mov r13, [send_buffer_ptr]
  add r13, PACKET_BODY_SIZE_OFFSET+4 ; encode directly to the send_buffer at the right offset
  mov rsi, r13
  push r13 ; preserved send buffer beginning
  
.process_loop:
  cmp rdi, r12
  jge .process_end
  mov rsi, rdi
  call decode_varint
  mov rdi, rsi
  cmp rax, ((GetMissionStatusCsReq.main_mission_id_list shl 3) or WIRE_LEN)
  je .process_main_missions
  cmp rax, ((GetMissionStatusCsReq.sub_mission_id_list shl 3) or WIRE_LEN)
  je .process_sub_missions
  nprint trace_log, trace_log_len, rax
  jmp .process_end

.process_main_missions:
  push r12
  call decode_varint
  mov r12, rsi
  add r12, rax ; list length in bytes
  mov rdi, rsi
.for_each_main_mission:
  cmp rdi, r12
  jge .for_each_main_mission_end
  mov rsi, rdi
  call decode_varint ; read next main mission id
  ; nprint main_trace_log, main_trace_log_len, rax
  mov rdi, rsi
  mov r14, rax
  mov rsi, r13
  pb_write_varint rsi, GetMissionStatusScRsp.finished_main_mission_id_list, r14
  mov r13, rsi ; r13 = current_write_buf_ptr
  jmp .for_each_main_mission
.for_each_main_mission_end:
  pop r12
  jmp .process_loop
.process_sub_missions:
  push r12
  call decode_varint
  mov r12, rsi
  add r12, rax ; list length in bytes
  mov rdi, rsi
.for_each_sub_mission:
  cmp rdi, r12
  jge .for_each_sub_mission_end
  mov rsi, rdi
  call decode_varint ; read next sub mission id
  ; nprint sub_trace_log, sub_trace_log_len, rax
  mov rdi, rsi
  mov r14, rax
  sub rsp, 32 ; allocate 32 bytes for 'Mission' buffer
  mov r11, rsp ; beginning of Mission buffer
  mov rsi, rsp
  pb_write_varint rsi, Mission.id, r14
  pb_write_varint rsi, Mission.status, MISSION_STATUS_FINISH
  mov r14, r11 ; save beginning of Mission buffer
  sub rsi, r11 ; cur pos of mission buffer - beginning = length
  mov r11, rsi ; Mission buffer length is now in r11
  mov rsi, r13 ; rsp buffer at current pos is now in rsi
  pb_write_bytes rsi, GetMissionStatusScRsp.sub_mission_status_list, r14, r11
  mov r13, rsi ; r13 = current_write_buf_ptr
  add rsp, 32 ; deallocate 'Mission' buffer
  jmp .for_each_sub_mission
.for_each_sub_mission_end:
  pop r12
  jmp .process_loop
; end of GetMissionStatus processing

.process_end:
  pop r14 ; rsp buffer beginning
  sub r13, r14 ; cur - begin
  mov r8, r13 ; r8 = body_len
  mov r9, CmdGetMissionStatusScRsp
  jmp .send_rsp

; dummy
  paste_dummy_branches

.packet_not_complete:
  ; nprint received_too_few_msg, received_too_few_msg_len, rax, r10
  jmp .recv_loop
.head_magic_mismatch:
  nprint head_magic_mismatch_msg, head_magic_mismatch_msg_len, HEAD_MAGIC, rax
  jmp .close_connection
.close_connection:
  pop r15 ; recv buffer position
  pop r15 ; client FD
  close r15

  ; extract ip octets into registers
  ; TODO: maybe move this to macro
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

  nprint disconnect_trace_msg, disconnect_trace_msg_len, r8, r9, r10, r11, r12
  jmp .accept_loop

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
get_timestamp_ms:
  push rsi
  push rdi
  push rdx
  push rcx
  push r8
  push r9
  
  sub rsp, 16
  mov rsi, rsp ; timespec
  mov rdi, 0 ; CLOCK_REALTIME
  clock_gettime 0, rsi
  mov r8, [rsp] ; sec
  mov rax, [rsp+8] ; nsec
  
  cdq ; prepare registers for `div`
  mov rcx, 1000000 ; ns to ms
  div rcx
  cmp rax, 0 ; if div result is 0, number is finished

  mov r9, rax
  mov rax, r8
  mov rcx, 1000
  mul rcx
  add rax, r9

  add rsp, 16
  pop r9
  pop r8
  pop rcx
  pop rdx
  pop rdi
  pop rsi
  ret

segment readable writeable
  listener_fd dq 0
  recv_buffer_ptr dq 0
  send_buffer_ptr dq 0

  bind_address sockaddr_in AF_INET, TCP_BIND_PORT, 0
  bind_address_len = $ - bind_address

  accept_address sockaddr_in 0, 0, 0
  accept_address_len dq $ - bind_address

  fatal_error_msg db "fatal error occurred, exiting.", 10
  fatal_error_msg_len = $ - fatal_error_msg

  startup_msg db "INFO: game server is listening at 0.0.0.0:%", 10
  startup_msg_len = $ - startup_msg

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

  disconnect_trace_msg db "INFO: client from %.%.%.%:% disconnected", 10
  disconnect_trace_msg_len = $ - disconnect_trace_msg

  received_too_few_msg db "WARN: expected at least % bytes, but received % bytes", 10
  received_too_few_msg_len = $ - received_too_few_msg

  head_magic_mismatch_msg db "WARN: head magic mismatch! Expected: %, received: %, closing connection", 10
  head_magic_mismatch_msg_len = $ - head_magic_mismatch_msg

  recv_cmd_id_trace_msg db "INFO: received packet with cmd_id %", 10
  recv_cmd_id_trace_msg_len = $ - recv_cmd_id_trace_msg

  heartbeat_trace_msg db "INFO: PlayerHeartBeat: client_time_ms: %", 10
  heartbeat_trace_msg_len = $ - heartbeat_trace_msg

  player_nickname_str db "ReversedRooms"
  player_nickname_str_len = $ - player_nickname_str

  lineup_name_str db "squad 1"
  lineup_name_str_len = $ - lineup_name_str

  heartbeat_payload db 8, 51, 16, 185, 10, 26, 128, 6, 108, 111, 99, 97, 108, 32, 102, 117, 110, 99, 116, 105, 111, 110, 32, 115, 101, 116, 84, 101, 120, 116, 67, 111, 109, 112, 111, 110, 101, 110, 116, 40, 112, 97, 116, 104, 44, 32, 110, 101, 119, 84, 101, 120, 116, 41, 10, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 108, 111, 99, 97, 108, 32, 111, 98, 106, 32, 61, 32, 67, 83, 46, 85, 110, 105, 116, 121, 69, 110, 103, 105, 110, 101, 46, 71, 97, 109, 101, 79, 98, 106, 101, 99, 116, 46, 70, 105, 110, 100, 40, 112, 97, 116, 104, 41, 10, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 105, 102, 32, 111, 98, 106, 32, 116, 104, 101, 110, 10, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 108, 111, 99, 97, 108, 32, 116, 101, 120, 116, 67, 111, 109, 112, 111, 110, 101, 110, 116, 32, 61, 32, 111, 98, 106, 58, 71, 101, 116, 67, 111, 109, 112, 111, 110, 101, 110, 116, 73, 110, 67, 104, 105, 108, 100, 114, 101, 110, 40, 116, 121, 112, 101, 111, 102, 40, 67, 83, 46, 82, 80, 71, 46, 67, 108, 105, 101, 110, 116, 46, 76, 111, 99, 97, 108, 105, 122, 101, 100, 84, 101, 120, 116, 41, 41, 10, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 105, 102, 32, 116, 101, 120, 116, 67, 111, 109, 112, 111, 110, 101, 110, 116, 32, 116, 104, 101, 110, 10, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 116, 101, 120, 116, 67, 111, 109, 112, 111, 110, 101, 110, 116, 46, 116, 101, 120, 116, 32, 61, 32, 110, 101, 119, 84, 101, 120, 116, 10, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 101, 110, 100, 10, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 101, 110, 100, 10, 32, 32, 32, 32, 32, 32, 32, 32, 101, 110, 100, 10, 32, 32, 32, 32, 32, 32, 32, 32, 10, 32, 32, 32, 32, 32, 32, 32, 32, 115, 101, 116, 84, 101, 120, 116, 67, 111, 109, 112, 111, 110, 101, 110, 116, 40, 34, 85, 73, 82, 111, 111, 116, 47, 65, 98, 111, 118, 101, 68, 105, 97, 108, 111, 103, 47, 66, 101, 116, 97, 72, 105, 110, 116, 68, 105, 97, 108, 111, 103, 40, 67, 108, 111, 110, 101, 41, 34, 44, 32, 34, 60, 99, 111, 108, 111, 114, 61, 35, 97, 49, 100, 54, 102, 98, 62, 67, 60, 47, 99, 111, 108, 111, 114, 62, 60, 99, 111, 108, 111, 114, 61, 35, 98, 50, 99, 55, 102, 97, 62, 121, 60, 47, 99, 111, 108, 111, 114, 62, 60, 99, 111, 108, 111, 114, 61, 35, 99, 50, 98, 56, 102, 57, 62, 114, 60, 47, 99, 111, 108, 111, 114, 62, 60, 99, 111, 108, 111, 114, 61, 35, 100, 51, 97, 97, 102, 56, 62, 101, 60, 47, 99, 111, 108, 111, 114, 62, 60, 99, 111, 108, 111, 114, 61, 35, 100, 98, 97, 99, 101, 55, 62, 110, 60, 47, 99, 111, 108, 111, 114, 62, 60, 99, 111, 108, 111, 114, 61, 35, 101, 51, 97, 102, 100, 54, 62, 101, 60, 47, 99, 111, 108, 111, 114, 62, 60, 99, 111, 108, 111, 114, 61, 35, 101, 98, 98, 49, 99, 53, 62, 83, 60, 47, 99, 111, 108, 111, 114, 62, 60, 99, 111, 108, 111, 114, 61, 35, 102, 52, 98, 52, 98, 52, 62, 82, 60, 47, 99, 111, 108, 111, 114, 62, 32, 105, 115, 32, 97, 32, 102, 114, 101, 101, 32, 97, 110, 100, 32, 111, 112, 101, 110, 32, 115, 111, 117, 114, 99, 101, 32, 115, 111, 102, 116, 119, 97, 114, 101, 46, 34, 41, 10, 32, 32, 32, 32, 32, 32, 32, 32, 115, 101, 116, 84, 101, 120, 116, 67, 111, 109, 112, 111, 110, 101, 110, 116, 40, 34, 86, 101, 114, 115, 105, 111, 110, 84, 101, 120, 116, 34, 44, 32, 34, 86, 105, 115, 105, 116, 32, 100, 105, 115, 99, 111, 114, 100, 46, 103, 103, 47, 114, 101, 118, 101, 114, 115, 101, 100, 114, 111, 111, 109, 115, 32, 102, 111, 114, 32, 109, 111, 114, 101, 32, 105, 110, 102, 111, 33, 34, 41, 10
  heartbeat_payload_len = $ - heartbeat_payload

  trace_log db "TRACE: tracked value: %", 10
  trace_log_len = $ - trace_log

  sub_trace_log db "TRACE: sub_mission tracked value: %", 10
  sub_trace_log_len = $ - sub_trace_log

  main_trace_log db "TRACE: main_mission tracked value: %", 10
  main_trace_log_len = $ - main_trace_log

  startup_splash db "   ____                          ____  ____  ", 10
                 db "  / ___|   _ _ __ ___ _ __   ___/ ___||  _ \ ", 10
                 db " | |  | | | | '__/ _ \ '_ \ / _ \___ \| |_) |", 10
                 db " | |__| |_| | | |  __/ | | |  __/___) |  _ < ", 10
                 db "  \____\__, |_|  \___|_| |_|\___|____/|_| \_\", 10
                 db "       |___/                                 ", 10
  startup_splash_len = $ - startup_splash
