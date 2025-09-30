.PHONY: all clean

all: dispatch gameserver

dispatch: src/dispatch.asm src/dispatch.pb.asm src/protobuf.asm src/base64.asm src/syscalls.asm src/print.asm
	fasm src/dispatch.asm dispatch

gameserver: src/gameserver.asm src/gameserver.pb.asm src/protobuf.asm src/dummy_handlers.asm src/syscalls.asm src/print.asm
	fasm src/gameserver.asm gameserver

clean:
	rm dispatch & rm gameserver
